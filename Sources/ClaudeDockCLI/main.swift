import ClaudeDockCore
import Foundation

@main
struct ClaudeDockCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let controller = DockController()

        guard let cmd = args.first else {
            printUsage()
            exit(0)
        }
        let rest = Array(args.dropFirst())
        // Same one-time layout upgrade the app does; a no-op once every account uses its per-ID folder.
        if !["help", "--help", "-h", "version", "--version", "-v"].contains(cmd) {
            controller.migrateCLIProfileDirectories()
        }

        do {
            switch cmd {
            case "add":
                try await handleAdd(rest, controller: controller)
            case "list", "ls":
                try handleList(rest, controller: controller)
            case "open":
                try await handleOpen(rest, controller: controller)
            case "focus":
                try handleFocus(rest, controller: controller)
            case "freeze":
                try handleFreeze(rest, controller: controller)
            case "resume":
                try await handleResume(rest, controller: controller)
            case "quit":
                try handleQuit(rest, controller: controller)
            case "quit-all":
                let ok = controller.windowController.quitAllClaudeDesktop()
                print(ok ? "All Claude Desktop windows closed." : "Some Claude Desktop windows may still be closing.")
            case "remove", "rm":
                try handleRemove(rest, controller: controller)
            case "egress":
                try await handleEgress(rest, controller: controller)
            case "clash":
                try handleClash(rest, controller: controller)
            case "quota":
                try await handleQuota(rest, controller: controller)
            case "recommend":
                try handleRecommend(rest, controller: controller)
            case "sync":
                try handleSync(rest, controller: controller)
            case "peers":
                try handlePeers(controller: controller)
            case "projects":
                try handleProjects(rest, controller: controller)
            case "handoff":
                try handleHandoff(rest)
            case "update-guard":
                try await handleUpdateGuard(rest, controller: controller)
            case "cli-run":
                try await handleCLIRun(rest, controller: controller)
            case "version", "--version", "-v":
                print("claudedock \(DockConstants.version)")
            case "help", "--help", "-h":
                printUsage()
            default:
                fputs("claudedock: unknown command '\(cmd)'\n", stderr)
                printUsage()
                exit(2)
            }
        } catch {
            fputs("claudedock error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func handleAdd(_ args: [String], controller: DockController) async throws {
        var name: String?
        var isDefault = false
        var iconStyle: IconStyle = .claudeBadge
        var colorHex: String?
        var proxyStr: String?
        var pinCurrent = false
        var pinIP: String?
        var regions: [String] = []
        var countries: [String] = []
        var tz: String?
        var group: String? = "default"
        var cliLinked = true

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--default": isDefault = true
            case "--pin": pinCurrent = true
            case "--ny":
                throw DockError.launcherOperationFailed("--ny was removed. Use --pin to detect the local proxy and lock the account to whatever exit it reports now.")
            case "--no-cli": cliLinked = false
            case "--icon":
                i += 1
                guard i < args.count else { throw DockError.launcherOperationFailed("--icon requires a value") }
                switch args[i] {
                case "claude": iconStyle = .claudeBadge
                case "letter": iconStyle = .letter
                default: iconStyle = .image(path: args[i])
                }
            case "--color":
                i += 1
                guard i < args.count else { throw DockError.invalidColorHex("") }
                colorHex = args[i]
            case "--proxy":
                i += 1
                guard i < args.count else { throw DockError.invalidProxyConfig("--proxy requires URL") }
                proxyStr = args[i]
            case "--pin-ip":
                i += 1
                guard i < args.count else { throw DockError.invalidProxyConfig("--pin-ip requires IP") }
                pinIP = args[i]
            case "--region":
                i += 1
                guard i < args.count else { throw DockError.invalidProxyConfig("--region requires value") }
                regions.append(args[i])
            case "--country":
                i += 1
                guard i < args.count else { throw DockError.invalidProxyConfig("--country requires value") }
                countries.append(args[i])
            case "--tz":
                i += 1
                guard i < args.count else { throw DockError.invalidTimezone("") }
                tz = args[i]
            case "--group":
                i += 1
                guard i < args.count else { throw DockError.launcherOperationFailed("--group requires value") }
                group = args[i]
            default:
                if args[i].hasPrefix("-") {
                    throw DockError.launcherOperationFailed("Unknown flag: \(args[i])")
                }
                if let name {
                    throw DockError.invalidAccountName("Got two names ('\(name)' and '\(args[i])'). Quote a name that contains spaces.")
                }
                name = args[i]
            }
            i += 1
        }

        guard let accountName = name else {
            throw DockError.invalidAccountName("Usage: claudedock add <NAME> [--default] [--pin] [--proxy http://127.0.0.1:7897]")
        }
        if let tz { try Validation.validateTimezone(tz) }

        var proxy = ProxyConfig(enabled: false)
        if let proxyStr {
            proxy = try parseProxyURL(proxyStr)
        }
        if let tz { proxy.timezone = tz }

        var policy = EgressPolicy()
        if pinIP != nil || !regions.isEmpty || !countries.isEmpty {
            // A fail-closed rule without a proxy would block every launch with no way to pass.
            guard proxy.enabled || pinCurrent else {
                throw DockError.invalidProxyConfig("--pin-ip/--region/--country need a proxy: add --proxy URL or --pin")
            }
            policy = EgressPolicy(
                mode: .failClosed,
                pinnedIP: pinIP,
                allowedCountries: countries,
                allowedRegions: regions,
                allowedTimezones: tz.map { [$0] } ?? [],
                watchdogEnabled: true,
                watchdogAction: .freeze
            )
        }

        let fresh = try controller.addAccount(
            name: accountName,
            isDefault: isDefault,
            iconStyle: iconStyle,
            colorHex: colorHex,
            proxy: proxy,
            egressPolicy: policy,
            handoffGroup: group,
            cliLinked: cliLinked
        )
        var account = fresh
        if pinCurrent {
            do {
                let (pinned, obs) = try await controller.pinCurrentEgress(for: fresh.id, pinExactIP: pinIP != nil)
                account = pinned
                print("Pinned to the current exit: \(obs.locationLabel) (TZ: \(obs.timezone ?? "—"))")
            } catch {
                fputs("Account created, but pinning failed: \(error.localizedDescription)\nRetry with: claudedock egress pin '\(fresh.name)'\n", stderr)
            }
        }
        let created = account
        print("Created account '\(created.name)'")
        print("  Launcher : ~/Applications/Claude \(created.name).app")
        print("  Data Dir : ~/Library/Application Support/\(created.dataDirName)")
        if created.proxy.enabled {
            print("  Proxy    : \(created.proxy.proxyURLString) (TZ: \(created.proxy.timezone ?? "system"))")
        }
        print("  Egress   : \(created.egressPolicy.mode.rawValue) (\(created.egressPolicy.summaryText))")
        if created.cliLinked {
            print("  CLI Cmd  : ~/.claudedock/bin/\(controller.cliLinker.wrapperName(for: created))")
        }
    }

    static func handleList(_ args: [String], controller: DockController) throws {
        let data = try controller.loadData()
        let states = controller.processManager.allRunningStates(for: data.accounts)

        if args.contains("--json") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let bytes = try enc.encode(data.accounts)
            print(String(data: bytes, encoding: .utf8) ?? "[]")
            return
        }

        if data.accounts.isEmpty {
            print("(No accounts yet. Run: claudedock add Work --pin)")
            return
        }

        print(pad("NAME", 16) + pad("STATE", 10) + pad("EGRESS", 22) + pad("5H / 7D", 16) + "PROXY")
        for acc in data.accounts {
            let stateStr: String
            switch states[acc.id] ?? .stopped {
            case .stopped: stateStr = "stopped"
            case .running: stateStr = "running"
            case .frozen: stateStr = "FROZEN"
            }
            let fh = acc.quota?.fiveHour.map { "\(Int($0.usedPercentage))%" } ?? "—"
            let sd = acc.quota?.sevenDay.map { "\(Int($0.usedPercentage))%" } ?? "—"
            let proxyStr = acc.proxy.enabled ? acc.proxy.proxyURLString : "direct"
            print(
                pad(acc.name, 16) +
                pad(stateStr, 10) +
                pad(acc.egressPolicy.summaryText, 22) +
                pad("\(fh) / \(sd)", 16) +
                proxyStr
            )
        }
    }

    static func handleOpen(_ args: [String], controller: DockController) async throws {
        let force = args.contains("--force")
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            throw DockError.accountNotFound("Usage: claudedock open <NAME> [--force]")
        }
        let res = try await controller.openOrFocusAccount(nameOrID: target, forceBypassGuard: force)
        if res.wasAlreadyOpen {
            print("Focused running window for '\(res.account.name)'.")
        } else {
            switch res.verdict {
            case .allowed(let obs):
                print("Egress verified [\(obs.maskedIP) · \(obs.locationLabel)]. Opened '\(res.account.name)'.")
            case .skipped:
                print("Opened '\(res.account.name)'.")
            case .blocked(let reason, _):
                print("Warning (warn-only): \(reason). Opened '\(res.account.name)'.")
            }
        }
    }

    static func handleFocus(_ args: [String], controller: DockController) throws {
        guard let target = args.first else { throw DockError.accountNotFound("Usage: claudedock focus <NAME>") }
        let data = try controller.loadData()
        guard let acc = controller.findAccount(target, in: data.accounts) else { throw DockError.accountNotFound(target) }
        if controller.windowController.focus(account: acc) {
            print("Focused '\(acc.name)'.")
        } else {
            throw DockError.launcherOperationFailed("'\(acc.name)' is not running (or is frozen).")
        }
    }

    static func handleFreeze(_ args: [String], controller: DockController) throws {
        guard let target = args.first else { throw DockError.accountNotFound("Usage: claudedock freeze <NAME>") }
        let data = try controller.loadData()
        guard let acc = controller.findAccount(target, in: data.accounts) else { throw DockError.accountNotFound(target) }
        let n = controller.windowController.freeze(account: acc)
        print("Frozen '\(acc.name)' (\(n) process(es) stopped via SIGSTOP).")
    }

    static func handleResume(_ args: [String], controller: DockController) async throws {
        let force = args.contains("--force")
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            throw DockError.accountNotFound("Usage: claudedock resume <NAME> [--force]")
        }
        let data = try controller.loadData()
        guard let acc = controller.findAccount(target, in: data.accounts) else { throw DockError.accountNotFound(target) }
        var verified = acc
        if !force {
            _ = try await controller.egressGuard.verifyBeforeLaunch(account: acc)
            // The check suspended; never SIGCONT against a proxy/policy it didn't verify.
            verified = try controller.revalidated(acc)
        }
        let n = controller.windowController.resume(account: verified)
        await controller.egressGuard.clearAlert(for: acc.id)
        print("Resumed '\(acc.name)' (\(n) process(es) continued via SIGCONT).")
    }

    static func handleQuit(_ args: [String], controller: DockController) throws {
        guard let target = args.first else { throw DockError.accountNotFound("Usage: claudedock quit <NAME>") }
        let data = try controller.loadData()
        guard let acc = controller.findAccount(target, in: data.accounts) else { throw DockError.accountNotFound(target) }
        let ok = controller.windowController.quit(account: acc)
        print(ok ? "Quit '\(acc.name)'." : "Sent quit signal to '\(acc.name)'.")
    }

    static func handleRemove(_ args: [String], controller: DockController) throws {
        let deleteData = args.contains("--delete-data")
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            throw DockError.accountNotFound("Usage: claudedock remove <NAME> [--delete-data]")
        }
        let removed = try controller.removeAccount(nameOrID: target, deleteData: deleteData)
        print("Removed account '\(removed.name)'\(deleteData ? " and deleted its data folder." : " (sign-in data preserved).")")
    }

    static func handleEgress(_ args: [String], controller: DockController) async throws {
        guard let sub = args.first else {
            throw DockError.invalidProxyConfig("Usage: claudedock egress [probe|check|pin] ...")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "probe":
            let proxy: ProxyConfig
            if let raw = try optionValue("--proxy", in: rest) {
                proxy = try parseProxyURL(raw)
            } else {
                let port = ClashVergeHelper.detect()?.mixedPort ?? 7897
                proxy = ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: port)
            }
            let obs = try await controller.egressProber.probe(proxy: proxy)
            print("Proxy    : \(proxy.proxyURLString)")
            print("IP       : \(obs.ip)")
            print("Location : \(obs.locationLabel)")
            print("Timezone : \(obs.timezone ?? "—")")
            print("Org      : \(obs.org ?? "—")")
            print("Provider : \(obs.provider)")

        case "check":
            guard let target = rest.first else { throw DockError.accountNotFound("Usage: claudedock egress check <NAME>") }
            let data = try controller.loadData()
            guard let acc = controller.findAccount(target, in: data.accounts) else { throw DockError.accountNotFound(target) }
            let verdict = try await controller.egressGuard.verifyBeforeLaunch(account: acc)
            switch verdict {
            case .allowed(let obs):
                print("PASS [\(acc.name)]: \(obs.maskedIP) · \(obs.locationLabel) · TZ=\(obs.timezone ?? "—")")
            case .skipped:
                print("SKIPPED [\(acc.name)]: Egress Guard is disabled.")
            case .blocked(let reason, _):
                throw DockError.egressBlocked(account: acc.name, reason: reason)
            }

        case "pin":
            let exact = rest.contains("--exact-ip")
            guard let target = rest.first(where: { !$0.hasPrefix("-") }) else {
                throw DockError.accountNotFound("Usage: claudedock egress pin <NAME> [--exact-ip]")
            }
            let (saved, obs) = try await controller.pinCurrentEgress(for: target, pinExactIP: exact)
            print("Pinned egress for '\(saved.name)':")
            print("  Location : \(obs.locationLabel) (TZ: \(obs.timezone ?? "—"))")
            print("  Policy   : \(saved.egressPolicy.mode.rawValue) · \(saved.egressPolicy.summaryText)")
        default:
            throw DockError.invalidProxyConfig("Unknown egress subcommand '\(sub)'")
        }
    }

    static func handleClash(_ args: [String], controller: DockController) throws {
        guard let sub = args.first else {
            throw DockError.invalidProxyConfig("Usage: claudedock clash [detect|merge]")
        }
        switch sub {
        case "detect":
            guard let info = ClashVergeHelper.detect() else {
                print("Clash Verge configuration directory not found on this Mac.")
                return
            }
            print("Clash Verge Detected:")
            print("  Config Dir     : \(info.configDirectory.path)")
            print("  Mixed Port     : \(info.mixedPort)")
            print("  TUN Mode       : \(info.tunEnabled ? "ON" : "OFF")")
            print("  System Proxy   : \(info.systemProxyEnabled ? "ON" : "OFF")")
            print("  Active Profile : \(info.activeProfileName ?? "(unknown)")")
            print("  All Profiles   : \(info.profileNames.isEmpty ? "(none)" : info.profileNames.joined(separator: ", "))")

        case "merge":
            let clash = ClashVergeHelper.detect()
            var nodeName = clash?.activeProfileName?.replacingOccurrences(of: ".yaml", with: "") ?? "Your-Dedicated-Node"
            if let node = try optionValue("--node", in: args) {
                nodeName = node
            }
            let accounts = (try? controller.loadData().accounts) ?? []
            print(ClashVergeHelper.generateMergeYAML(for: accounts, defaultProxyName: nodeName, mixedPort: clash?.mixedPort ?? 7897))
        default:
            throw DockError.invalidProxyConfig("Unknown clash subcommand '\(sub)'")
        }
    }

    static func handleQuota(_ args: [String], controller: DockController) async throws {
        let force = args.contains("--force")
        let target = args.first(where: { !$0.hasPrefix("-") })
        let data = try controller.loadData()
        let targets: [AccountProfile]
        if let target {
            guard let acc = controller.findAccount(target, in: data.accounts) else { throw DockError.accountNotFound(target) }
            targets = [acc]
        } else {
            targets = data.accounts
        }
        for acc in targets {
            let updated = try await controller.refreshIdentityAndQuota(for: acc.id, force: force)
            let fh = updated.quota?.fiveHour.map { "\(Int($0.usedPercentage))% (resets \($0.resetCountdownString()))" } ?? "—"
            let sd = updated.quota?.sevenDay.map { "\(Int($0.usedPercentage))% (resets \($0.resetCountdownString()))" } ?? "—"
            print("\(updated.name) [\(updated.identity?.email ?? "unverified")]: 5h=\(fh) | 7d=\(sd) | status=\(updated.quota?.status.rawValue ?? "none")")
            if let note = updated.quota?.errorMessage, !note.isEmpty {
                print("  note: \(note)")
            }
        }
    }

    static func handleRecommend(_ args: [String], controller: DockController) throws {
        let group = try optionValue("--group", in: args)
        let data = try controller.loadData()
        guard let best = AccountScheduler.recommendAccount(from: data.accounts, requiredGroup: group, mode: data.settings.schedulingMode) else {
            print("No eligible account found.")
            return
        }
        let headroom = best.quota?.effectiveHeadroom().map { "\(Int($0))% remaining" } ?? "quota unknown"
        print("Recommended: \(best.name) (\(headroom))")
    }

    static func handleSync(_ args: [String], controller: DockController) throws {
        guard args == ["mcp"] else {
            throw DockError.launcherOperationFailed("Usage: claudedock sync mcp")
        }
        let data = try controller.loadData()
        let report = try controller.configSyncEngine.syncDesktopMCPConfigs(accounts: data.accounts)
        print("Desktop MCP three-way sync complete (\(report.mergedMCPServerCount) shared server(s)).")
        if !report.syncedAccounts.isEmpty {
            print("  Updated : \(report.syncedAccounts.joined(separator: ", "))")
        }
        for w in report.warnings {
            print("  Note    : \(w)")
        }
    }

    static func handlePeers(controller: DockController) throws {
        let data = try controller.loadData()
        let sessions = controller.sessionRadar.discoverLiveSessions(accounts: data.accounts)
        if sessions.isEmpty {
            print("No running Claude Code sessions detected.")
            return
        }
        print(pad("ACCOUNT", 16) + pad("STATUS", 10) + pad("PID", 8) + "SESSION")
        for s in sessions {
            print(pad(s.accountName, 16) + pad(s.status, 10) + pad("\(s.pid)", 8) + s.name)
        }
    }

    static func handleHandoff(_ args: [String]) throws {
        let cwd = try optionValue("--cwd", in: args)
        var positional = args
        if let idx = positional.firstIndex(of: "--cwd") { positional.removeSubrange(idx...min(idx + 1, positional.count - 1)) }
        guard positional.count >= 3 else {
            throw DockError.launcherOperationFailed("Usage: claudedock handoff <FROM_ACCOUNT> <TO_ACCOUNT> <SUMMARY> [--cwd <PATH>]")
        }
        print(SessionRadar.buildHandoffBrief(fromAccount: positional[0], toAccount: positional[1], taskSummary: positional[2...].joined(separator: " "), workingDirectory: cwd))
    }

    static func handleUpdateGuard(_ args: [String], controller: DockController) async throws {
        guard let sub = args.first else {
            throw DockError.launcherOperationFailed("Usage: claudedock update-guard [start|restore]")
        }
        switch sub {
        case "start":
            let res = try controller.startUpdateGuard()
            print("Saved open accounts: \(res.savedNames.isEmpty ? "(none)" : res.savedNames.joined(separator: ", "))")
            print(res.allClosed ? "All Claude Desktop windows closed. Safe to update Claude.app now!" : "Warning: some Claude windows are still open.")
        case "restore":
            let result = try await controller.restoreAfterUpdate()
            print("Restored accounts: \(result.restored.isEmpty ? "(none)" : result.restored.joined(separator: ", "))")
            for (name, reason) in result.failed {
                fputs("Failed restoring '\(name)': \(reason)\n", stderr)
            }
        default:
            throw DockError.launcherOperationFailed("Unknown update-guard action '\(sub)'")
        }
    }

    /// Dynamic CLI launcher executed by thin `claude-<slug>` wrappers.
    /// Loads latest stored config, enforces Fail-Closed Egress Guard, applies clean proxy env, and replaces process via `execve`.
    static func handleCLIRun(_ args: [String], controller: DockController) async throws {
        guard let accountRef = args.first else {
            throw DockError.accountNotFound("Usage: claudedock cli-run <ACCOUNT_ID_OR_NAME> [-- claude-args...]")
        }
        var passthrough = Array(args.dropFirst())
        if passthrough.first == "--" {
            passthrough.removeFirst()
        }

        let data = try controller.loadData()
        guard let account = controller.findAccount(accountRef, in: data.accounts) else {
            throw DockError.accountNotFound(accountRef)
        }
        guard let cliURL = controller.claudeCLIURL() else {
            throw DockError.claudeCLINotFound
        }

        _ = try await controller.egressGuard.verifyBeforeLaunch(account: account)
        // Build the environment from what was verified, and only if it is still what's stored.
        let verified = try controller.revalidated(account)
        let env = controller.identityObserver.buildCLIEnvironment(for: verified)

        // Remember which account works where, so the Projects view can attribute sessions to accounts.
        var resumed: String?
        if let resumeArg = passthrough.first(where: { $0.hasPrefix("--resume=") }) {
            resumed = String(resumeArg.dropFirst("--resume=".count))
        } else if let i = passthrough.firstIndex(where: { $0 == "--resume" || $0 == "-r" }), i + 1 < passthrough.count,
                  !passthrough[i + 1].hasPrefix("-") {
            resumed = passthrough[i + 1]
        } else if passthrough.contains(where: { $0 == "--continue" || $0 == "-c" }) {
            // --continue picks up the newest session in this folder; record it so the Projects view shows who ran it last.
            resumed = ProjectCatalog.latestSessionID(cwd: FileManager.default.currentDirectoryPath)
        }
        controller.sessionLedger.append(SessionLedger.Entry(
            accountID: account.id,
            cwd: FileManager.default.currentDirectoryPath,
            resumedSessionID: resumed
        ))

        let argvStrings = [cliURL.path] + passthrough
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        let cArgv = argvStrings.map { strdup($0) } + [nil]
        let cEnv = envStrings.map { strdup($0) } + [nil]
        defer {
            for p in cArgv { free(p) }
            for p in cEnv { free(p) }
        }
        execve(cliURL.path, cArgv, cEnv)
        let code = errno
        throw DockError.launcherOperationFailed("Could not start \(cliURL.path): \(String(cString: strerror(code)))")
    }

    /// Lists projects and their recent Claude Code sessions across all accounts.
    static func handleProjects(_ args: [String], controller: DockController) throws {
        let accounts = try controller.loadData().accounts
        let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let projects = controller.scanProjects(accounts: accounts)
        let limit = args.contains("--all") ? Int.max : 15
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        for p in projects.prefix(limit) {
            let who = p.lastAccountID.flatMap { names[$0] }.map { " · last used by \($0)" } ?? ""
            print("\(p.name)  (\(p.sessions.count) sessions, \(rel.localizedString(for: p.lastActivity, relativeTo: Date()))\(who))")
            print("  \((p.path as NSString).abbreviatingWithTildeInPath)")
            for sess in p.sessions.prefix(3) {
                print("    \(sess.id.prefix(8))  \(sess.title)")
            }
        }
        if projects.count > limit { print("… \(projects.count - limit) more (use --all)") }
        print("Resume any session with any account:  cd <project> && claude-<account> --resume <session-id>")
    }

    static func parseProxyURL(_ raw: String) throws -> ProxyConfig {
        guard let url = URL(string: raw),
              let schemeStr = url.scheme?.lowercased(),
              let host = url.host,
              let port = url.port else {
            throw DockError.invalidProxyConfig("Expected scheme://host:port (e.g. http://127.0.0.1:7897), got '\(raw)'")
        }
        let scheme: ProxyScheme
        switch schemeStr {
        case "http": scheme = .http
        case "socks5", "socks5h": scheme = .socks5
        default:
            throw DockError.invalidProxyConfig("Unsupported proxy scheme '\(schemeStr)'. Use http:// or socks5://")
        }
        if url.user != nil || url.password != nil {
            throw DockError.invalidProxyConfig("Proxy credentials in the URL aren't supported; use a local proxy port instead.")
        }
        let cfg = ProxyConfig(enabled: true, scheme: scheme, host: host, port: port)
        try Validation.validateProxy(cfg)
        return cfg
    }

    /// Value after `flag`, nil when the flag is absent; throws when the flag is present without a value.
    static func optionValue(_ flag: String, in args: [String]) throws -> String? {
        guard let idx = args.firstIndex(of: flag) else { return nil }
        guard idx + 1 < args.count, !args[idx + 1].hasPrefix("--") else {
            throw DockError.launcherOperationFailed("\(flag) requires a value")
        }
        return args[idx + 1]
    }

    static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return String(s.prefix(width - 1)) + " " }
        return s + String(repeating: " ", count: width - s.count)
    }

    static func printUsage() {
        print("""
        ClaudeDock \(DockConstants.version) — Native macOS Claude Desktop Multi-Account Workbench + Clash Egress Guard

        Usage:
          claudedock add <NAME> [--default] [--pin] [--proxy http://127.0.0.1:7897] [--pin-ip IP] [--region R] [--tz TZ]
                                                   --pin: use the detected local proxy and lock to its current exit
          claudedock list [--json]
          claudedock open <NAME> [--force]         Verify Egress Guard & open/focus Claude Desktop window
          claudedock focus <NAME>                  Bring specific account window to foreground by PID
          claudedock freeze <NAME>                 Freeze process tree (SIGSTOP) to prevent leaks
          claudedock resume <NAME> [--force]       Re-verify egress & resume frozen window (SIGCONT)
          claudedock quit <NAME> | quit-all        Gracefully quit one or all Claude Desktop windows
          claudedock remove <NAME> [--delete-data] Remove launcher (and optionally data folder)

          claudedock egress probe [--proxy URL]    Probe real exit IP/region/timezone via proxy
          claudedock egress check <NAME>           Run Fail-Closed Egress Guard check for an account
          claudedock egress pin <NAME> [--exact-ip] Lock current proxy egress region/TZ (or exact IP)
          claudedock clash detect                  Inspect local Clash Verge ports & profiles
          claudedock clash merge [--node NAME]     Generate Clash Verge Multi-Listener Merge YAML

          claudedock quota [NAME] [--force]        Zero-token 5h/7d quota check via Claude CLI
          claudedock recommend [--group NAME]      Recommend best account by remaining headroom
          claudedock sync mcp                      Three-way merge Desktop MCP servers across accounts
          claudedock peers                         List live Claude Code sessions across accounts
          claudedock projects [--all]              Projects and sessions from every account (resume with any account)
          claudedock handoff <FROM> <TO> <TASK>    Generate structured cross-account handoff brief
          claudedock update-guard start|restore    Safe Claude.app update helper
        """)
    }
}
