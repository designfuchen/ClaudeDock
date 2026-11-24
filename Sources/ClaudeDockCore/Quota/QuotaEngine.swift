import Foundation

/// Zero-token-cost quota radar using official Claude CLI `control_request: get_usage`.
/// Features: 60s debounce, max 2 concurrent probes, before/after identity verification, monotonic window cache.
public actor QuotaEngine {
    public static let minimumRefreshInterval: TimeInterval = 60.0
    public static let maxConcurrentProbes = 2

    private let identityObserver: IdentityObserver
    private var activeProbes = 0
    private var inFlight: [String: (generation: UInt64, task: Task<QuotaSnapshot, Never>)] = [:]
    private var nextGeneration: UInt64 = 0

    public init(identityObserver: IdentityObserver = IdentityObserver()) {
        self.identityObserver = identityObserver
    }

    public func isDue(_ snapshot: QuotaSnapshot?, now: Date = Date()) -> Bool {
        guard let snapshot else { return true }
        return now.timeIntervalSince(snapshot.checkedAt) >= Self.minimumRefreshInterval
    }

    /// Probes 5-hour and 7-day quota windows strictly via `control_request: get_usage` (0 inference tokens, $0 cost).
    /// Registers per-account task BEFORE suspending for concurrency slot so duplicate probes never slip through.
    public func refresh(
        account: AccountProfile,
        claudeCLIURL: URL,
        force: Bool = false
    ) async -> QuotaSnapshot {
        if !force, let existing = account.quota, !isDue(existing) {
            return existing
        }
        if let existingEntry = inFlight[account.id] {
            return await existingEntry.task.value
        }

        nextGeneration &+= 1
        let gen = nextGeneration
        let task = Task<QuotaSnapshot, Never> { [self] in
            // Acquire concurrency permit inside the registered task
            guard await self.acquirePermit() else {
                return account.quota ?? QuotaSnapshot(status: .error, errorMessage: "Cancelled")
            }
            defer { self.releasePermit() }
            if Task.isCancelled {
                return account.quota ?? QuotaSnapshot(status: .error, errorMessage: "Cancelled")
            }
            return await self.performZeroTokenProbe(account: account, claudeCLIURL: claudeCLIURL)
        }
        inFlight[account.id] = (gen, task)
        let result = await task.value
        if inFlight[account.id]?.generation == gen {
            inFlight.removeValue(forKey: account.id)
        }
        return result
    }

    /// Returns false (holding nothing) if cancelled while waiting, so the caller never releases a permit it never took.
    private func acquirePermit() async -> Bool {
        while activeProbes >= Self.maxConcurrentProbes {
            if Task.isCancelled { return false }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return false
            }
        }
        activeProbes += 1
        return true
    }

    private func releasePermit() {
        activeProbes = max(0, activeProbes - 1)
    }

    private func performZeroTokenProbe(account: AccountProfile, claudeCLIURL: URL) async -> QuotaSnapshot {
        let startedAt = Int64(Date().timeIntervalSince1970)
        // 1. Verify active CLI identity before querying usage
        guard let before = await identityObserver.probeCLIAuthStatus(account: account, claudeCLIURL: claudeCLIURL) else {
            return QuotaSnapshot(status: .error, checkedAt: Date(), errorMessage: "CLI auth status probe timed out or failed")
        }
        guard before.loggedIn, let expectedHash = before.subjectHash else {
            return QuotaSnapshot(status: .loggedOut, checkedAt: Date(), errorMessage: "CLI profile not signed in")
        }

        // 2. Invoke zero-token structured get_usage control_request
        let env = identityObserver.buildCLIEnvironment(for: account)
        let probeOutput: Result<(available: Bool, fiveHour: QuotaWindow?, sevenDay: QuotaWindow?), Error> = await runUsageProcess(
            claudeCLIURL: claudeCLIURL,
            env: env,
            timeoutSeconds: 10.0
        )

        // 3. Re-verify identity after query so mid-flight /login cannot attribute quota to the wrong account
        guard let after = await identityObserver.probeCLIAuthStatus(account: account, claudeCLIURL: claudeCLIURL),
              after.subjectHash == expectedHash else {
            return QuotaSnapshot(status: .error, checkedAt: Date(), errorMessage: "Account identity changed during quota check")
        }

        switch probeOutput {
        case .success(let parsed):
            if !parsed.available {
                return QuotaSnapshot(status: .notApplicable, identityHash: expectedHash, checkedAt: Date())
            }
            return Self.mergeMonotonic(
                previous: account.quota,
                fiveHour: parsed.fiveHour,
                sevenDay: parsed.sevenDay,
                identityHash: expectedHash,
                queryStartedAt: startedAt
            )

        case .failure(let error):
            return cachedFallback(previous: account.quota, expectedIdentityHash: expectedHash, status: .error, message: error.localizedDescription)
        }
    }

    /// only reuse cached quota windows when `previous.identityHash` matches the verified identity.
    private func cachedFallback(previous: QuotaSnapshot?, expectedIdentityHash: String, status: QuotaStatus, message: String) -> QuotaSnapshot {
        if let prev = previous,
           prev.identityHash == expectedIdentityHash,
           (prev.fiveHour != nil || prev.sevenDay != nil) {
            return QuotaSnapshot(
                fiveHour: prev.fiveHour,
                sevenDay: prev.sevenDay,
                status: .cached,
                identityHash: prev.identityHash,
                checkedAt: Date(),
                errorMessage: message
            )
        }
        return QuotaSnapshot(status: status, identityHash: expectedIdentityHash, checkedAt: Date(), errorMessage: message)
    }

    private func runUsageProcess(
        claudeCLIURL: URL,
        env: [String: String],
        timeoutSeconds: Double
    ) async -> Result<(available: Bool, fiveHour: QuotaWindow?, sevenDay: QuotaWindow?), Error> {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("claudedock-usage-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tmpDir) }

        let payload = Data((#"{"type":"control_request","request_id":"quota","request":{"subtype":"get_usage","skip_behaviors":true}}"# + "\n").utf8)
        do {
            let res = try await SubprocessRunner.run(
                executableURL: claudeCLIURL,
                arguments: [
                    "--setting-sources", "user",
                    "--settings", #"{"disableAllHooks":true}"#,
                    "-p",
                    "--input-format", "stream-json",
                    "--verbose",
                    "--output-format", "stream-json",
                    "--no-session-persistence",
                    "--strict-mcp-config",
                    "--tools", "",
                ],
                environment: env,
                currentDirectoryURL: tmpDir,
                stdinData: payload,
                timeoutSeconds: timeoutSeconds,
                maxOutputBytes: 2 << 20
            )
            if res.timedOut {
                return .failure(DockError.quotaProbeFailed("get_usage timed out"))
            }
            guard res.exitCode == 0 else {
                return .failure(DockError.quotaProbeFailed("CLI exited with status \(res.exitCode)"))
            }
            let parsed = try Self.parseUsageStreamJSON(res.stdout, now: Date())
            return .success(parsed)
        } catch {
            return .failure(error)
        }
    }

    /// Pure parser for Claude CLI `SDKControlGetUsageResponse` NDJSON stream.
    /// Rejects any unexpected inference turn or non-zero cost for strict zero-token safety.
    public static func parseUsageStreamJSON(
        _ data: Data,
        now: Date = Date()
    ) throws -> (available: Bool, fiveHour: QuotaWindow?, sevenDay: QuotaWindow?) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DockError.quotaProbeFailed("Non-UTF8 output from usage probe")
        }

        var report: [String: Any]?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = rawLine.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let type = msg["type"] as? String
            if type == "user" || type == "assistant" {
                throw DockError.quotaProbeFailed("Unexpected conversation turn during zero-token usage query")
            }
            if type == "result" {
                let isErr = (msg["is_error"] as? Bool) == true
                let turns = (msg["num_turns"] as? Int) ?? 0
                if isErr || turns != 0 {
                    throw DockError.quotaProbeFailed("Unexpected inference result during usage query")
                }
            }
            if type == "control_response",
               let resp = msg["response"] as? [String: Any],
               (resp["request_id"] as? String) == "quota" {
                guard report == nil, (resp["subtype"] as? String) == "success",
                      let body = resp["response"] as? [String: Any] else {
                    throw DockError.quotaProbeFailed("Failed control_response for get_usage")
                }
                report = body
            }
        }

        guard let report, let available = report["rate_limits_available"] as? Bool else {
            throw DockError.quotaProbeFailed("Missing structured usage response")
        }
        if let session = report["session"] as? [String: Any] {
            let cost = (session["total_cost_usd"] as? Double) ?? 0
            if cost != 0 {
                throw DockError.quotaProbeFailed("Unexpected non-zero cost reported")
            }
        }
        guard available else {
            return (false, nil, nil)
        }

        let nowSec = Int64(now.timeIntervalSince1970)
        let rate = (report["rate_limits"] as? [String: Any]) ?? [:]
        var fiveHour = parseMeter(rate["five_hour"] as? [String: Any], nowSec: nowSec)
        var sevenDay = parseMeter(rate["seven_day"] as? [String: Any], nowSec: nowSec)

        // Fallback to unscoped limits[] rows if direct keys were omitted
        if let rows = rate["limits"] as? [[String: Any]] {
            for row in rows {
                guard let kind = row["kind"] as? String else { continue }
                if kind == "session", fiveHour == nil {
                    fiveHour = parseLimitRow(row, nowSec: nowSec)
                } else if kind == "weekly_all", sevenDay == nil {
                    sevenDay = parseLimitRow(row, nowSec: nowSec)
                }
            }
        }

        return (true, fiveHour, sevenDay)
    }

    private static func parseMeter(_ dict: [String: Any]?, nowSec: Int64) -> QuotaWindow? {
        guard let dict, let util = numberValue(dict["utilization"]), (0...100).contains(util) else {
            return nil
        }
        let reset = parseResetTimestamp(dict["resets_at"], nowSec: nowSec)
        return QuotaWindow(usedPercentage: util, resetsAt: reset, observedAt: nowSec)
    }

    private static func parseLimitRow(_ dict: [String: Any], nowSec: Int64) -> QuotaWindow? {
        guard let pct = numberValue(dict["percent"]), (0...100).contains(pct) else {
            return nil
        }
        let reset = parseResetTimestamp(dict["resets_at"], nowSec: nowSec)
        return QuotaWindow(usedPercentage: pct, resetsAt: reset, observedAt: nowSec)
    }

    private static func numberValue(_ raw: Any?) -> Double? {
        // JSON true/false bridge to NSNumber too; a boolean is never a percentage or timestamp.
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Epoch seconds of the reset, or 0 when unknown. A reset already in the past is kept as-is (not 0):
    /// `QuotaWindow.isExpired` then reports the window as rolled over instead of treating a stale "100% used"
    /// as current forever. Millisecond epochs are normalised to seconds.
    private static func parseResetTimestamp(_ raw: Any?, nowSec: Int64) -> Int64 {
        if !(raw is String), let value = numberValue(raw), value.isFinite, value > 0 {
            let sec = value > 100_000_000_000 ? value / 1000 : value
            return Int64(sec)
        }
        if let iso = raw as? String {
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            if let dt = f1.date(from: iso) ?? f2.date(from: iso) {
                let sec = Int64(dt.timeIntervalSince1970)
                return sec > 0 ? sec : 0
            }
        }
        return 0
    }

    /// Merges new quota windows monotonically so stale readings never roll back newer observations.
    public static func mergeMonotonic(
        previous: QuotaSnapshot?,
        fiveHour: QuotaWindow?,
        sevenDay: QuotaWindow?,
        identityHash: String,
        queryStartedAt: Int64
    ) -> QuotaSnapshot {
        let sameIdentity = (previous?.identityHash == identityHash)
        let prevFH = sameIdentity ? previous?.fiveHour : nil
        let prevSD = sameIdentity ? previous?.sevenDay : nil

        let mergedFH = pickWindow(old: prevFH, new: fiveHour, queryStartedAt: queryStartedAt)
        let mergedSD = pickWindow(old: prevSD, new: sevenDay, queryStartedAt: queryStartedAt)

        let count = (mergedFH != nil ? 1 : 0) + (mergedSD != nil ? 1 : 0)
        let status: QuotaStatus
        switch count {
        case 2: status = .reported
        case 1: status = .partial
        default: status = .unavailable
        }

        return QuotaSnapshot(
            fiveHour: mergedFH,
            sevenDay: mergedSD,
            status: status,
            identityHash: identityHash,
            checkedAt: Date(),
            errorMessage: nil
        )
    }

    private static func pickWindow(old: QuotaWindow?, new: QuotaWindow?, queryStartedAt: Int64) -> QuotaWindow? {
        guard let old else { return new }
        guard let new else { return old }
        if old.observedAt > queryStartedAt {
            return old
        }
        // Only a reset that moved meaningfully backwards marks a stale reading; ±1 min is server jitter.
        if new.resetsAt > 0 && old.resetsAt > 0 && new.resetsAt < old.resetsAt - 60 {
            return old
        }
        return new
    }
}
