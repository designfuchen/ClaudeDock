import Foundation

/// Probes real external egress IP, region, country, city, and timezone STRICTLY through the configured proxy.
/// Uses `curl -q` (ignoring ~/.curlrc), HTTPS-only protocols, and deadlock-free SubprocessRunner.
/// NEVER falls back to direct connection when a proxy is specified.
public final class EgressProber: Sendable {
    public struct Endpoint: Sendable {
        public let name: String
        public let url: URL
    }

    public static let defaultEndpoints: [Endpoint] = [
        Endpoint(name: "ipinfo.io", url: URL(string: "https://ipinfo.io/json")!),
        Endpoint(name: "ipwho.is", url: URL(string: "https://ipwho.is/")!),
        Endpoint(name: "ifconfig.co", url: URL(string: "https://ifconfig.co/json")!),
    ]

    public init() {}

    /// Probes real egress strictly via `proxy` (HTTP or SOCKS5). Fails closed if proxy is dead.
    public func probe(proxy: ProxyConfig, timeoutSeconds: TimeInterval = 5.0) async throws -> EgressObservation {
        try Validation.validateProxy(proxy)

        var lastError: String = "No GeoIP provider responded"
        for endpoint in Self.defaultEndpoints {
            if Task.isCancelled { throw CancellationError() }
            do {
                var obs = try await fetchGeoJSON(from: endpoint, via: proxy, timeout: timeoutSeconds)
                // Stamp which proxy produced this measurement, so it can never vouch for a different one.
                obs.proxyKey = proxy.proxyURLString
                return obs
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = "\(endpoint.name): \(error.localizedDescription)"
            }
        }
        throw DockError.proxyUnreachable(proxy: proxy.proxyURLString, detail: lastError)
    }

    /// Probes egress via `/usr/bin/curl -q` with explicit `--proxy`, `--noproxy ""`, HTTPS-only `--proto`,
    /// and a clean environment so ~/.curlrc or inherited `NO_PROXY` can never contaminate or bypass the proxy.
    private func fetchGeoJSON(from endpoint: Endpoint, via proxy: ProxyConfig, timeout: TimeInterval) async throws -> EgressObservation {
        let proxyFlag: String
        switch proxy.scheme {
        case .http:
            proxyFlag = "http://\(proxy.host):\(proxy.port)"
        case .socks5:
            // socks5h forces DNS resolution through the proxy so no local DNS leaks
            proxyFlag = "socks5h://\(proxy.host):\(proxy.port)"
        }

        // Minimal clean environment: strip ALL inherited proxy/NO_PROXY/CURL_HOME overrides
        let cleanEnv: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
        ]

        let result = try await SubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "-q", // MUST be first: disables reading ~/.curlrc
                "-fsSL",
                "--proto", "=https",
                "--proto-redir", "=https",
                "--max-redirs", "2",
                "--max-time", String(format: "%.1f", timeout),
                "--connect-timeout", "2.5",
                "--noproxy", "",
                "--proxy", proxyFlag,
                "-H", "Accept: application/json",
                "-H", "User-Agent: ClaudeDock/\(DockConstants.version)",
                "--",
                endpoint.url.absoluteString,
            ],
            environment: cleanEnv,
            timeoutSeconds: timeout + 2.0,
            maxOutputBytes: 256 * 1024
        )

        if result.timedOut {
            throw DockError.proxyUnreachable(proxy: proxy.proxyURLString, detail: "Probe timed out via \(endpoint.name)")
        }
        guard result.exitCode == 0 else {
            let errStr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "curl exit \(result.exitCode)"
            throw DockError.proxyUnreachable(proxy: proxy.proxyURLString, detail: errStr)
        }
        return try Self.parseGeoJSON(result.stdout, provider: endpoint.name)
    }

    /// Parses and normalizes GeoIP JSON responses from `ipinfo.io`, `ipwho.is`, and `ifconfig.co`.
    /// Always prefers canonical ISO 3166-1 alpha-2 country codes (`country_code`/`country_iso`) over full names.
    public static func parseGeoJSON(_ data: Data, provider: String) throws -> EgressObservation {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockError.ioError("Non-JSON response from \(provider)")
        }
        if let success = obj["success"] as? Bool, !success {
            let msg = (obj["message"] as? String) ?? "lookup failed"
            throw DockError.ioError("\(provider): \(msg)")
        }

        let ip = (obj["ip"] as? String) ?? (obj["query"] as? String) ?? ""
        guard !ip.isEmpty else {
            throw DockError.ioError("Missing IP in \(provider) response")
        }

        let city = (obj["city"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = ((obj["region"] as? String) ?? (obj["region_name"] as? String) ?? (obj["regionName"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer canonical 2-letter ISO code across all providers (`ipwho.is` has both `country`="United States" and `country_code`="US"!)
        let rawCountryCode = (obj["country_code"] as? String)
            ?? (obj["country_iso"] as? String)
            ?? (obj["countryCode"] as? String)
            ?? (obj["country"] as? String)
        let country = rawCountryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        var timezone: String? = obj["timezone"] as? String
        if timezone == nil, let tzObj = obj["timezone"] as? [String: Any] {
            timezone = tzObj["id"] as? String
        }
        if timezone == nil {
            timezone = obj["time_zone"] as? String
        }

        var org: String? = obj["org"] as? String
        if org == nil, let conn = obj["connection"] as? [String: Any] {
            org = (conn["org"] as? String) ?? (conn["isp"] as? String)
        }
        if org == nil {
            org = obj["asn_org"] as? String
        }

        return EgressObservation(
            ip: ip.trimmingCharacters(in: .whitespacesAndNewlines),
            city: city,
            region: region,
            country: country,
            timezone: timezone?.trimmingCharacters(in: .whitespacesAndNewlines),
            org: org?.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider,
            checkedAt: Date()
        )
    }
}

/// Pure, strict policy evaluator matching an EgressObservation against an AccountProfile's EgressPolicy.
/// Uses normalized exact matching and ignores empty entries so blank allowlists never accidentally pass.
public enum EgressPolicyEvaluator {
    public static func evaluate(observation: EgressObservation, against policy: EgressPolicy) -> EgressVerdict {
        if policy.mode == .disabled {
            return .skipped
        }

        if let pinnedIP = policy.pinnedIP?.trimmingCharacters(in: .whitespacesAndNewlines), !pinnedIP.isEmpty {
            if observation.ip != pinnedIP {
                return .blocked(
                    reason: "IP mismatch: expected \(pinnedIP), got \(observation.ip) (\(observation.locationLabel))",
                    observation: observation
                )
            }
        }

        if let prefix = policy.pinnedIPPrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty {
            if !observation.ip.hasPrefix(prefix) {
                return .blocked(
                    reason: "IP prefix mismatch: expected \(prefix)*, got \(observation.ip) (\(observation.locationLabel))",
                    observation: observation
                )
            }
        }

        let cleanCountries = normalizeList(policy.allowedCountries)
        if !cleanCountries.isEmpty {
            let actual = (observation.country ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if actual.isEmpty || !cleanCountries.contains(actual) {
                return .blocked(
                    reason: "Country mismatch: expected \(policy.allowedCountries.joined(separator: "/")), got \(observation.country ?? "unknown") (\(observation.locationLabel))",
                    observation: observation
                )
            }
        }

        let cleanRegions = normalizeList(policy.allowedRegions)
        if !cleanRegions.isEmpty {
            let actual = (observation.region ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if actual.isEmpty || !cleanRegions.contains(actual) {
                return .blocked(
                    reason: "Region mismatch: expected \(policy.allowedRegions.joined(separator: "/")), got \(observation.region ?? "unknown") (\(observation.locationLabel))",
                    observation: observation
                )
            }
        }

        let cleanCities = normalizeList(policy.allowedCities)
        if !cleanCities.isEmpty {
            let actual = (observation.city ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if actual.isEmpty || !cleanCities.contains(actual) {
                return .blocked(
                    reason: "City mismatch: expected \(policy.allowedCities.joined(separator: "/")), got \(observation.city ?? "unknown") (\(observation.locationLabel))",
                    observation: observation
                )
            }
        }

        let cleanTimezones = normalizeList(policy.allowedTimezones)
        if !cleanTimezones.isEmpty {
            let actual = (observation.timezone ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if actual.isEmpty || !cleanTimezones.contains(actual) {
                return .blocked(
                    reason: "Timezone mismatch: expected \(policy.allowedTimezones.joined(separator: "/")), got \(observation.timezone ?? "unknown")",
                    observation: observation
                )
            }
        }

        return .allowed(observation)
    }

    private static func normalizeList(_ list: [String]) -> [String] {
        list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
