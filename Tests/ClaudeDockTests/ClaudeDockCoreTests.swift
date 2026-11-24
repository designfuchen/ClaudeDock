import ClaudeDockCore
import Foundation
import XCTest

final class ClaudeDockCoreTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudedock-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
    }

    // MARK: - 1. Validation & Security Hygiene

    func testAccountNameValidation() throws {
        XCTAssertNoThrow(try Validation.validateAccountName("NY-1"))
        XCTAssertNoThrow(try Validation.validateAccountName("Work Account"))
        XCTAssertNoThrow(try Validation.validateAccountName("pro_5"))

        XCTAssertThrowsError(try Validation.validateAccountName(""))
        XCTAssertThrowsError(try Validation.validateAccountName("../evil"))
        XCTAssertThrowsError(try Validation.validateAccountName("foo/bar"))
        XCTAssertThrowsError(try Validation.validateAccountName("Claude-3p"))
        XCTAssertThrowsError(try Validation.validateAccountName("test 3P"))
        XCTAssertThrowsError(try Validation.validateAccountName("trailing "))
        XCTAssertThrowsError(try Validation.validateAccountName("a;rm -rf /"))
    }

    func testProxyAndColorValidation() throws {
        XCTAssertEqual(try Validation.normalizeColorHex("#3b6fd8"), "3B6FD8")
        XCTAssertThrowsError(try Validation.normalizeColorHex("ZZZZZZ"))

        XCTAssertNoThrow(try Validation.validateProxy(ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 7897)))
        XCTAssertThrowsError(try Validation.validateProxy(ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1;id", port: 7897)))
        XCTAssertThrowsError(try Validation.validateProxy(ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 70000)))
        XCTAssertThrowsError(try Validation.validateTimezone("../../etc/passwd"))
        XCTAssertNoThrow(try Validation.validateTimezone("America/New_York"))
    }

    // MARK: - 2. ProfileStore Atomic Persistence & Permissions

    func testProfileStoreRoundTripAndPermissions() throws {
        let storeRoot = tempHome.appendingPathComponent(".claudedock", isDirectory: true)
        let store = ProfileStore(rootDirectory: storeRoot)

        let profile = AccountProfile(
            name: "NY-1",
            proxy: ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 7897, timezone: "America/New_York"),
            egressPolicy: EgressPolicy(mode: .failClosed, pinnedIP: "107.173.1.2", allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"])
        )
        try store.mutate { data in
            data.accounts.append(profile)
        }

        let loaded = try store.load()
        XCTAssertEqual(loaded.accounts.count, 1)
        XCTAssertEqual(loaded.accounts[0].name, "NY-1")
        XCTAssertEqual(loaded.accounts[0].egressPolicy.pinnedIP, "107.173.1.2")

        let attrs = try FileManager.default.attributesOfItem(atPath: store.storeFileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)
    }

    // MARK: - 3. Process Discovery & Process Tree

    func testProcessMatchingAndTree() {
        let ps = """
          100     1 S    /Applications/Claude.app/Contents/MacOS/Claude
          101   100 S    /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=renderer
          200     1 S    /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/Users/test/Library/Application Support/Claude-NY-1 --proxy-server=http://127.0.0.1:7897
          201   200 S    /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu-process --user-data-dir=/Users/test/Library/Application Support/Claude-NY-1
          202   201 T    /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=utility
          300     1 T    /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=/Users/test/Library/Application Support/Claude-NY-2
        """
        let procs = ProcessManager.parsePSOutput(ps)
        XCTAssertEqual(procs.count, 6)

        let mainDefault = ProcessManager.matchMainProcesses(
            expectedUserDataDir: "/Users/test/Library/Application Support/Claude",
            isDefault: true,
            in: procs
        )
        XCTAssertEqual(mainDefault.map(\.pid), [100])

        let mainNY1 = ProcessManager.matchMainProcesses(
            expectedUserDataDir: "/Users/test/Library/Application Support/Claude-NY-1",
            isDefault: false,
            in: procs
        )
        XCTAssertEqual(mainNY1.map(\.pid), [200])

        let tree = ProcessManager.processTreePIDs(rootPIDs: [200], in: procs)
        XCTAssertEqual(tree, [200, 201, 202])

        let mainNY2 = ProcessManager.matchMainProcesses(
            expectedUserDataDir: "/Users/test/Library/Application Support/Claude-NY-2",
            isDefault: false,
            in: procs
        )
        XCTAssertEqual(mainNY2.first?.isStopped, true)
    }

    // MARK: - 4. Egress Prober JSON Parsing & Fail-Closed Guard

    func testGeoJSONParsingAndNewYorkPolicy() throws {
        let ipinfoJSON = """
        {"ip":"107.173.42.9","city":"Buffalo","region":"New York","country":"US","org":"AS36352 HostPapa","timezone":"America/New_York"}
        """.data(using: .utf8)!
        let nyObs = try EgressProber.parseGeoJSON(ipinfoJSON, provider: "ipinfo.io")
        XCTAssertEqual(nyObs.region, "New York")
        XCTAssertEqual(nyObs.country, "US")
        XCTAssertEqual(nyObs.timezone, "America/New_York")

        let nyPolicy = EgressPolicy(mode: .failClosed, allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"])
        XCTAssertTrue(EgressPolicyEvaluator.evaluate(observation: nyObs, against: nyPolicy).isAllowed)

        // Accidental switch to Singapore airport node -> MUST BLOCK.
        let sgObs = EgressObservation(ip: "43.134.10.1", city: "Singapore", region: "Singapore", country: "SG", timezone: "Asia/Singapore")
        let sgVerdict = EgressPolicyEvaluator.evaluate(observation: sgObs, against: nyPolicy)
        XCTAssertFalse(sgVerdict.isAllowed)

        // Accidental switch to Germany REALITY backup -> MUST BLOCK.
        let deObs = EgressObservation(ip: "185.20.1.1", city: "Frankfurt", region: "Hesse", country: "DE", timezone: "Europe/Berlin")
        XCTAssertFalse(EgressPolicyEvaluator.evaluate(observation: deObs, against: nyPolicy).isAllowed)
    }

    func testEgressGuardFailClosedOnDeadProxy() async {
        let guardEngine = EgressGuard()
        let deadAccount = AccountProfile(
            name: "NY-Dead",
            proxy: ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 19999),
            egressPolicy: EgressPolicy(mode: .failClosed, allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"])
        )
        do {
            _ = try await guardEngine.verifyBeforeLaunch(account: deadAccount)
            XCTFail("Expected Fail-Closed EgressGuard to reject dead proxy port")
        } catch let err as DockError {
            if case .egressBlocked(let acc, _) = err {
                XCTAssertEqual(acc, "NY-Dead")
            } else {
                XCTFail("Unexpected DockError: \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - 5. Clash Verge Multi-Listener YAML

    func testClashVergeMergeYAMLGeneration() {
        let a1 = AccountProfile(name: "NY-1", proxy: ProxyConfig(enabled: true, port: 17901, clashNodeName: "纽约直连-REALITY"))
        let a2 = AccountProfile(name: "NY-2", proxy: ProxyConfig(enabled: true, port: 17902, clashNodeName: "纽约直连-REALITY"))
        let yaml = ClashVergeHelper.generateMergeYAML(for: [a1, a2])
        XCTAssertTrue(yaml.contains("listeners:"))
        XCTAssertTrue(yaml.contains("name: claudedock-ny-1"))
        XCTAssertTrue(yaml.contains("port: 17901"))
        XCTAssertTrue(yaml.contains("listen: 127.0.0.1"))
        XCTAssertTrue(yaml.contains("proxy: \"纽约直连-REALITY\""))
        XCTAssertTrue(yaml.contains("port: 17902"))
    }

    // MARK: - 6. Identity & Zero-Token Quota Parsing

    func testDesktopLogIdentityParser() {
        let logSample = """
        [MAIN_LOG] 2026-11-24 05:00:01 [debug] [DATAPROVIDER] Setting "current-account" to: {
          isLoggedOut: false,
          accountUuid: '11111111-2222-3333-4444-555555555555',
          organizationUuid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
          emailAddress: 'builder@example.com',
        }
        """
        let obs = IdentityObserver.parseCurrentAccountLog(logSample)
        XCTAssertEqual(obs?.loggedIn, true)
        XCTAssertEqual(obs?.email, "builder@example.com")
        XCTAssertEqual(obs?.accountUUID, "11111111-2222-3333-4444-555555555555")
    }

    func testZeroTokenQuotaStreamParsingAndMonotonicMerge() throws {
        let future = Int64(Date().timeIntervalSince1970) + 7200
        let stream = """
        {"type":"control_response","response":{"request_id":"quota","subtype":"success","response":{"rate_limits_available":true,"session":{"total_cost_usd":0},"rate_limits":{"five_hour":{"utilization":42.5,"resets_at":\(future)},"seven_day":{"utilization":18.0,"resets_at":\(future + 86400)}}}}}
        {"type":"result","is_error":false,"num_turns":0}
        """.data(using: .utf8)!

        let parsed = try QuotaEngine.parseUsageStreamJSON(stream)
        XCTAssertTrue(parsed.available)
        XCTAssertEqual(parsed.fiveHour?.usedPercentage, 42.5)
        XCTAssertEqual(parsed.sevenDay?.usedPercentage, 18.0)

        // Ensure unexpected inference cost is strictly rejected
        let badStream = """
        {"type":"control_response","response":{"request_id":"quota","subtype":"success","response":{"rate_limits_available":true,"session":{"total_cost_usd":0.02},"rate_limits":{}}}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try QuotaEngine.parseUsageStreamJSON(badStream))

        // Monotonic merge must NOT roll back a newer window observed after queryStartedAt
        let newerSnap = QuotaSnapshot(
            fiveHour: QuotaWindow(usedPercentage: 65, resetsAt: future, observedAt: 2000),
            status: .partial,
            identityHash: "abc"
        )
        let merged = QuotaEngine.mergeMonotonic(
            previous: newerSnap,
            fiveHour: QuotaWindow(usedPercentage: 40, resetsAt: future, observedAt: 1500),
            sevenDay: nil,
            identityHash: "abc",
            queryStartedAt: 1800
        )
        XCTAssertEqual(merged.fiveHour?.usedPercentage, 65)
    }

    // MARK: - 7. Account Scheduler & Handoff Group Isolation

    func testSchedulerHeadroomAndGroupIsolation() {
        let future = Int64(Date().timeIntervalSince1970) + 3600
        let workHeavy = AccountProfile(
            name: "Work-1", sortOrder: 0, handoffGroup: "work",
            quota: QuotaSnapshot(fiveHour: QuotaWindow(usedPercentage: 92, resetsAt: future), status: .reported)
        )
        let workFresh = AccountProfile(
            name: "Work-2", sortOrder: 1, handoffGroup: "work",
            quota: QuotaSnapshot(fiveHour: QuotaWindow(usedPercentage: 15, resetsAt: future), status: .reported)
        )
        let personalFresh = AccountProfile(
            name: "Personal", sortOrder: 2, handoffGroup: "personal",
            quota: QuotaSnapshot(fiveHour: QuotaWindow(usedPercentage: 5, resetsAt: future), status: .reported)
        )

        let picked = AccountScheduler.recommendAccount(
            from: [workHeavy, workFresh, personalFresh],
            excludingAccountID: workHeavy.id,
            requiredGroup: "work",
            mode: .mostHeadroom
        )
        XCTAssertEqual(picked?.name, "Work-2") // Must not pick Personal despite higher headroom.

        let alerts = AccountScheduler.evaluateThresholdAlerts(
            accounts: [workHeavy, workFresh, personalFresh],
            thresholdPercentage: 85,
            mode: .mostHeadroom
        )
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].accountName, "Work-1")
        XCTAssertEqual(alerts[0].recommendedNext?.name, "Work-2")
    }

    // MARK: - 8. Three-Way Desktop MCP Sync

    func testThreeWayMergeAndDesktopMCPSync() throws {
        // Pure three-way tests: add, update, delete
        let base: [String: Any] = ["keep": ["cmd": "a"], "toDelete": ["cmd": "old"]]
        let local: [String: Any] = ["keep": ["cmd": "a"], "localNew": ["cmd": "x"]] // deleted toDelete, added localNew
        let common: [String: Any] = ["keep": ["cmd": "a"], "toDelete": ["cmd": "old"], "commonNew": ["cmd": "y"]]
        let merged = ConfigSyncEngine.threeWayMerge(local: local, base: base, common: common)
        XCTAssertNotNil(merged["keep"])
        XCTAssertNotNil(merged["localNew"])
        XCTAssertNotNil(merged["commonNew"])
        XCTAssertNil(merged["toDelete"])

        // End-to-end filesystem sync preserving non-MCP keys
        let acc1 = AccountProfile(name: "NY-1")
        let acc2 = AccountProfile(name: "NY-2")
        let dir1 = acc1.userDataDirectory(homeDirectory: tempHome)
        let dir2 = acc2.userDataDirectory(homeDirectory: tempHome)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        let cfg1 = #"{"theme":"dark","mcpServers":{"filesystem":{"command":"npx"}}}"#
        let cfg2 = #"{"theme":"light","mcpServers":{"github":{"command":"gh"}}}"#
        try cfg1.write(to: dir1.appendingPathComponent("claude_desktop_config.json"), atomically: true, encoding: .utf8)
        try cfg2.write(to: dir2.appendingPathComponent("claude_desktop_config.json"), atomically: true, encoding: .utf8)

        let syncEngine = ConfigSyncEngine(
            homeDirectory: tempHome,
            syncStateDirectory: tempHome.appendingPathComponent(".claudedock/sync", isDirectory: true)
        )
        let report = try syncEngine.syncDesktopMCPConfigs(accounts: [acc1, acc2])
        XCTAssertEqual(report.mergedMCPServerCount, 2)
        XCTAssertEqual(report.syncedAccounts.count, 2)

        let out1 = try JSONSerialization.jsonObject(with: Data(contentsOf: dir1.appendingPathComponent("claude_desktop_config.json"))) as? [String: Any]
        XCTAssertEqual(out1?["theme"] as? String, "dark") // Non-MCP field preserved.
        let mcp1 = out1?["mcpServers"] as? [String: Any]
        XCTAssertNotNil(mcp1?["filesystem"])
        XCTAssertNotNil(mcp1?["github"])
    }

    // MARK: - 9. Sandboxed Launcher & CLI Wrapper Lifecycle

    func testSandboxedLauncherAndCLILinkerLifecycle() throws {
        // Create a mock Claude.app in tempHome
        let fakeClaudeApp = tempHome.appendingPathComponent("Applications/Claude.app", isDirectory: true)
        let fakeBin = fakeClaudeApp.appendingPathComponent("Contents/MacOS/Claude")
        try FileManager.default.createDirectory(at: fakeBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: fakeBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBin.path)

        // Create shared ~/.claude/CLAUDE.md
        let mainClaude = tempHome.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: mainClaude, withIntermediateDirectories: true)
        try "# Shared Instructions\n".write(to: mainClaude.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let appsDir = tempHome.appendingPathComponent("Launchers", isDirectory: true)
        let controller = DockController(
            homeDirectory: tempHome,
            storeRoot: tempHome.appendingPathComponent(".claudedock", isDirectory: true),
            appsDirectory: appsDir
        )
        try controller.store.mutate { data in
            data.settings.claudeAppPath = fakeClaudeApp.path
        }

        let created = try controller.addAccount(
            name: "NY-1",
            iconStyle: .letter,
            colorHex: "2E9D6A",
            proxy: ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 17901, timezone: "America/New_York"),
            egressPolicy: EgressPolicy(mode: .failClosed, allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"]),
            cliLinked: true
        )

        let launcherApp = created.launcherAppURL(appsDirectory: appsDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: launcherApp.appendingPathComponent("Contents/MacOS/launcher").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: launcherApp.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertTrue(controller.launcherBuilder.isManagedLauncher(launcherApp))

        // Verify CLI wrapper created & delegates dynamically via `claudedock cli-run <ID>`
        let wrapper = controller.cliLinker.wrapperURL(for: created)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapper.path))
        let wrapperText = try String(contentsOf: wrapper, encoding: .utf8)
        XCTAssertTrue(wrapperText.contains("cli-run '\(created.id)'"))
        XCTAssertTrue(wrapperText.contains("unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy"))

        let linkedClaudeMD = created.cliConfigDirectory(homeDirectory: tempHome).appendingPathComponent("CLAUDE.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkedClaudeMD.path))

        // Verify rename keeps dataDirName intact
        var renamed = created
        renamed.name = "NY-Primary"
        let updated = try controller.updateAccount(renamed)
        XCTAssertEqual(updated.dataDirName, "Claude-NY-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launcherApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: updated.launcherAppURL(appsDirectory: appsDir).path))

        // Verify default account data folder cannot be deleted
        let def = try controller.addAccount(name: "Main", isDefault: true, iconStyle: .letter)
        XCTAssertThrowsError(try controller.removeAccount(nameOrID: def.id, deleteData: true))
    }

    // MARK: - 10. Hardening Regression Tests

    func testHardeningRegressions() throws {
        // 1. ipwho.is returns both country="United States" and country_code="US" -> must normalize to "US"
        let ipwhoJSON = """
        {"success":true,"ip":"107.173.1.5","country":"United States","country_code":"US","region":"New York","city":"Buffalo","timezone":{"id":"America/New_York"}}
        """.data(using: .utf8)!
        let parsed = try EgressProber.parseGeoJSON(ipwhoJSON, provider: "ipwho.is")
        XCTAssertEqual(parsed.country, "US")
        XCTAssertEqual(parsed.timezone, "America/New_York")
        XCTAssertTrue(EgressPolicyEvaluator.evaluate(observation: parsed, against: EgressPolicy(mode: .failClosed, allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"])).isAllowed)

        // 2. Substring/empty allowlist must NOT pass region checks
        let fuzzyPolicy = EgressPolicy(mode: .failClosed, allowedRegions: ["York", "   "])
        XCTAssertFalse(EgressPolicyEvaluator.evaluate(observation: parsed, against: fuzzyPolicy).isAllowed)

        // 3. Corrupt claude_desktop_config.json MUST abort MCP sync rather than wiping preferences
        let acc1 = AccountProfile(name: "GoodAcc")
        let acc2 = AccountProfile(name: "CorruptAcc")
        let acc3 = AccountProfile(name: "UnopenedAcc") // directory does not exist.
        let dir1 = acc1.userDataDirectory(homeDirectory: tempHome)
        let dir2 = acc2.userDataDirectory(homeDirectory: tempHome)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try #"{"mcpServers":{"git":{"command":"uvx"}}}"#.write(to: dir1.appendingPathComponent("claude_desktop_config.json"), atomically: true, encoding: .utf8)
        try "{corrupt json!!!".write(to: dir2.appendingPathComponent("claude_desktop_config.json"), atomically: true, encoding: .utf8)

        let sync = ConfigSyncEngine(homeDirectory: tempHome, syncStateDirectory: tempHome.appendingPathComponent(".claudedock/sync", isDirectory: true))
        XCTAssertThrowsError(try sync.syncDesktopMCPConfigs(accounts: [acc1, acc2]))

        // 4. Unopened account directory MUST NOT delete existing servers from GoodAcc.
        let report = try sync.syncDesktopMCPConfigs(accounts: [acc1, acc3])
        XCTAssertEqual(report.mergedMCPServerCount, 1)
        XCTAssertEqual(report.warnings.count, 1)

        // 5. YAML escaping & duplicate non-ASCII listener name deduplication
        let yaml = ClashVergeHelper.generateMergeYAML(mappings: [
            ClashListenerMapping(accountName: "纽约", listenPort: 17901, proxyName: "NY\\Node\"1\nBad"),
            ClashListenerMapping(accountName: "德国", listenPort: 17902, proxyName: "DE"),
        ])
        XCTAssertTrue(yaml.contains("claudedock-slot-1"))
        XCTAssertTrue(yaml.contains("claudedock-slot-2"))
        XCTAssertTrue(yaml.contains(#"proxy: "NY\\Node\"1\nBad""#))

        // 6. IdentityObserver strips NO_PROXY and binds both lowercase & uppercase proxy vars
        let nyAcc = AccountProfile(name: "NY-Env", proxy: ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 17901, timezone: "America/New_York"))
        let env = IdentityObserver(homeDirectory: tempHome).buildCLIEnvironment(for: nyAcc)
        XCTAssertEqual(env["HTTP_PROXY"], "http://127.0.0.1:17901")
        XCTAssertEqual(env["http_proxy"], "http://127.0.0.1:17901")
        XCTAssertEqual(env["https_proxy"], "http://127.0.0.1:17901")
        XCTAssertEqual(env["NO_PROXY"], "127.0.0.1,localhost")
        XCTAssertEqual(env["no_proxy"], "127.0.0.1,localhost")
    }

    // MARK: - Phase 1: Trustworthy status

    func testEgressHealthSeparatesPolicyFromMeasurement() {
        let now = Date()
        let freshness = EgressHealth.freshnessWindow(watchdogIntervalSeconds: 15)
        XCTAssertEqual(freshness, 60)
        XCTAssertEqual(EgressHealth.freshnessWindow(watchdogIntervalSeconds: 60), 180)

        let proxy = ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 17901)
        var acc = AccountProfile(name: "NY-1", proxy: proxy, egressPolicy: EgressPolicy(mode: .failClosed, allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"]))

        // A fail-closed policy with no observation is NOT verified (the old UI drew a green shield here).
        XCTAssertEqual(EgressHealth.evaluate(account: acc, alert: nil, freshness: freshness, now: now), .unverified)

        let nyObs = EgressObservation(ip: "107.173.42.9", city: "Buffalo", region: "New York", country: "US",
                                      timezone: "America/New_York", checkedAt: now.addingTimeInterval(-10))
        acc.lastEgress = nyObs
        let fresh = EgressHealth.evaluate(account: acc, alert: nil, freshness: freshness, now: now)
        XCTAssertTrue(fresh.isVerified)
        XCTAssertFalse(fresh.needsAttention)

        // Same observation, too old -> stale, not verified.
        let later = now.addingTimeInterval(freshness + 1)
        XCTAssertEqual(EgressHealth.evaluate(account: acc, alert: nil, freshness: freshness, now: later), .stale(nyObs))

        // Editing the rules re-evaluates the last observation: it can never stay green.
        acc.egressPolicy.allowedCountries = ["JP"]
        let edited = EgressHealth.evaluate(account: acc, alert: nil, freshness: freshness, now: now)
        guard case .mismatch(_, let obs) = edited else { return XCTFail("expected mismatch, got \(edited)") }
        XCTAssertEqual(obs, nyObs)
        XCTAssertTrue(edited.needsAttention)
        acc.egressPolicy = EgressPolicy(mode: .failClosed, allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"])

        // An alert always wins; with an observation it is a mismatch, without one a probe failure.
        let sgObs = EgressObservation(ip: "43.134.10.1", region: "Singapore", country: "SG")
        let mismatchAlert = EgressAlert(accountID: acc.id, accountName: acc.name, reason: "Country mismatch",
                                        actionTaken: .freeze, observation: sgObs)
        XCTAssertEqual(EgressHealth.evaluate(account: acc, alert: mismatchAlert, freshness: freshness, now: now),
                       .mismatch(reason: "Country mismatch", observation: sgObs))
        let outage = EgressAlert(accountID: acc.id, accountName: acc.name, reason: "Proxy outage",
                                 actionTaken: .freeze, observation: nil)
        XCTAssertEqual(EgressHealth.evaluate(account: acc, alert: outage, freshness: freshness, now: now),
                       .probeFailed(reason: "Proxy outage"))

        // Guard on but proxy off is a misconfiguration; guard off is simply off.
        var noProxy = acc
        noProxy.proxy.enabled = false
        if case .misconfigured = EgressHealth.evaluate(account: noProxy, alert: nil, freshness: freshness, now: now) {} else {
            XCTFail("expected misconfigured")
        }
        var off = acc
        off.egressPolicy.mode = .disabled
        XCTAssertEqual(EgressHealth.evaluate(account: off, alert: mismatchAlert, freshness: freshness, now: now), .off)
    }

    func testFutureDatedObservationIsNeverFresh() {
        let now = Date()
        var acc = AccountProfile(name: "NY-2",
                                 proxy: ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 17901),
                                 egressPolicy: EgressPolicy(mode: .failClosed, allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"]))
        acc.lastEgress = EgressObservation(ip: "107.173.42.9", region: "New York", country: "US",
                                           timezone: "America/New_York", checkedAt: now.addingTimeInterval(3600))
        let health = EgressHealth.evaluate(account: acc, alert: nil, freshness: 60, now: now)
        XCTAssertFalse(health.isVerified, "a timestamp from the future must not count as a fresh measurement")
        acc.lastEgress?.checkedAt = now.addingTimeInterval(30) // small clock skew is tolerated
        XCTAssertTrue(EgressHealth.evaluate(account: acc, alert: nil, freshness: 60, now: now).isVerified)
    }

    func testUpdateAccountKeepsRuntimeDataAndDropsEgressOnTransportChange() throws {
        let controller = DockController(
            homeDirectory: tempHome,
            storeRoot: tempHome.appendingPathComponent("store", isDirectory: true),
            appsDirectory: tempHome.appendingPathComponent("Applications", isDirectory: true)
        )
        let store = controller.store
        var acc = AccountProfile(name: "Transport",
                                 proxy: ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 17901),
                                 egressPolicy: EgressPolicy(mode: .failClosed, allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"]))
        let obs = EgressObservation(ip: "107.173.42.9", region: "New York", country: "US")
        acc.lastEgress = obs
        acc.quota = QuotaSnapshot(fiveHour: QuotaWindow(usedPercentage: 10, resetsAt: 0), status: .reported)
        try store.mutate { $0.accounts.append(acc) }

        // A stale editor copy (no runtime data) must not wipe fresher runtime data on disk.
        var edit = acc.configurationOnly
        edit.notes = "renamed note"
        _ = try controller.updateAccount(edit, rebuildLauncher: false)
        var stored = try XCTUnwrap(store.load().accounts.first { $0.id == acc.id })
        XCTAssertEqual(stored.notes, "renamed note")
        XCTAssertEqual(stored.lastEgress?.ip, obs.ip) // JSON drops sub-second precision on dates
        XCTAssertNotNil(stored.quota)

        // Changing the proxy port invalidates the old measurement: it described a different exit.
        edit.proxy.port = 17902
        _ = try controller.updateAccount(edit, rebuildLauncher: false)
        stored = try XCTUnwrap(store.load().accounts.first { $0.id == acc.id })
        XCTAssertNil(stored.lastEgress)
        XCTAssertNotNil(stored.quota)
    }

    func testObservationFromAnotherProxyNeverVerifies() {
        let now = Date()
        var acc = AccountProfile(name: "NY-3",
                                 proxy: ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 17901),
                                 egressPolicy: EgressPolicy(mode: .failClosed, allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"]))
        acc.lastEgress = EgressObservation(ip: "107.173.42.9", region: "New York", country: "US",
                                           timezone: "America/New_York", checkedAt: now,
                                           proxyKey: "http://127.0.0.1:17901")
        XCTAssertTrue(EgressHealth.evaluate(account: acc, alert: nil, freshness: 60, now: now).isVerified)
        acc.proxy.port = 17902
        XCTAssertEqual(EgressHealth.evaluate(account: acc, alert: nil, freshness: 60, now: now), .unverified)
    }

    func testDesktopProfileReaderMatchesOnlyThisAccount() {
        func v8(_ key: String, _ value: String, twoByte: Bool = false) -> [UInt8] {
            var out = [UInt8](key.utf8)
            let payload: [UInt8] = twoByte
                ? value.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
                : Array(value.utf8)
            out.append(twoByte ? 0x63 : 0x22)
            out.append(UInt8(payload.count))
            return out + payload
        }
        let mine = "39ae0e7a-be8d-4313-b260-0626c0e52cf4"
        let other = "11111111-2222-3333-4444-555555555555"
        var bytes: [UInt8] = [0x00, 0x01]
        let own: [UInt8] = [0x22, 0x04] + Array("uuid".utf8) + [0x22, 0x24]
        bytes += own + Array(other.utf8) + [0x22] + v8("email_address", "someone@else.dev") + v8("full_name", "Someone")
        // A mere reference to my UUID from another object must not count.
        bytes += Array("accountUuid".utf8) + [0x22, 0x24] + Array(mine.utf8) + [0x22] + v8("email_address", "wrong@else.dev")
        bytes += [0x00, 0x7F] + own + Array(mine.utf8) + [0x22]
        bytes += v8("email_address", "me@example.com") + [0x22] + v8("full_name", "杨磊", twoByte: true)
        bytes += [0x22] + v8("display_name", "Lei")

        let p = DesktopProfileReader.parse(Data(bytes), accountUUID: mine)
        XCTAssertEqual(p?.email, "me@example.com")
        XCTAssertEqual(p?.displayName, "Lei", "display name wins over full name")

        var noDisplay: [UInt8] = own + Array(mine.utf8) + [0x22] + v8("email_address", "me@example.com") + [0x22] + v8("full_name", "杨磊", twoByte: true)
        noDisplay += [0x00]
        XCTAssertEqual(DesktopProfileReader.parse(Data(noDisplay), accountUUID: mine)?.displayName, "杨磊")
        XCTAssertNil(DesktopProfileReader.parse(Data(bytes), accountUUID: "99999999-0000-0000-0000-000000000000"))
    }

    func testSessionSharingMergesWithoutLosingHistory() throws {
        let linker = CLILinker(homeDirectory: tempHome)
        let fm = FileManager.default
        let shared = tempHome.appendingPathComponent(".claude/projects/-repo", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try "shared".write(to: shared.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let profile = tempHome.appendingPathComponent(".claudedock/cli-profiles/work", isDirectory: true)
        let privateProjects = profile.appendingPathComponent("projects/-repo", isDirectory: true)
        try fm.createDirectory(at: privateProjects, withIntermediateDirectories: true)
        try "mine".write(to: privateProjects.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        try "conflict".write(to: privateProjects.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        try linker.linkSharedSessions(into: profile)

        let link = profile.appendingPathComponent("projects")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), tempHome.appendingPathComponent(".claude/projects").path)
        XCTAssertEqual(try String(contentsOf: shared.appendingPathComponent("b.jsonl"), encoding: .utf8), "mine", "private session copied in")
        XCTAssertEqual(try String(contentsOf: shared.appendingPathComponent("a.jsonl"), encoding: .utf8), "shared", "shared copy never overwritten")
        let backups = try fm.contentsOfDirectory(atPath: profile.path).filter { $0.hasPrefix("projects.claudedock-backup-") }
        XCTAssertEqual(backups.count, 1)
        let backup = profile.appendingPathComponent(backups[0])
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("-repo/a.jsonl"), encoding: .utf8), "conflict", "nothing is deleted")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("-repo/b.jsonl"), encoding: .utf8), "mine")

        // A symlink planted inside the shared tree is never written through.
        let outside = tempHome.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: shared.deletingLastPathComponent().appendingPathComponent("-evil"), withDestinationURL: outside)

        // Turning sharing off and on again with new private history keeps the earlier backup and adds a new one.
        linker.unlinkSharedSessions(from: profile)
        XCTAssertFalse(fm.fileExists(atPath: link.path))
        let evil = profile.appendingPathComponent("projects/-evil", isDirectory: true)
        try fm.createDirectory(at: evil, withIntermediateDirectories: true)
        try "x".write(to: evil.appendingPathComponent("c.jsonl"), atomically: true, encoding: .utf8)
        try linker.linkSharedSessions(into: profile)
        let backups2 = try fm.contentsOfDirectory(atPath: profile.path).filter { $0.hasPrefix("projects.claudedock-backup-") }
        XCTAssertEqual(backups2.count, 2, "earlier backup kept")
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("c.jsonl").path), "never writes through a symlink")
        XCTAssertTrue(fm.fileExists(atPath: shared.appendingPathComponent("b.jsonl").path))
    }

    func testProjectCatalogTitlesAndAttribution() throws {
        let root = tempHome.appendingPathComponent(".claude/projects", isDirectory: true)
        let folder = root.appendingPathComponent("-Volumes-Work-app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let s1 = "11111111-1111-1111-1111-111111111111"
        let s2 = "22222222-2222-2222-2222-222222222222"
        let lines1 = [
            #"{"type":"queue-operation","operation":"enqueue"}"#,
            #"{"type":"user","cwd":"/Volumes/Work/app","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","cwd":"/Volumes/Work/app","message":{"role":"user","content":[{"type":"text","text":"Fix the login\nbug please"}]}}"#
        ].joined(separator: "\n")
        let lines2 = [
            #"{"type":"user","cwd":"/Volumes/Work/app","message":{"role":"user","content":"first prompt"}}"#,
            #"{"type":"custom-title","customTitle":"重构设置页","sessionId":"x"}"#
        ].joined(separator: "\n")
        try lines1.write(to: folder.appendingPathComponent("\(s1).jsonl"), atomically: true, encoding: .utf8)
        try lines2.write(to: folder.appendingPathComponent("\(s2).jsonl"), atomically: true, encoding: .utf8)
        try "junk".write(to: folder.appendingPathComponent("agent-notes.jsonl"), atomically: true, encoding: .utf8)

        let ledger = [
            SessionLedger.Entry(accountID: "acc-work", cwd: "/Volumes/Work/app", startedAt: Date().addingTimeInterval(-60)),
            SessionLedger.Entry(accountID: "acc-pro", cwd: "/Volumes/Work/app", startedAt: Date(), resumedSessionID: s2),
        ]
        let projects = ProjectCatalog.scan(projectRoots: [root], ledger: ledger)
        XCTAssertEqual(projects.count, 1)
        let p = try XCTUnwrap(projects.first)
        XCTAssertEqual(p.path, "/Volumes/Work/app")
        XCTAssertEqual(p.name, "app")
        let byID = Dictionary(uniqueKeysWithValues: p.sessions.map { ($0.id, $0) })
        XCTAssertEqual(byID[s1]?.title, "Fix the login bug please", "skips command echoes, collapses whitespace")
        XCTAssertEqual(byID[s2]?.title, "重构设置页", "custom title wins")
        XCTAssertEqual(byID[s2]?.lastAccountID, "acc-pro", "resumed session belongs to the account that resumed it")
        XCTAssertEqual(byID[s1]?.lastAccountID, "acc-work", "new session belongs to the launch just before it")

        // Ledger round-trip
        let l = SessionLedger(homeDirectory: tempHome)
        l.append(ledger[0]); l.append(ledger[1])
        XCTAssertEqual(l.load().map(\.accountID), ["acc-work", "acc-pro"])
    }

    func testAppSettingsDecodesOlderFiles() throws {
        let old = #"{"schedulingMode":"orderPriority","quotaAlertThreshold":80,"watchdogIntervalSeconds":30,"shareDesktopMCP":true,"shareClaudeCodeResources":false,"launchAtLogin":false,"globalHotkeysEnabled":true,"uiLanguage":"zh"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.schedulingMode, .orderPriority)
        XCTAssertFalse(s.shareClaudeCodeResources)
        XCTAssertTrue(s.shareClaudeCodeSessions, "new setting defaults on for existing users")
    }

    func testFuzzyMatchIncludingPinyin() {
        XCTAssertGreaterThan(FuzzyMatch.score("cg", in: ["词光"]), 0, "pinyin initials")
        XCTAssertGreaterThan(FuzzyMatch.score("ciguang", in: ["词光"]), 0, "full pinyin")
        XCTAssertGreaterThan(FuzzyMatch.score("xyy", in: ["X运营之王"]), 0, "mixed latin + chinese initials")
        XCTAssertGreaterThan(FuzzyMatch.score("cd", in: ["ClaudeDock"]), 0, "subsequence")
        XCTAssertEqual(FuzzyMatch.score("zz", in: ["ClaudeDock"]), 0)
        XCTAssertGreaterThan(FuzzyMatch.score("clau", in: ["ClaudeDock"]), FuzzyMatch.score("cd", in: ["ClaudeDock"]), "prefix ranks first")
    }

    func testSlugCollisionsAndDashesAreRejected() throws {
        XCTAssertThrowsError(try Validation.validateAccountName("Work --x"), "'--' would break process matching")
        let controller = DockController(
            homeDirectory: tempHome,
            storeRoot: tempHome.appendingPathComponent("store", isDirectory: true),
            appsDirectory: tempHome.appendingPathComponent("Applications", isDirectory: true)
        )
        _ = try controller.addAccount(name: "Pro 2", cliLinked: false, createLauncher: false)
        XCTAssertThrowsError(try controller.addAccount(name: "pro-2", cliLinked: false, createLauncher: false),
                             "same slug would share one CLI login folder")
    }

    func testProjectCatalogSurvivesChunkCutMidCharacter() {
        let line1 = #"{"type":"user","cwd":"/Volumes/Work/词光","message":{"role":"user","content":"整理一下中文长会话"}}"#
        var head = Data((line1 + "\n" + #"{"type":"assistant","text":"很长的中文回复"#).utf8)
        head = head.prefix(head.count - 2) // cut in the middle of a multi-byte character
        let info = ProjectCatalog.parseSession(head: head, tail: Data())
        XCTAssertEqual(info?.cwd, "/Volumes/Work/词光")
        XCTAssertEqual(info?.title, "整理一下中文长会话")
    }

    func testLiveParentPIDComesFromTheKernel() {
        XCTAssertEqual(WindowController.liveParentPID(of: getpid()), getppid())
        XCTAssertNil(WindowController.liveParentPID(of: 999_999), "a PID that doesn't exist has no parent")
    }

    func testChineseAccountNames() throws {
        XCTAssertNoThrow(try Validation.validateAccountName("工作"))
        XCTAssertNoThrow(try Validation.validateAccountName("工作 2"))
        XCTAssertThrowsError(try Validation.validateAccountName("工作/../x"))
        XCTAssertThrowsError(try Validation.validateAccountName("😀"), "emoji are not letters")
        XCTAssertEqual(AccountProfile(name: "工作").slug, "gong-zuo")
        XCTAssertEqual(AccountProfile(name: "个人 Pro").slug, "ge-ren-pro")
        XCTAssertEqual(AccountProfile(name: "NY-Main").slug, "ny-main", "ASCII names unchanged")
        XCTAssertTrue(AccountProfile(name: "工作").slug.allSatisfy(\.isASCII))
    }

    func testProjectFolderNameMatchesClaudeCode() {
        // Same encoding Claude Code uses on disk, including non-ASCII path parts.
        XCTAssertEqual(ProjectCatalog.projectFolderName(for: "/Users/me/Documents/我的项目/ClaudeDock"),
                       "-Users-me-Documents------ClaudeDock")
        XCTAssertEqual(ProjectCatalog.projectFolderName(for: "/a/b.c_d"), "-a-b-c-d")
    }

    func testMCPInventoryAndFingerprint() throws {
        let engine = ConfigSyncEngine(homeDirectory: tempHome)
        let a = AccountProfile(name: "A", isDefault: false)
        let b = AccountProfile(name: "B", isDefault: false)
        let dirA = a.userDataDirectory(homeDirectory: tempHome)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        let cfg = #"{"mcpServers":{"github":{"command":"gh"},"fetch":{"command":"uvx"}},"preferences":{"x":1}}"#
        try cfg.write(to: dirA.appendingPathComponent("claude_desktop_config.json"), atomically: true, encoding: .utf8)

        let inv = engine.mcpInventory(accounts: [a, b])
        XCTAssertEqual(inv[a.id], ["fetch", "github"])
        XCTAssertNil(inv[b.id], "an account never opened has no Desktop folder yet")

        let before = engine.configFingerprint(accounts: [a, b])
        try FileManager.default.createDirectory(at: b.userDataDirectory(homeDirectory: tempHome), withIntermediateDirectories: true)
        XCTAssertNotEqual(before, engine.configFingerprint(accounts: [a, b]), "a newly opened account changes the fingerprint")

        // Sync copies A's servers to B and keeps A's other preferences untouched.
        _ = try engine.syncDesktopMCPConfigs(accounts: [a, b])
        XCTAssertEqual(engine.mcpInventory(accounts: [a, b])[b.id], ["fetch", "github"])
        let aAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: dirA.appendingPathComponent("claude_desktop_config.json"))) as? [String: Any]
        XCTAssertNotNil(aAfter?["preferences"])
    }

    func testMissingConfigNeverWipesOtherAccounts() throws {
        let engine = ConfigSyncEngine(homeDirectory: tempHome)
        let a = AccountProfile(name: "A")
        let b = AccountProfile(name: "B")
        for acc in [a, b] {
            try FileManager.default.createDirectory(at: acc.userDataDirectory(homeDirectory: tempHome), withIntermediateDirectories: true)
        }
        let cfgA = a.userDataDirectory(homeDirectory: tempHome).appendingPathComponent("claude_desktop_config.json")
        let cfgB = b.userDataDirectory(homeDirectory: tempHome).appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"github":{"command":"gh"}}}"#.write(to: cfgA, atomically: true, encoding: .utf8)
        _ = try engine.syncDesktopMCPConfigs(accounts: [a, b])
        XCTAssertEqual(engine.mcpInventory(accounts: [a, b])[b.id], ["github"])

        // A's file disappears (e.g. Claude Desktop reset it). That must not delete github from B.
        try FileManager.default.removeItem(at: cfgA)
        _ = try engine.syncDesktopMCPConfigs(accounts: [a, b])
        XCTAssertEqual(engine.mcpInventory(accounts: [a, b])[b.id], ["github"], "missing file is not a deletion")
        XCTAssertEqual(engine.mcpInventory(accounts: [a, b])[a.id], ["github"], "and A gets its servers back")

        // An explicit empty object *is* a deletion, and it propagates.
        try #"{"mcpServers":{}}"#.write(to: cfgB, atomically: true, encoding: .utf8)
        _ = try engine.syncDesktopMCPConfigs(accounts: [a, b])
        XCTAssertEqual(engine.mcpInventory(accounts: [a, b])[a.id], [])
    }

    func testUnknownQuotaNeverOutranksMeasured() {
        let now = Date()
        let future = Int64(now.timeIntervalSince1970) + 3600
        var measured = AccountProfile(name: "Main", sortOrder: 1)
        measured.quota = QuotaSnapshot(fiveHour: QuotaWindow(usedPercentage: 69, resetsAt: future), status: .reported)
        let unknown = AccountProfile(name: "New", sortOrder: 0)
        var signedOut = AccountProfile(name: "Out", sortOrder: 0)
        signedOut.quota = QuotaSnapshot(status: .loggedOut)
        XCTAssertEqual(AccountScheduler.recommendAccount(from: [unknown, measured, signedOut], mode: .mostHeadroom, now: now)?.name, "Main")
        XCTAssertEqual(AccountScheduler.recommendAccount(from: [unknown, signedOut], mode: .mostHeadroom, now: now)?.name, "New",
                       "with nothing measured, fall back to list order — but never to a signed-out account")
        XCTAssertNil(AccountScheduler.recommendAccount(from: [signedOut], mode: .mostHeadroom, now: now))
    }

    func testLostSharedCatalogNeverWipesAccounts() throws {
        let engine = ConfigSyncEngine(homeDirectory: tempHome)
        let a = AccountProfile(name: "A"), b = AccountProfile(name: "B")
        for acc in [a, b] {
            try FileManager.default.createDirectory(at: acc.userDataDirectory(homeDirectory: tempHome), withIntermediateDirectories: true)
        }
        let cfgA = a.userDataDirectory(homeDirectory: tempHome).appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"github":{"command":"gh"}}}"#.write(to: cfgA, atomically: true, encoding: .utf8)
        _ = try engine.syncDesktopMCPConfigs(accounts: [a, b])
        // The shared catalog disappears (cleanup, Time Machine restore, manual delete…).
        let catalog = tempHome.appendingPathComponent(".claudedock/sync/shared-desktop-mcp.json")
        if FileManager.default.fileExists(atPath: catalog.path) { try FileManager.default.removeItem(at: catalog) }
        else {
            // Find it wherever the engine keeps it.
            let found = FileManager.default.enumerator(atPath: tempHome.path)?.compactMap { $0 as? String }.first { $0.hasSuffix("shared-desktop-mcp.json") }
            try FileManager.default.removeItem(at: tempHome.appendingPathComponent(try XCTUnwrap(found)))
        }
        _ = try engine.syncDesktopMCPConfigs(accounts: [a, b])
        let inv = engine.mcpInventory(accounts: [a, b])
        XCTAssertEqual(inv[a.id], ["github"], "a lost catalog must not delete servers")
        XCTAssertEqual(inv[b.id], ["github"])
    }

    func testConfigurationOnlyIgnoresRuntimeObservations() {
        let base = AccountProfile(name: "Work", egressPolicy: EgressPolicy(mode: .failClosed, allowedCountries: ["US"], allowedRegions: ["New York"], allowedTimezones: ["America/New_York"]))
        var observed = base
        observed.lastEgress = EgressObservation(ip: "1.2.3.4")
        observed.quota = QuotaSnapshot(fiveHour: QuotaWindow(usedPercentage: 40, resetsAt: 0), status: .reported)
        observed.identity = ObservedIdentity(email: "a@example.com", loggedIn: true)
        XCTAssertNotEqual(base, observed)
        XCTAssertEqual(base.configurationOnly, observed.configurationOnly)

        var edited = base
        edited.proxy.port = 17902
        XCTAssertNotEqual(base.configurationOnly, edited.configurationOnly)
    }

    // MARK: - Review-round regressions

    func testPastResetTimestampExpiresInsteadOfStickingAt100() throws {
        let now = Date()
        let past = Int64(now.timeIntervalSince1970) - 600
        let stream = """
        {"type":"control_response","response":{"request_id":"quota","subtype":"success","response":{"rate_limits_available":true,"session":{"total_cost_usd":0},"rate_limits":{"five_hour":{"utilization":100,"resets_at":\(past)},"seven_day":{"utilization":true,"resets_at":\(Double(past) + 0.5)}}}}}
        {"type":"result","is_error":false,"num_turns":0}
        """.data(using: .utf8)!
        let parsed = try QuotaEngine.parseUsageStreamJSON(stream, now: now)
        let fh = try XCTUnwrap(parsed.fiveHour)
        XCTAssertEqual(fh.resetsAt, past, "a past reset must be kept, not turned into 'unknown'")
        XCTAssertTrue(fh.isExpired(at: now), "a window whose reset passed must count as rolled over")
        XCTAssertNil(parsed.sevenDay, "a JSON boolean is never a utilization percentage")
    }

    func testUngroupedAccountNeverHandsOffAcrossGroups() {
        let future = Int64(Date().timeIntervalSince1970) + 3600
        let loose = AccountProfile(name: "Loose", sortOrder: 0, handoffGroup: nil,
                                   quota: QuotaSnapshot(fiveHour: QuotaWindow(usedPercentage: 95, resetsAt: future), status: .reported))
        let work = AccountProfile(name: "Work", sortOrder: 1, handoffGroup: "work",
                                  quota: QuotaSnapshot(fiveHour: QuotaWindow(usedPercentage: 5, resetsAt: future), status: .reported))
        let alerts = AccountScheduler.evaluateThresholdAlerts(accounts: [loose, work], thresholdPercentage: 85, mode: .mostHeadroom)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertNil(alerts[0].recommendedNext, "an ungrouped account must not be pointed at an explicitly grouped one")
    }

    func testClashMergeReservesExplicitPortsBeforeAutoAssigning() {
        let auto = AccountProfile(name: "Auto", sortOrder: 0)
        let pinned = AccountProfile(name: "Pinned", sortOrder: 1,
                                    proxy: ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: 17901))
        let yaml = ClashVergeHelper.generateMergeYAML(for: [auto, pinned], mixedPort: 7890)
        let lines = yaml.components(separatedBy: "\n")
        // The configured account keeps 17901; the automatic one moves past it.
        XCTAssertTrue(yaml.contains("17901"))
        XCTAssertTrue(yaml.contains("17902"))
        let pinnedIdx = lines.firstIndex { $0.contains("claudedock-pinned") } ?? -1
        let autoIdx = lines.firstIndex { $0.contains("claudedock-auto") } ?? -1
        XCTAssertGreaterThanOrEqual(pinnedIdx, 0)
        XCTAssertGreaterThanOrEqual(autoIdx, 0)
        XCTAssertTrue(lines[pinnedIdx...].prefix(6).contains { $0.contains("17901") }, yaml)
        XCTAssertFalse(lines[autoIdx...].prefix(6).contains { $0.contains("17901") }, yaml)
    }

    func testRenameNeverMovesTheClaudeCodeFolder() throws {
        let controller = DockController(
            homeDirectory: tempHome,
            storeRoot: tempHome.appendingPathComponent("store", isDirectory: true),
            appsDirectory: tempHome.appendingPathComponent("Applications", isDirectory: true)
        )
        let acc = try controller.addAccount(name: "Alpha", cliLinked: false, createLauncher: false)
        XCTAssertEqual(acc.cliDirName, acc.id, "new accounts are keyed by their ID, not their name")
        let dir = acc.cliConfigDirectory(homeDirectory: tempHome)
        XCTAssertEqual(dir.lastPathComponent, acc.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var renamed = acc
        renamed.name = "Beta"
        renamed.cliDirName = "tampered" // an editor must not be able to repoint the login folder
        let committed = try controller.updateAccount(renamed, rebuildLauncher: false)
        XCTAssertEqual(committed.name, "Beta")
        XCTAssertEqual(committed.cliConfigDirectory(homeDirectory: tempHome), dir)
        XCTAssertEqual(try controller.loadData().accounts.first?.cliDirName, acc.id)
    }

    func testLegacySlugFoldersMigrateToStableIDs() throws {
        let controller = DockController(
            homeDirectory: tempHome,
            storeRoot: tempHome.appendingPathComponent("store", isDirectory: true),
            appsDirectory: tempHome.appendingPathComponent("Applications", isDirectory: true)
        )
        let fm = FileManager.default
        // Profiles saved by an older version: no cliDirName, folder named after the slug.
        let idle = AccountProfile(name: "Idle Work")
        let busy = AccountProfile(name: "Busy")
        let empty = AccountProfile(name: "Never Used")
        let main = AccountProfile(name: "Main", isDefault: true)
        try controller.store.mutate { $0.accounts = [idle, busy, empty, main] }
        XCTAssertEqual(idle.cliConfigDirectory(homeDirectory: tempHome).lastPathComponent, "idle-work")

        let idleOld = idle.cliConfigDirectory(homeDirectory: tempHome)
        try fm.createDirectory(at: idleOld, withIntermediateDirectories: true)
        try Data("login".utf8).write(to: idleOld.appendingPathComponent(".credentials.json"))
        // A live Claude Code session (this test process) keeps Busy's folder in place for now.
        let busySessions = busy.cliConfigDirectory(homeDirectory: tempHome).appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: busySessions, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: busySessions.appendingPathComponent("\(getpid()).json"))

        let moved = controller.migrateCLIProfileDirectories()
        XCTAssertEqual(moved, ["Idle Work"])
        let stored = try controller.loadData().accounts
        func find(_ a: AccountProfile) -> AccountProfile? { stored.first { $0.id == a.id } }

        let idleNow = try XCTUnwrap(find(idle))
        XCTAssertEqual(idleNow.cliDirName, idle.id)
        XCTAssertTrue(fm.fileExists(atPath: idleNow.cliConfigDirectory(homeDirectory: tempHome).appendingPathComponent(".credentials.json").path))
        XCTAssertFalse(fm.fileExists(atPath: idleOld.path))

        XCTAssertNil(find(busy)?.cliDirName, "a folder in use is left alone and retried later")
        XCTAssertTrue(fm.fileExists(atPath: busySessions.path))
        XCTAssertEqual(find(empty)?.cliDirName, empty.id, "no folder yet: adopt the stable name directly")
        XCTAssertNil(find(main)?.cliDirName, "the default account keeps using ~/.claude")
        XCTAssertEqual(find(main)?.cliConfigDirectory(homeDirectory: tempHome).lastPathComponent, ".claude")

        // Once the session ends, the next pass finishes the job; after that it is a no-op.
        try fm.removeItem(at: busySessions.appendingPathComponent("\(getpid()).json"))
        XCTAssertEqual(controller.migrateCLIProfileDirectories(), ["Busy"])
        XCTAssertEqual(controller.migrateCLIProfileDirectories(), [])
    }

    func testSubprocessReturnsWhenADescendantHoldsThePipe() async throws {
        // The shell exits at once, but its background child keeps stdout open for 30s.
        let started = Date()
        let result = try await SubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo hello; sleep 30 & exit 0"],
            timeoutSeconds: 10
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }
}
