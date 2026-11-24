import Foundation

/// Passively discovers account identity across Claude Desktop profiles and paired CLI profiles.
/// Never touches macOS Keychain or decrypts Electron Cookies.
public final class IdentityObserver: Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public static func locateClaudeCLI(customPath: String? = nil, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let c = customPath, !c.isEmpty { candidates.append(c) }
        candidates.append(homeDirectory.appendingPathComponent(".local/bin/claude").path)
        candidates.append("/opt/homebrew/bin/claude")
        candidates.append("/usr/local/bin/claude")
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                candidates.append("\(dir)/claude")
            }
        }
        for p in candidates {
            if fm.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    /// Combines passive Desktop session directory discovery + optional CLI `claude auth status` probe.
    public func observe(account: AccountProfile, claudeCLIURL: URL?) async -> ObservedIdentity {
        let desktopUUIDs = discoverDesktopUUIDs(for: account)
        let profile = desktopUUIDs.flatMap { DesktopProfileReader.read(userDataDirectory: account.userDataDirectory(homeDirectory: homeDirectory), accountUUID: $0.accountUUID) }

        if let cliURL = claudeCLIURL, (account.cliLinked || account.isDefault) {
            if let cliIdentity = await probeCLIAuthStatus(account: account, claudeCLIURL: cliURL) {
                return ObservedIdentity(
                    email: cliIdentity.email ?? profile?.email,
                    displayName: profile?.displayName,
                    organizationID: cliIdentity.organizationID ?? desktopUUIDs?.orgUUID,
                    accountUUID: desktopUUIDs?.accountUUID,
                    planType: cliIdentity.planType,
                    loggedIn: cliIdentity.loggedIn,
                    source: desktopUUIDs != nil ? "cli+desktop" : "cli",
                    observedAt: Date()
                )
            }
        }

        if let uuids = desktopUUIDs {
            // Historical session directory is an observed hint; preserve verified email/plan only if UUID matches
            let keepEmail = (account.identity?.accountUUID == uuids.accountUUID) ? account.identity?.email : nil
            let keepPlan = (account.identity?.accountUUID == uuids.accountUUID) ? account.identity?.planType : nil
            return ObservedIdentity(
                email: profile?.email ?? keepEmail,
                displayName: profile?.displayName,
                organizationID: uuids.orgUUID,
                accountUUID: uuids.accountUUID,
                planType: keepPlan,
                loggedIn: keepEmail != nil,
                source: "desktop-sessions-hint",
                observedAt: Date()
            )
        }

        return ObservedIdentity(loggedIn: false, source: "none", observedAt: Date())
    }

    /// Passively inspects `<userDataDir>/claude-code-sessions/<accountUuid>/<orgUuid>/` for the most recently active Desktop account UUID pair.
    public func discoverDesktopUUIDs(for account: AccountProfile) -> (accountUUID: String, orgUUID: String)? {
        let fm = FileManager.default
        let sessionsRoot = account.userDataDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
        guard fm.fileExists(atPath: sessionsRoot.path),
              let accountDirs = try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        var best: (account: String, org: String, modified: Date)?
        for accDir in accountDirs {
            guard isUUID(accDir.lastPathComponent),
                  let orgDirs = try? fm.contentsOfDirectory(at: accDir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for orgDir in orgDirs {
                guard isUUID(orgDir.lastPathComponent) else { continue }
                let mod = (try? orgDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if best == nil || mod > best!.modified {
                    best = (accDir.lastPathComponent, orgDir.lastPathComponent, mod)
                }
            }
        }
        guard let found = best else { return nil }
        return (found.account, found.org)
    }

    /// Runs `claude auth status` in a clean temp directory with the account's `CLAUDE_CONFIG_DIR` and bound proxy.
    /// Uses deadlock-free `SubprocessRunner` with strict timeout and SIGTERM->SIGKILL cleanup.
    public func probeCLIAuthStatus(account: AccountProfile, claudeCLIURL: URL) async -> ObservedIdentity? {
        let env = buildCLIEnvironment(for: account)
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("claudedock-id-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tmpDir) }

        guard let res = try? await SubprocessRunner.run(
            executableURL: claudeCLIURL,
            arguments: [
                "--setting-sources", "user",
                "--settings", #"{"disableAllHooks":true}"#,
                "auth", "status",
            ],
            environment: env,
            currentDirectoryURL: tmpDir,
            timeoutSeconds: 8.0,
            maxOutputBytes: 256 * 1024
        ) else {
            return nil
        }
        guard !res.timedOut, (res.exitCode == 0 || res.exitCode == 1) else {
            return nil
        }
        return Self.parseAuthStatusJSON(res.stdout)
    }

    public func buildCLIEnvironment(for account: AccountProfile) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Strip third-party API overrides AND all inherited uppercase/lowercase proxy & NO_PROXY vars (!)
        for key in [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
            "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_GATEWAY",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy"
        ] {
            env.removeValue(forKey: key)
        }
        if account.isDefault {
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            let cfgDir = account.cliConfigDirectory(homeDirectory: homeDirectory)
            try? FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            env["CLAUDE_CONFIG_DIR"] = cfgDir.path
        }
        if account.proxy.enabled {
            let proxyURL = account.proxy.proxyURLString
            // Bind BOTH uppercase and lowercase proxy vars and prohibit NO_PROXY bypasses
            env["HTTP_PROXY"] = proxyURL
            env["HTTPS_PROXY"] = proxyURL
            env["ALL_PROXY"] = proxyURL
            env["http_proxy"] = proxyURL
            env["https_proxy"] = proxyURL
            env["all_proxy"] = proxyURL
            env["NO_PROXY"] = "127.0.0.1,localhost"
            env["no_proxy"] = "127.0.0.1,localhost"
            if let tz = account.proxy.timezone, !tz.isEmpty {
                env["TZ"] = tz
            }
        }
        return env
    }

    public static func parseAuthStatusJSON(_ data: Data) -> ObservedIdentity? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let loggedIn = (obj["loggedIn"] as? Bool) == true
            && (obj["authMethod"] as? String) == "claude.ai"
            && (obj["apiProvider"] as? String) == "firstParty"
        if !loggedIn {
            return ObservedIdentity(loggedIn: false, source: "cli", observedAt: Date())
        }
        let email = obj["email"] as? String
        let org = (obj["orgId"] as? String) ?? (obj["orgName"] as? String)
        let plan = obj["subscriptionType"] as? String
        return ObservedIdentity(
            email: email,
            organizationID: org,
            accountUUID: nil,
            planType: plan,
            loggedIn: true,
            source: "cli",
            observedAt: Date()
        )
    }

    /// Parses passive Claude Desktop debug log chunks for `[DATAPROVIDER] Setting "current-account"` events.
    public static func parseCurrentAccountLog(_ text: String) -> ObservedIdentity? {
        let ansiStripped = text.replacingOccurrences(of: #"\u{001B}\[[0-9;]*m"#, with: "", options: .regularExpression)
        var inBlock = false
        var fields: [String: String] = [:]
        var latest: ObservedIdentity?

        for rawLine in ansiStripped.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.contains("[DATAPROVIDER] Resetting \"current-account\"") {
                inBlock = false
                fields = [:]
                latest = ObservedIdentity(loggedIn: false, source: "desktop-log", observedAt: Date())
                continue
            }
            if line.contains("[DATAPROVIDER] Setting \"current-account\" to: { isLoggedOut: true }") {
                inBlock = false
                fields = [:]
                latest = ObservedIdentity(loggedIn: false, source: "desktop-log", observedAt: Date())
                continue
            }
            if line.contains("[DATAPROVIDER] Setting \"current-account\" to: {") {
                inBlock = true
                fields = [:]
                continue
            }
            guard inBlock else { continue }
            if line == "}" {
                inBlock = false
                if fields["isLoggedOut"] == "true" {
                    latest = ObservedIdentity(loggedIn: false, source: "desktop-log", observedAt: Date())
                } else if fields["isLoggedOut"] == "false", let email = fields["emailAddress"], !email.isEmpty {
                    latest = ObservedIdentity(
                        email: email,
                        organizationID: fields["organizationUuid"],
                        accountUUID: fields["accountUuid"],
                        planType: nil,
                        loggedIn: true,
                        source: "desktop-log",
                        observedAt: Date()
                    )
                }
                fields = [:]
            } else if line.hasPrefix("  ") {
                let trimmed = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ","))
                if let colonIdx = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let val = String(trimmed[trimmed.index(after: colonIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    if ["isLoggedOut", "accountUuid", "organizationUuid", "emailAddress"].contains(key) {
                        fields[key] = val
                    }
                }
            } else {
                inBlock = false
                fields = [:]
            }
        }
        return latest
    }

    private func isUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }
}
