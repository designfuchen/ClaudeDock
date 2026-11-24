import Foundation

/// High-level unified facade shared by both `claudedock` CLI and `ClaudeDockApp` (SwiftUI Menu Bar App).
public final class DockController: Sendable {
    public let homeDirectory: URL
    public let store: ProfileStore
    public let processManager: ProcessManager
    public let windowController: WindowController
    public let launcherBuilder: LauncherBuilder
    public let egressProber: EgressProber
    public let egressGuard: EgressGuard
    public let identityObserver: IdentityObserver
    public let quotaEngine: QuotaEngine
    public let cliLinker: CLILinker
    public let configSyncEngine: ConfigSyncEngine
    public let sessionRadar: SessionRadar
    public let coordinator: OAuthAndUpdateCoordinator

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        storeRoot: URL? = nil,
        appsDirectory: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        let resolvedStore = ProfileStore(rootDirectory: storeRoot ?? homeDirectory.appendingPathComponent(".claudedock", isDirectory: true))
        self.store = resolvedStore
        self.processManager = ProcessManager(homeDirectory: homeDirectory)
        self.windowController = WindowController(processManager: self.processManager)
        self.launcherBuilder = LauncherBuilder(homeDirectory: homeDirectory, appsDirectory: appsDirectory)
        self.egressProber = EgressProber()
        self.egressGuard = EgressGuard(prober: self.egressProber, processManager: self.processManager, windowController: self.windowController)
        self.identityObserver = IdentityObserver(homeDirectory: homeDirectory)
        self.quotaEngine = QuotaEngine(identityObserver: self.identityObserver)
        self.cliLinker = CLILinker(homeDirectory: homeDirectory)
        self.configSyncEngine = ConfigSyncEngine(homeDirectory: homeDirectory)
        self.sessionRadar = SessionRadar(homeDirectory: homeDirectory)
        self.coordinator = OAuthAndUpdateCoordinator(processManager: self.processManager, windowController: self.windowController)
    }

    public func loadData() throws -> DockStoreData {
        try store.load()
    }

    public func claudeAppURL() throws -> URL {
        let settings = (try? store.load().settings) ?? AppSettings()
        guard let url = LauncherBuilder.locateClaudeApp(customPath: settings.claudeAppPath, homeDirectory: homeDirectory) else {
            throw DockError.claudeAppNotFound
        }
        return url
    }

    public func claudeCLIURL() -> URL? {
        let settings = (try? store.load().settings) ?? AppSettings()
        return IdentityObserver.locateClaudeCLI(customPath: settings.claudeCLIPath, homeDirectory: homeDirectory)
    }

    // MARK: - Account CRUD

    @discardableResult
    public func addAccount(
        name: String,
        isDefault: Bool = false,
        iconStyle: IconStyle = .claudeBadge,
        colorHex: String? = nil,
        proxy: ProxyConfig? = nil,
        egressPolicy: EgressPolicy? = nil,
        handoffGroup: String? = "default",
        cliLinked: Bool = true,
        createLauncher: Bool = true
    ) throws -> AccountProfile {
        try Validation.validateAccountName(name)
        let resolvedColor: String
        if let raw = colorHex, !raw.isEmpty {
            resolvedColor = try Validation.normalizeColorHex(raw)
        } else {
            resolvedColor = AccountProfile.defaultColorHex(for: name)
        }

        let resolvedProxy = proxy ?? ProxyConfig(enabled: false)
        if resolvedProxy.enabled {
            try Validation.validateProxy(resolvedProxy)
        }
        let resolvedPolicy = egressPolicy ?? EgressPolicy()

        let created = try store.mutate { data -> AccountProfile in
            if data.accounts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw DockError.accountAlreadyExists(name)
            }
            // Different names can share a slug ("Pro 2" / "pro-2"), which would share a CLI login folder.
            let slug = AccountProfile(name: name).slug
            if let clash = data.accounts.first(where: { $0.slug == slug }) {
                throw DockError.invalidAccountName("'\(name)' would share the command name claude-\(slug) with '\(clash.name)'")
            }
            if isDefault, let existing = data.accounts.first(where: \.isDefault) {
                throw DockError.defaultAccountAlreadyExists(existing.name)
            }
            let nextOrder = (data.accounts.map(\.sortOrder).max() ?? -1) + 1
            var profile = AccountProfile(
                name: name,
                isDefault: isDefault,
                iconStyle: iconStyle,
                colorHex: resolvedColor,
                sortOrder: nextOrder,
                handoffGroup: handoffGroup,
                proxy: resolvedProxy,
                egressPolicy: resolvedPolicy,
                cliLinked: cliLinked
            )
            // Named by the account's ID, so a later rename never touches the Claude Code login.
            if !isDefault { profile.cliDirName = profile.stableCLIDirName }
            data.accounts.append(profile)
            return profile
        }

        if createLauncher, let appURL = try? claudeAppURL() {
            _ = try launcherBuilder.createOrUpdateLauncher(for: created, claudeAppURL: appURL)
        }
        if created.cliLinked {
            let settings = (try? store.load().settings) ?? AppSettings()
            _ = try? cliLinker.installWrapper(for: created, shareResources: settings.shareClaudeCodeResources, shareSessions: settings.shareClaudeCodeSessions)
        }
        return created
    }

    @discardableResult
    public func updateAccount(_ updated: AccountProfile, rebuildLauncher: Bool = true) throws -> AccountProfile {
        try Validation.validateAccountName(updated.name)
        if updated.proxy.enabled {
            try Validation.validateProxy(updated.proxy)
        }

        let (old, committed): (AccountProfile, AccountProfile) = try store.mutate { data in
            guard let idx = data.accounts.firstIndex(where: { $0.id == updated.id }) else {
                throw DockError.accountNotFound(updated.name)
            }
            let prev = data.accounts[idx]
            if prev.name.caseInsensitiveCompare(updated.name) != .orderedSame &&
                data.accounts.contains(where: { $0.id != updated.id && $0.name.caseInsensitiveCompare(updated.name) == .orderedSame }) {
                throw DockError.accountAlreadyExists(updated.name)
            }
            if let clash = data.accounts.first(where: { $0.id != updated.id && $0.slug == updated.slug }) {
                throw DockError.invalidAccountName("'\(updated.name)' would share the command name claude-\(updated.slug) with '\(clash.name)'")
            }
            if updated.isDefault && !prev.isDefault, let existing = data.accounts.first(where: { $0.id != updated.id && $0.isDefault }) {
                throw DockError.defaultAccountAlreadyExists(existing.name)
            }
            // Refuse mutating active proxy transport while Claude Desktop is still running with the old proxy.
            // The bypass list is a launch argument too, so it only takes effect after a restart.
            let transportChanged = prev.proxy.enabled != updated.proxy.enabled
                || prev.proxy.scheme != updated.proxy.scheme
                || prev.proxy.host != updated.proxy.host
                || prev.proxy.port != updated.proxy.port
                || (updated.proxy.enabled && prev.proxy.bypassList != updated.proxy.bypassList)
            if transportChanged && processManager.runningState(for: prev).isActive {
                throw DockError.accountStillRunning("\(prev.name) (quit its window before changing proxy settings so the new proxy actually takes effect)")
            }
            // Updates carry configuration only: keep the freshest runtime observations from disk,
            // and drop the egress measurement when the proxy transport changed — it described a different exit.
            var merged = updated
            merged.identity = prev.identity
            merged.quota = prev.quota
            merged.lastEgress = transportChanged ? nil : prev.lastEgress

            // The Claude Code folder is fixed per account and never follows the name. Editors can't change it;
            // a not-yet-migrated profile keeps the folder it already uses (its pre-rename slug).
            merged.cliDirName = prev.isDefault ? prev.cliDirName : (prev.cliDirName ?? prev.slug)
            data.accounts[idx] = merged
            return (prev, merged)
        }

        if rebuildLauncher, let appURL = try? claudeAppURL() {
            if old.name != committed.name {
                _ = try launcherBuilder.renameLauncher(from: old, to: committed, claudeAppURL: appURL)
            } else {
                _ = try launcherBuilder.createOrUpdateLauncher(for: committed, claudeAppURL: appURL)
            }
        }
        // The slug is also the command name: drop the old `claude-<slug>` wrapper.
        if old.slug != committed.slug {
            cliLinker.removeWrapper(for: old)
        }
        if committed.cliLinked {
            let settings = (try? store.load().settings) ?? AppSettings()
            _ = try? cliLinker.installWrapper(for: committed, shareResources: settings.shareClaudeCodeResources, shareSessions: settings.shareClaudeCodeSessions)
        } else {
            cliLinker.removeWrapper(for: old)
        }
        return committed
    }

    public func removeAccount(nameOrID: String, deleteData: Bool = false) throws -> AccountProfile {
        let data = try store.load()
        guard let account = findAccount(nameOrID, in: data.accounts) else {
            throw DockError.accountNotFound(nameOrID)
        }
        // ALWAYS require termination before removing an account (even when retaining data)
        // so an active Claude window is never orphaned from Egress Watchdog.
        if processManager.runningState(for: account).isActive {
            throw DockError.accountStillRunning(account.name)
        }
        if deleteData && (account.isDefault || account.dataDirName == "Claude") {
            throw DockError.cannotDeleteDefaultData
        }

        if deleteData {
            let dir = account.userDataDirectory(homeDirectory: homeDirectory)
            guard dir.lastPathComponent.hasPrefix("Claude-") else {
                throw DockError.cannotDeleteDefaultData
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: dir.path) {
                try fm.removeItem(at: dir)
            }
            let cliDir = account.cliConfigDirectory(homeDirectory: homeDirectory)
            if !account.isDefault && fm.fileExists(atPath: cliDir.path) {
                try fm.removeItem(at: cliDir)
            }
        }

        try? launcherBuilder.removeLauncher(for: account)
        cliLinker.removeWrapper(for: account)

        try store.mutate { storeData in
            storeData.accounts.removeAll { $0.id == account.id }
        }
        return account
    }

    public func findAccount(_ nameOrID: String, in accounts: [AccountProfile]) -> AccountProfile? {
        accounts.first { $0.id == nameOrID } ??
        accounts.first { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame } ??
        accounts.first { $0.slug.caseInsensitiveCompare(nameOrID) == .orderedSame }
    }

    // MARK: - Launch / Focus / Freeze / Resume / Quit

    /// Verifies Egress Guard (Fail-Closed if configured) and launches or focuses the account's Claude Desktop window.
    @discardableResult
    public func openOrFocusAccount(nameOrID: String, forceBypassGuard: Bool = false) async throws -> (account: AccountProfile, verdict: EgressVerdict, wasAlreadyOpen: Bool) {
        let data = try store.load()
        guard let account = findAccount(nameOrID, in: data.accounts) else {
            throw DockError.accountNotFound(nameOrID)
        }

        let state = processManager.runningState(for: account)
        if state.isActive {
            if state.isFrozen {
                // Re-verify egress before unfreezing.
                let verdict = forceBypassGuard ? .skipped : try await egressGuard.verifyBeforeLaunch(account: account)
                // The probe suspended for seconds: what was verified must still be what is stored.
                let latest = try revalidated(account)
                if case .allowed(let obs) = verdict {
                    saveObservation(obs, for: account.id)
                }
                _ = windowController.resume(account: latest)
                await egressGuard.clearAlert(for: account.id)
                _ = windowController.focus(account: latest)
                return (latest, verdict, true)
            }
            _ = windowController.focus(account: account)
            return (account, .skipped, true)
        }

        let verdict: EgressVerdict
        if forceBypassGuard {
            verdict = .skipped
        } else {
            verdict = try await egressGuard.verifyBeforeLaunch(account: account)
            if case .allowed(let obs) = verdict {
                saveObservation(obs, for: account.id)
            }
        }

        // Re-validate latest stored account after suspension so concurrent edits/removals are never ignored.
        let latestAccount = try revalidated(account)

        let appURL = try claudeAppURL()
        try launcherBuilder.launchClaudeDesktopDirect(account: latestAccount, claudeAppURL: appURL)
        return (latestAccount, verdict, false)
    }

    /// Re-reads `account` after an `await` and fails if it was removed or its proxy/egress policy changed,
    /// so a verification result is never applied to a configuration it did not check.
    public func revalidated(_ account: AccountProfile) throws -> AccountProfile {
        guard let latest = try store.load().accounts.first(where: { $0.id == account.id }) else {
            throw DockError.accountNotFound(account.name)
        }
        if latest.proxy != account.proxy || latest.egressPolicy != account.egressPolicy {
            throw DockError.egressBlocked(account: latest.name, reason: "Account proxy or egress policy changed during pre-launch check; please retry.")
        }
        return latest
    }

    /// Moves Claude Code folders from the old name-based layout (`cli-profiles/<slug>`) to the stable
    /// `cli-profiles/<account id>`. Safe to call on every launch: it only touches accounts that need it,
    /// and skips (to retry later) any account whose folder is in use — a running window, a live Claude Code
    /// session, or an occupied destination. Returns the names of accounts that were moved.
    @discardableResult
    public func migrateCLIProfileDirectories() -> [String] {
        func needsWork(_ acc: AccountProfile) -> Bool { !acc.isDefault && acc.cliDirName != acc.stableCLIDirName }
        guard let snapshot = try? store.load(), snapshot.accounts.contains(where: needsWork) else { return [] }
        let fm = FileManager.default
        return (try? store.mutate { data -> [String] in
            var moved: [String] = []
            for idx in data.accounts.indices where needsWork(data.accounts[idx]) {
                let acc = data.accounts[idx]
                let from = acc.cliConfigDirectory(homeDirectory: homeDirectory)
                var target = acc
                target.cliDirName = acc.stableCLIDirName
                let to = target.cliConfigDirectory(homeDirectory: homeDirectory)
                guard fm.fileExists(atPath: from.path) else {
                    // Nothing on disk yet: just adopt the stable name.
                    data.accounts[idx].cliDirName = acc.stableCLIDirName
                    continue
                }
                if fm.fileExists(atPath: to.path) { continue }
                if processManager.runningState(for: acc).isActive { continue }
                if Self.hasLiveClaudeCodeSession(in: from) { continue }
                do {
                    try fm.moveItem(at: from, to: to)
                } catch {
                    continue
                }
                data.accounts[idx].cliDirName = acc.stableCLIDirName
                moved.append(acc.name)
            }
            return moved
        }) ?? []
    }

    /// Whether a Claude Code process is still using this config folder (it keeps `sessions/<pid>.json`).
    static func hasLiveClaudeCodeSession(in configDir: URL) -> Bool {
        let sessions = configDir.appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessions.path) else { return false }
        return files.contains { file in
            guard file.hasSuffix(".json"), let pid = Int32(file.dropLast(5)), pid > 0 else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        }
    }

    /// Probes the account's proxy right now and transactionally pins its live IP/Region/Country/Timezone into EgressPolicy.
    public func pinCurrentEgress(
        for nameOrID: String,
        pinExactIP: Bool = false,
        watchdogAction: WatchdogAction = .freeze
    ) async throws -> (account: AccountProfile, observation: EgressObservation) {
        let data = try store.load()
        guard let account = findAccount(nameOrID, in: data.accounts) else {
            throw DockError.accountNotFound(nameOrID)
        }
        var targetProxy = account.proxy
        if !targetProxy.enabled {
            if processManager.runningState(for: account).isActive {
                throw DockError.accountStillRunning("\(account.name) (quit first before enabling proxy pinning so Claude restarts with the bound proxy)")
            }
            let detectedPort = ClashVergeHelper.detect(homeDirectory: homeDirectory)?.mixedPort ?? 7897
            targetProxy = ProxyConfig(enabled: true, scheme: .http, host: "127.0.0.1", port: detectedPort)
        }

        let obs = try await egressProber.probe(proxy: targetProxy)
        if !pinExactIP && obs.country == nil && obs.region == nil && obs.timezone == nil {
            throw DockError.egressBlocked(account: account.name, reason: "The exit was reached but reported no country, region or timezone to pin. Retry, or pin the exact IP instead.")
        }

        // Field-level transactional update after async probe (preserves concurrent name/group/CLI edits!)
        let saved: AccountProfile = try store.mutate { storeData in
            guard let idx = storeData.accounts.firstIndex(where: { $0.id == account.id }) else {
                throw DockError.accountNotFound(account.name)
            }
            var current = storeData.accounts[idx]
            // The probe took seconds; refuse to overwrite a proxy someone edited meanwhile.
            if current.proxy != account.proxy {
                throw DockError.egressBlocked(account: current.name, reason: "Proxy settings changed while probing; please pin again.")
            }
            if !account.proxy.enabled && processManager.runningState(for: current).isActive {
                throw DockError.accountStillRunning("\(current.name) (quit first before enabling proxy pinning so Claude restarts with the bound proxy)")
            }
            current.proxy = targetProxy
            current.proxy.timezone = obs.timezone ?? current.proxy.timezone
            current.egressPolicy = EgressPolicy(
                mode: .failClosed,
                pinnedIP: pinExactIP ? obs.ip : nil,
                pinnedIPPrefix: nil,
                allowedCountries: obs.country.map { [$0] } ?? [],
                allowedRegions: obs.region.map { [$0] } ?? [],
                allowedCities: [],
                allowedTimezones: obs.timezone.map { [$0] } ?? [],
                watchdogEnabled: true,
                watchdogAction: watchdogAction
            )
            current.lastEgress = obs
            storeData.accounts[idx] = current
            return current
        }

        if let appURL = try? claudeAppURL() {
            _ = try? launcherBuilder.createOrUpdateLauncher(for: saved, claudeAppURL: appURL)
        }
        return (saved, obs)
    }

    public func reconcileCLIWrappers(shareResources: Bool, shareSessions: Bool = true) {
        guard let data = try? store.load() else { return }
        for acc in data.accounts where acc.cliLinked {
            _ = try? cliLinker.installWrapper(for: acc, shareResources: shareResources, shareSessions: shareSessions)
        }
    }

    // MARK: - Projects & sessions

    public var sessionLedger: SessionLedger { SessionLedger(homeDirectory: homeDirectory) }

    /// Every place Claude Code keeps transcripts: the shared `~/.claude/projects`, plus any account
    /// whose history is still private (sharing off, or not yet linked).
    public func projectRoots(accounts: [AccountProfile]) -> [URL] {
        var roots = [homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)]
        for acc in accounts where !acc.isDefault {
            let dir = acc.cliConfigDirectory(homeDirectory: homeDirectory).appendingPathComponent("projects", isDirectory: true)
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: dir.path)) != nil
            if !isLink, FileManager.default.fileExists(atPath: dir.path) { roots.append(dir) }
        }
        return roots
    }

    public func scanProjects(accounts: [AccountProfile]) -> [ClaudeProject] {
        ProjectCatalog.scan(projectRoots: projectRoots(accounts: accounts), ledger: sessionLedger.load())
    }

    public func refreshIdentityAndQuota(for nameOrID: String, force: Bool = false) async throws -> AccountProfile {
        let data = try store.load()
        guard var account = findAccount(nameOrID, in: data.accounts) else {
            throw DockError.accountNotFound(nameOrID)
        }
        var cliURL = claudeCLIURL()
        // Reading identity/quota sends this account's credentials to Anthropic. Under a fail-closed policy that
        // must only happen through a verified exit — otherwise read local (Desktop) identity only, and skip quota.
        var egressBlockedReason: String?
        var quotaTouched = false
        if account.egressPolicy.mode == .failClosed {
            do {
                _ = try await egressGuard.verifyBeforeLaunch(account: account)
            } catch {
                egressBlockedReason = error.localizedDescription
                cliURL = nil
            }
        }
        let idObs = await identityObserver.observe(account: account, claudeCLIURL: cliURL)
        account.identity = idObs

        if let reason = egressBlockedReason {
            var q = account.quota ?? QuotaSnapshot(status: .unavailable)
            q.status = q.fiveHour != nil || q.sevenDay != nil ? .cached : .unavailable
            q.errorMessage = "出口未通过检查，暂不读取：\(reason)"
            account.quota = q
            quotaTouched = true
        } else if let cliURL, (account.cliLinked || account.isDefault) {
            let quota = await quotaEngine.refresh(account: account, claudeCLIURL: cliURL, force: force)
            account.quota = quota
            quotaTouched = true
        }

        // Identity-only refreshes must not roll back a quota another refresh wrote meanwhile.
        return try store.mutate { storeData in
            guard let idx = storeData.accounts.firstIndex(where: { $0.id == account.id }) else { return account }
            storeData.accounts[idx].identity = account.identity
            if quotaTouched { storeData.accounts[idx].quota = account.quota }
            return storeData.accounts[idx]
        }
    }

    // MARK: - Update Guard

    public func startUpdateGuard() throws -> (savedNames: [String], allClosed: Bool) {
        let data = try store.load()
        let res = coordinator.prepareForUpdate(accounts: data.accounts)
        // Running it twice (e.g. after a partial restore) must not forget windows that are still waiting.
        let saved: [String] = try store.mutate { storeData in
            var merged = storeData.updateGuardSavedAccounts
            for id in res.savedAccountIDs where !merged.contains(id) { merged.append(id) }
            storeData.updateGuardSavedAccounts = merged
            return merged
        }
        let names = data.accounts.filter { saved.contains($0.id) }.map(\.name)
        return (names, res.allClosed)
    }

    public func restoreAfterUpdate() async throws -> (restored: [String], failed: [(String, String)]) {
        let data = try store.load()
        let savedIDs = data.updateGuardSavedAccounts
        var restored: [String] = []
        var succeededIDs = Set<String>()
        var failed: [(String, String)] = []
        // Persist progress even when cancelled mid-way, so already reopened windows aren't reopened again.
        defer {
            if !succeededIDs.isEmpty {
                try? store.mutate { storeData in
                    storeData.updateGuardSavedAccounts.removeAll { succeededIDs.contains($0) }
                }
            }
        }

        for id in savedIDs {
            if Task.isCancelled { throw CancellationError() }
            guard let acc = data.accounts.first(where: { $0.id == id }) else {
                succeededIDs.insert(id) // Removed account no longer needs restore
                continue
            }
            do {
                _ = try await openOrFocusAccount(nameOrID: acc.id)
                restored.append(acc.name)
                succeededIDs.insert(id)
                try await Task.sleep(for: .milliseconds(700))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed.append((acc.name, error.localizedDescription))
            }
        }
        // Failed IDs stay saved (see defer) so the user can retry after fixing proxy/Clash.
        return (restored, failed)
    }

    private func saveObservation(_ obs: EgressObservation, for accountID: String) {
        try? store.mutate { data in
            if let idx = data.accounts.firstIndex(where: { $0.id == accountID }) {
                data.accounts[idx].lastEgress = obs
            }
        }
    }
}
