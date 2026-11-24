// FILE: ViewModels/DockViewModel.swift
import AppKit
import ClaudeDockCore
import Foundation
import ServiceManagement
import SwiftUI

/// Top-level destinations of the main window, organised by task rather than by module.
enum AppRoute: String, CaseIterable, Identifiable {
    case deck, projects, accounts, network, sharing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deck: return String(localized: "工作台")
        case .accounts: return String(localized: "账号")
        case .projects: return String(localized: "项目")
        case .network: return String(localized: "连接与守护")
        case .sharing: return String(localized: "配置共享")
        }
    }

    var symbol: String {
        switch self {
        case .deck: return "square.grid.2x2"
        case .accounts: return "person.crop.rectangle.stack"
        case .projects: return "folder"
        case .network: return "checkmark.shield"
        case .sharing: return "arrow.triangle.2.circlepath"
        }
    }
}

struct PendingNavigation: Equatable {
    let route: AppRoute
    let accountID: String?
}

/// A Claude Desktop sign-in in progress with the other Claude windows temporarily closed,
/// so the browser's claude:// callback can only reach the account that is signing in.
struct GuidedSignIn: Equatable {
    let accountID: String
    var pausedAccountIDs: [String]
    let startedAt: Date
    /// Whoever was signed in to this account's Desktop before we started (nil for a fresh account).
    var baselineUUID: String?
    /// True while closed windows are being reopened after sign-in finishes or cancels.
    var isRestoring: Bool = false
}

enum PendingConfirmation: Identifiable, Hashable {
    case updateGuard
    case quitAll
    case guidedSignIn(AccountProfile)

    var id: Self { self }
}

/// One-glance summary of measured egress across guarded accounts.
struct GuardSummary {
    let title: String
    let detail: String
    let symbol: String
    let tone: StatusTone
}

/// What ClaudeDock is currently doing for one account. Shown in place, one at a time per account.
enum AccountOperation: Equatable {
    case opening
    case resuming
    case pinning
    case quitting

    var label: String {
        switch self {
        case .opening: return String(localized: "正在检测出口…")
        case .resuming: return String(localized: "重新检测出口…")
        case .pinning: return String(localized: "正在检测出口…")
        case .quitting: return String(localized: "正在退出…")
        }
    }
}

/// Short-lived feedback. Success and info fade on their own; warnings and errors stay until dismissed.
struct Toast: Identifiable, Equatable {
    enum Tone { case success, info, warning, error }
    let id = UUID()
    let text: String
    let tone: Tone

    var isPersistent: Bool { tone == .warning || tone == .error }
}

@MainActor
final class DockViewModel: ObservableObject {
    let controller: DockController
    private let enableBackgroundServices: Bool

    @Published var accounts: [AccountProfile] = []
    @Published var settings: AppSettings = AppSettings()
    @Published var runningStates: [String: RunningState] = [:]
    @Published var activeAlerts: [String: EgressAlert] = [:]
    @Published var quotaAlerts: [QuotaThresholdAlert] = []
    @Published var clashInfo: ClashVergeDetection?
    @Published var liveSessions: [LiveClaudeSession] = []
    @Published var updateGuardSavedCount: Int = 0

    @Published var isBusy: Bool = false
    @Published private(set) var operations: [String: AccountOperation] = [:]
    /// Accounts whose quota is being read. Kept apart from `operations` so reading quota never blocks switching.
    @Published private(set) var quotaRefreshing: Set<String> = []
    /// Set by the account editor while it holds unsaved edits, with a closure that saves them.
    @Published private(set) var unsavedEdits: (() -> Bool)?
    /// A navigation that is waiting because the editor has unsaved edits.
    @Published var pendingNavigation: PendingNavigation?
    @Published var toast: Toast?
    @Published private(set) var registeredHotkeySlots: Set<Int> = []
    /// Ticks with the poll timer so time-based states (stale egress, "x min ago") re-render.
    @Published private(set) var clock = Date()

    // Navigation shared by the main window, the menu bar and the menu commands.
    @Published var route: AppRoute = .deck
    @Published var isAddingAccount = false
    @Published var selectedAccountID: String?
    /// A destructive multi-account action waiting for the user's confirmation in the main window.
    @Published var pendingConfirmation: PendingConfirmation?
    private var pollTick = 0
    @Published var lastSyncReport: SyncReport?

    nonisolated(unsafe) private var startupTask: Task<Void, Never>?
    nonisolated(unsafe) private var pollTimer: Timer?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    nonisolated(unsafe) private var frontAppObserver: NSObjectProtocol?
    private var notifiedQuotaIDs = Set<String>()
    private var lastStoreMtime: Date?
    private var migrationInFlight = false
    private var removingAccountIDs: Set<String> = []
    /// Accounts whose proxy changed while their Desktop process was still running/frozen.
    /// Probes against the new proxy must not mark these verified until the window is restarted.
    @Published private(set) var proxyRestartNeeded: Set<String> = []

    init(controller: DockController = DockController(), enableBackgroundServices: Bool = true) {
        self.controller = controller
        self.enableBackgroundServices = enableBackgroundServices
        reloadFromDisk()
        guard enableBackgroundServices else { return }
        NotificationHelper.requestPermissionIfBundled()
        // Old name-based Claude Code folders move to per-ID folders (skipped while in use, retried while polling).
        migrateCLIProfileDirectoriesInBackground()
        refreshProcessStates()
        refreshLiveSessions()
        refreshClashDetection()
        refreshSharedSkills()
        startPollingAndWatchdog()
        QuickSwitcher.shared.install(vm: self)
        // Read quota shortly after launch, and again whenever the user comes back to the app (e.g. after signing in).
        startupTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.refreshAllQuotas(silent: true)
            self.refreshProjects()
        }
        frontAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in self?.updateFrontAccount(pid: pid) }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Drop sign-ins started more than 15 minutes ago.
                self.awaitingSignIn = self.awaitingSignIn.filter { Date().timeIntervalSince($0.value) < 900 }
                if !self.awaitingSignIn.isEmpty {
                    self.completeSignIns()
                } else if Date().timeIntervalSince(self.lastQuotaSweep ?? .distantPast) > 60 {
                    self.refreshAllQuotas(silent: true)
                }
            }
        }
    }

    deinit {
        startupTask?.cancel()
        pollTimer?.invalidate()
        if let frontAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontAppObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    private var lastQuotaSweep: Date?

    /// The account whose Claude window is the frontmost app right now (nil when another app is in front).
    @Published private(set) var frontAccountID: String?

    private func updateFrontAccount(pid: pid_t?) {
        let id = pid.flatMap { p in runningStates.first(where: { $0.value.pids.contains(p) })?.key }
        if id != frontAccountID { frontAccountID = id }
    }

    /// Menu bar text: the frontmost Claude account's tightest remaining quota, else the running count.
    /// "NY-Main · 剩 8%": the account in front (or the only one open), named so the number can't be misread.
    var menuBarText: String? {
        let acc = frontAccountID.flatMap { id in accounts.first { $0.id == id } }
            ?? (runningAccounts.count == 1 ? runningAccounts.first : nil)
        guard let acc else { return nil }
        guard let h = acc.quota?.effectiveHeadroom(at: clock) else { return acc.name }
        return String(localized: "\(acc.name) · 剩 \(Int(h.rounded()))%")
    }

    private var hasBundledCLI: Bool {
        FileManager.default.isExecutableFile(
            atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/claudedock").path
        )
    }

    func canRunClaudeCode(_ account: AccountProfile) -> Bool {
        hasBundledCLI || account.cliLinked || account.isDefault
    }

    /// Accounts with a usage window whose reset time has passed: shown as "待刷新" until a fresh read confirms it.
    private var accountsAwaitingReset: [AccountProfile] {
        accounts.filter { acc in
            guard canRunClaudeCode(acc), let q = acc.quota else { return false }
            return [q.fiveHour, q.sevenDay].contains { $0?.isExpired(at: clock) == true }
        }
    }
    /// Accounts the user just started a Claude Code sign-in for; re-read their quota when the app is reactivated.
    private var awaitingSignIn: [String: Date] = [:]

    /// Back from the browser: read the quota of accounts that were signing in and say how it went.
    /// An account that still isn't signed in stays pending (the user may just have switched apps mid-login).
    private func completeSignIns() {
        let pending = accounts.filter { awaitingSignIn[$0.id] != nil }
        let controller = self.controller
        for acc in pending {
            guard !quotaRefreshing.contains(acc.id) else { continue }
            quotaRefreshing.insert(acc.id)
            Task {
                let refreshed = (try? await controller.refreshIdentityAndQuota(for: acc.id, force: true)) != nil
                self.quotaRefreshing.remove(acc.id)
                self.reloadFromDisk()
                let quota = self.accounts.first { $0.id == acc.id }?.quota
                // Only a fresh, successful read proves the sign-in worked.
                guard refreshed, let quota, quota.status != .loggedOut, quota.checkedAt > Date().addingTimeInterval(-120) else { return }
                self.awaitingSignIn.removeValue(forKey: acc.id)
                if quota.fiveHour != nil || quota.sevenDay != nil {
                    self.showToast(String(localized: "\(acc.name) 已登录 Claude Code，额度已更新"), .success)
                } else {
                    self.showToast(String(localized: "\(acc.name) 已登录，但暂无法获取额度"), .warning)
                }
            }
        }
    }

    /// Opens Terminal and signs this account's Claude Code in, through the account's own isolated config and proxy.
    /// Quota can only be read through a signed-in Claude Code, even when Claude Desktop is already signed in.
    func signInClaudeCode(for account: AccountProfile) {
        guard let claude = claudeCommand(for: account) else { return }
        // Account names are validated to [A-Za-z0-9 _-]; they are still shell-quoted as defense in depth.
        // When sign-in succeeds the script brings ClaudeDock back to the front, which re-reads the quota.
        let body = """
        clear
        echo \(Self.shellQuote("为 \(account.name) 登录 Claude Code。在浏览器里完成授权后，会自动回到 ClaudeDock。"))
        echo
        if \(claude) auth login; then
          echo
          echo '登录成功，正在回到 ClaudeDock…'
          open -b \(Self.shellQuote(Bundle.main.bundleIdentifier ?? "io.claudedock.app"))
          sleep 1
          exit 0
        else
          echo
          echo '登录没有完成。可以关闭这个窗口，回到 ClaudeDock 再试一次。'
        fi
        """
        if runInTerminal(name: "signin-\(account.slug)", body: body) {
            awaitingSignIn[account.id] = Date()
        }
    }

    // MARK: - Projects

    @Published private(set) var projects: [ClaudeProject] = []
    @Published private(set) var isScanningProjects = false

    func refreshProjects() {
        guard !isScanningProjects else { return }
        isScanningProjects = true
        let controller = self.controller
        let accounts = self.accounts
        Task.detached(priority: .utility) {
            let found = controller.scanProjects(accounts: accounts)
            await MainActor.run {
                if self.projects != found { self.projects = found }
                self.isScanningProjects = false
            }
        }
    }

    /// Accounts that can run Claude Code (have a command-line entry or bundled CLI).
    var codeAccounts: [AccountProfile] {
        accounts.filter { canRunClaudeCode($0) }
    }

    /// Who should continue this project: the last account if it still has room, otherwise the best one.
    func suggestedAccount(for project: ClaudeProject) -> AccountProfile? {
        suggestedAccount(lastAccountID: project.lastAccountID)
    }

    /// Keeps the previous account (better prompt-cache reuse) only while it is usable: not paused, exit healthy,
    /// and measured with more than 10% left. Otherwise hands over to the recommended account.
    func suggestedAccount(lastAccountID: String?) -> AccountProfile? {
        // Usable for Claude Code: not paused, exit healthy, and Claude Code actually signed in.
        let pool = codeAccounts.filter {
            runningStates[$0.id]?.isFrozen != true && !egressHealth(for: $0).needsAttention && $0.quota?.status != .loggedOut
        }
        if let last = lastAccountID, let acc = pool.first(where: { $0.id == last }),
           let headroom = acc.quota?.effectiveHeadroom(at: clock), headroom > 10 {
            return acc
        }
        // Prefer accounts whose quota we actually know; "unknown" must never outrank a measured account.
        let known = pool.filter { $0.quota?.effectiveHeadroom(at: clock) != nil }
        if !known.isEmpty {
            return AccountScheduler.recommendAccount(from: known, mode: settings.schedulingMode) ?? known.first
        }
        // All candidates have unknown quota: keep the previous account if available, else fall back.
        if let last = lastAccountID, let acc = pool.first(where: { $0.id == last }) {
            return acc
        }
        // Never fall back to an unhealthy account: no suggestion is better than a paused or mis-routed one.
        return AccountScheduler.recommendAccount(from: pool, mode: settings.schedulingMode) ?? pool.first
    }

    private func tightestHeadroomText(_ account: AccountProfile) -> String? {
        guard let q = account.quota, let total = q.effectiveHeadroom(at: clock) else { return nil }
        let pct = Int(total.rounded())
        let fiveActive = q.fiveHour.map { !$0.isExpired(at: clock) } ?? false
        let sevenActive = q.sevenDay.map { !$0.isExpired(at: clock) } ?? false
        if fiveActive && !sevenActive { return String(localized: "5 小时 剩 \(pct)%") }
        if sevenActive && !fiveActive { return String(localized: "7 天 剩 \(pct)%") }
        if fiveActive && sevenActive {
            var alerts = AccountScheduler.evaluateThresholdAlerts(
                accounts: [account],
                thresholdPercentage: 1,
                mode: .mostHeadroom
            )
            if alerts.isEmpty {
                alerts = AccountScheduler.evaluateThresholdAlerts(
                    accounts: [account],
                    thresholdPercentage: 99,
                    mode: .mostHeadroom
                )
            }
            if let tightest = alerts.max(by: { $0.usedPercentage < $1.usedPercentage }),
               abs((100 - tightest.usedPercentage) - total) < 1.0 {
                return tightest.windowName == "5-hour"
                    ? String(localized: "5 小时 剩 \(pct)%")
                    : String(localized: "7 天 剩 \(pct)%")
            }
        }
        return String(localized: "剩 \(pct)%")
    }

    func headroomText(_ account: AccountProfile) -> String? {
        tightestHeadroomText(account)
    }

    /// Opens Terminal in `path` and starts Claude Code as `account`: resuming a session, continuing the latest, or fresh.
    func launchClaudeCode(account: AccountProfile, in path: String, resume sessionID: String? = nil, continueLatest: Bool = false) {
        guard FileManager.default.fileExists(atPath: path) else {
            showToast(String(localized: "找不到项目文件夹：\((path as NSString).abbreviatingWithTildeInPath)"), .error)
            return
        }
        guard let claude = claudeCommand(for: account) else { return }
        var args = ""
        if let sessionID {
            guard sessionID.range(of: "^[0-9a-fA-F-]{36}$", options: .regularExpression) != nil else { return }
            args = " --resume \(sessionID)"
        } else if continueLatest {
            args = " --continue"
        }
        let what = sessionID != nil ? "继续这个会话" : (continueLatest ? "继续最近的会话" : "开始新会话")
        let body = """
        cd -- \(Self.shellQuote(path)) || exit 1
        clear
        echo \(Self.shellQuote("用 \(account.name) \(what)"))
        echo
        exec \(claude)\(args)
        """
        if runInTerminal(name: "code-\(account.slug)", body: body) {
            let toastMessage: String
            if sessionID != nil {
                toastMessage = String(localized: "已在终端用 \(account.name) 继续这个会话")
            } else if continueLatest {
                toastMessage = String(localized: "已在终端用 \(account.name) 继续最近的会话")
            } else {
                toastMessage = String(localized: "已在终端用 \(account.name) 开始新会话")
            }
            showToast(toastMessage, .success)
        }
    }

    /// The command that runs Claude Code as this account — always through `claudedock cli-run`, so every launch
    /// (including the default account) passes the egress check and gets the account's own environment.
    private func claudeCommand(for account: AccountProfile) -> String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/claudedock")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return "\(Self.shellQuote(bundled.path)) cli-run \(Self.shellQuote(account.id)) --"
        }
        let wrapper = controller.cliLinker.wrapperURL(for: account)
        if FileManager.default.isExecutableFile(atPath: wrapper.path) {
            return Self.shellQuote(wrapper.path)
        }
        showToast(String(localized: "找不到 claudedock 命令，请重新安装 ClaudeDock"), .error)
        return nil
    }

    /// Writes a one-off `.command` script with a unique name (0700, under ~/.claudedock/tmp) and opens it in the
    /// user's terminal. Scripts older than a day are cleaned up.
    @discardableResult
    private func runInTerminal(name: String, body: String) -> Bool {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claudedock/tmp", isDirectory: true)
        // Clean up only our own old scripts: regular files with our name prefixes, never directories or links,
        // and never inside a tmp folder that has been replaced by a symlink.
        if (try? fm.destinationOfSymbolicLink(atPath: dir.path)) == nil,
           let old = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in old where f.pathExtension == "command"
                && (f.lastPathComponent.hasPrefix("code-") || f.lastPathComponent.hasPrefix("signin-")) {
                guard let attrs = try? fm.attributesOfItem(atPath: f.path),
                      (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
                let m = (attrs[.modificationDate] as? Date) ?? .distantPast
                if Date().timeIntervalSince(m) > 86_400 { unlink(f.path) }
            }
        }
        let script = dir.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).command")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = Data(("#!/bin/zsh\n" + body + "\n").utf8)
            guard fm.createFile(atPath: script.path, contents: data, attributes: [.posixPermissions: 0o700]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard NSWorkspace.shared.open(script) else { throw CocoaError(.fileReadUnknown) }
            return true
        } catch {
            showToast(String(localized: "无法打开终端：\(error.localizedDescription)"), .error)
            return false
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var menuBarIconName: String {
        if !activeAlerts.isEmpty || runningStates.values.contains(where: \.isFrozen) {
            return "exclamationmark.shield.fill"
        }
        if !quotaAlerts.isEmpty {
            return "gauge.with.dots.needle.100percent"
        }
        return "square.stack.3d.up.fill"
    }

    /// Menu bar glyph state: badge for anything that needs the user, ring for the best account's remaining quota.
    var menuBarImage: NSImage {
        let badge: MenuBarIcon.Badge
        if menuBarHasWarning || accounts.contains(where: { egressHealth(for: $0).needsAttention }) {
            badge = .attention
        } else if !quotaAlerts.isEmpty {
            badge = .quota
        } else {
            badge = .none
        }
        let best = accounts.compactMap { $0.quota?.effectiveHeadroom(at: clock) }.max()
        return MenuBarIcon.image(badge: badge, remaining: best)
    }

    /// What VoiceOver reads for the menu bar item: running count, anything that needs attention, best quota.
    var menuBarAccessibilitySummary: String {
        var parts = ["ClaudeDock", String(localized: "\(activeRunningCount) 个账号运行中")]
        let attention = accounts.filter {
            egressHealth(for: $0).needsAttention || runningStates[$0.id]?.isFrozen == true
        }.count
        if attention > 0 { parts.append(String(localized: "\(attention) 项需要处理")) }
        if !quotaAlerts.isEmpty { parts.append(String(localized: "\(quotaAlerts.count) 个账号额度偏低")) }
        if let best = accounts.compactMap({ $0.quota?.effectiveHeadroom(at: clock) }).max() {
            parts.append(String(localized: "最多剩余 \(Int(best.rounded()))%"))
        }
        return parts.joined(separator: String(localized: "，"))
    }

    var menuBarHasWarning: Bool {
        !activeAlerts.isEmpty || runningStates.values.contains(where: \.isFrozen)
    }

    var activeRunningCount: Int {
        runningStates.values.filter(\.isActive).count
    }

    func operation(for accountID: String) -> AccountOperation? {
        operations[accountID]
    }

    /// Measured egress state for an account (never inferred from the configured policy alone).
    func egressHealth(for account: AccountProfile) -> EgressHealth {
        EgressHealth.evaluate(
            account: account,
            alert: activeAlerts[account.id],
            freshness: EgressHealth.freshnessWindow(watchdogIntervalSeconds: settings.watchdogIntervalSeconds),
            now: clock
        )
    }

    func showAccount(_ accountID: String) {
        navigate(to: .accounts, account: accountID)
    }

    /// Every route/account change goes through here so unsaved account edits are never dropped silently.
    func navigate(to route: AppRoute, account: String? = nil) {
        let target = PendingNavigation(route: route, accountID: account)
        let current = PendingNavigation(route: self.route, accountID: self.route == .accounts ? resolvedAccountID : nil)
        if target == current || (route == self.route && account == nil) { return }
        if unsavedEdits != nil {
            pendingNavigation = target
        } else {
            apply(target)
        }
    }

    /// The account the account page is showing: the selection if it still exists, otherwise the first.
    var resolvedAccountID: String? {
        if let id = selectedAccountID, accounts.contains(where: { $0.id == id }) { return id }
        return accounts.first?.id
    }

    func setUnsavedEdits(_ save: (() -> Bool)?) {
        unsavedEdits = save
    }

    /// Resolves a pending navigation: save first (stays put if saving fails), discard, or cancel.
    func resolvePendingNavigation(save: Bool?) {
        guard let target = pendingNavigation else { return }
        pendingNavigation = nil
        switch save {
        case .some(true):
            if unsavedEdits?() == true { unsavedEdits = nil; apply(target) }
        case .some(false):
            unsavedEdits = nil
            apply(target)
        case .none:
            break
        }
    }

    private func apply(_ target: PendingNavigation) {
        if let id = target.accountID { selectedAccountID = id }
        withAnimation(DS.Motion.reduceMotion ? .easeOut(duration: 0.12) : DS.Motion.standard) {
            route = target.route
        }
    }

    func isRefreshingQuota(_ accountID: String) -> Bool {
        quotaRefreshing.contains(accountID)
    }

    /// Acknowledges a warn-only incident. The account's chip keeps showing the mismatch until a probe passes.
    func dismissIncident(for accountID: String) {
        activeAlerts.removeValue(forKey: accountID)
        Task { await controller.egressGuard.clearAlert(for: accountID) }
    }

    func requestAddAccount() {
        isAddingAccount = true
    }

    var runningAccounts: [AccountProfile] {
        accounts.filter { runningStates[$0.id]?.isActive == true }
    }

    /// Green only when every running guarded account has a fresh passing measurement.
    var guardSummary: GuardSummary {
        let guarded = accounts.filter { $0.egressPolicy.mode != .disabled }
        guard !guarded.isEmpty else {
            return GuardSummary(title: String(localized: "未开启"), detail: String(localized: "没有账号开启出口守护"), symbol: "shield.slash", tone: .neutral)
        }
        let problems = guarded.filter { egressHealth(for: $0).needsAttention }
        if !problems.isEmpty {
            let names = problems.prefix(2).map(\.name).joined(separator: String(localized: "、"))
            return GuardSummary(title: String(localized: "\(problems.count) 项需要处理"), detail: names, symbol: "xmark.shield.fill", tone: .critical)
        }
        let running = guarded.filter { runningStates[$0.id]?.isActive == true }
        if running.isEmpty {
            return GuardSummary(title: String(localized: "已就绪"), detail: String(localized: "\(guarded.count) 个账号已开启出口守护"), symbol: "shield", tone: .neutral)
        }
        let verified = running.filter { egressHealth(for: $0).isVerified }.count
        if verified == running.count {
            return GuardSummary(title: String(localized: "全部已验证"), detail: String(localized: "\(running.count) 个运行中，出口正常"), symbol: "checkmark.shield.fill", tone: .verified)
        }
        return GuardSummary(title: String(localized: "\(verified)/\(running.count) 已验证"), detail: String(localized: "其余等待下次检测"), symbol: "shield.lefthalf.filled", tone: .caution)
    }

    var hotkeySummary: String {
        guard settings.globalHotkeysEnabled else { return String(localized: "已关闭") }
        let wanted = min(9, accounts.count)
        let got = registeredHotkeySlots.count
        if wanted == 0 { return String(localized: "添加账号后可用") }
        if got == wanted { return got == 1 ? "⌘⌥1" : "⌘⌥1 – ⌘⌥\(got)" }
        return String(localized: "\(got)/\(wanted) 可用，其余被占用")
    }

    /// Why the recommended account is recommended, in one line.
    func recommendationReason(for account: AccountProfile) -> String {
        let headroom = tightestHeadroomText(account)
        switch settings.schedulingMode {
        case .orderPriority:
            return [String(localized: "按列表顺序优先"), headroom].compactMap { $0 }.joined(separator: " · ")
        case .mostHeadroom:
            return headroom.map { String(localized: "剩余额度最多 · \($0)") } ?? String(localized: "额度未知，按列表顺序推荐")
        }
    }

    func hotkeyLabel(forIndex index: Int) -> String? {
        registeredHotkeySlots.contains(index) ? "⌘⌥\(index + 1)" : nil
    }

    /// Runs `work` as the single in-flight operation for an account; a second request is ignored.
    private func perform(_ op: AccountOperation, on accountID: String, _ work: @escaping @MainActor () async -> Void) {
        guard operations[accountID] == nil, !isBulkQuitting, !removingAccountIDs.contains(accountID) else { return }
        operations[accountID] = op
        operationTasks[accountID] = Task {
            await work()
            self.operations[accountID] = nil
            self.operationTasks[accountID] = nil
        }
    }

    private var operationTasks: [String: Task<Void, Never>] = [:]
    /// While set, no account may start opening or resuming — a bulk quit is in progress.
    @Published private(set) var isBulkQuitting = false

    /// Stops new launches, cancels in-flight ones and waits for them to settle, so a bulk quit can't race an open.
    /// Returns `true` if all operations settled within the deadline, `false` on timeout.
    private func drainOperations() async -> Bool {
        isBulkQuitting = true
        for task in operationTasks.values { task.cancel() }
        let deadline = Date().addingTimeInterval(8)
        while !operations.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return operations.isEmpty
    }

    /// Keeps launches gated after a drain timeout until all remaining tasks settle.
    private func releaseBulkQuitWhenSettled() {
        let remaining = Array(operationTasks.values)
        if remaining.isEmpty && operations.isEmpty {
            isBulkQuitting = false
            return
        }
        Task {
            for task in remaining { await task.value }
            if !self.isBusy {
                self.isBulkQuitting = false
            }
        }
    }

    /// The account as it is now, or nil if it changed in a way that invalidates a probe started on `snapshot`.
    private func unchangedSinceProbe(_ snapshot: AccountProfile) -> AccountProfile? {
        guard let current = accounts.first(where: { $0.id == snapshot.id }) else { return nil }
        guard current.proxy == snapshot.proxy, current.egressPolicy == snapshot.egressPolicy else { return nil }
        return current
    }

    var recommendedAccount: AccountProfile? {
        // Never recommend an account that is paused or whose exit currently fails its rule.
        let pool = accounts.filter {
            runningStates[$0.id]?.isFrozen != true && !egressHealth(for: $0).needsAttention
        }
        // Prefer accounts whose quota has been measured so unmeasured shells don't outrank ready accounts.
        let known = pool.filter { $0.quota?.effectiveHeadroom(at: clock) != nil }
        return AccountScheduler.recommendAccount(
            from: known.isEmpty ? pool : known,
            mode: settings.schedulingMode
        )
    }

    // MARK: - Lifecycle & Polling

    func reloadFromDisk() {
        do {
            let data = try controller.loadData()
            let sorted = data.accounts.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
            if self.accounts != sorted { self.accounts = sorted }
            if self.settings != data.settings {
                let intervalChanged = self.settings.watchdogIntervalSeconds != data.settings.watchdogIntervalSeconds
                self.settings = data.settings
                // Changed from the CLI or another window: the running watchdog still has the old interval.
                if intervalChanged { restartWatchdog() }
            }
            if self.updateGuardSavedCount != data.updateGuardSavedAccounts.count {
                self.updateGuardSavedCount = data.updateGuardSavedAccounts.count
            }
            // Alerts for accounts removed (here or from the CLI) can never be resolved; drop them.
            let ids = Set(accounts.map(\.id))
            let unguarded = Set(accounts.filter { $0.egressPolicy.mode == .disabled }.map(\.id))
            for id in activeAlerts.keys where !ids.contains(id) || (unguarded.contains(id) && !proxyRestartNeeded.contains(id)) {
                activeAlerts.removeValue(forKey: id)
                Task { await controller.egressGuard.clearAlert(for: id) }
            }
            if let sel = selectedAccountID, !ids.contains(sel) { selectedAccountID = nil }
            recomputeQuotaAlerts()
            refreshHotkeys()
        } catch {
            showToast(error.localizedDescription, .error)
        }
    }

    private func migrateCLIProfileDirectoriesInBackground() {
        guard !migrationInFlight else { return }
        migrationInFlight = true
        let controller = self.controller
        Task.detached(priority: .utility) {
            controller.migrateCLIProfileDirectories()
            await MainActor.run { self.migrationInFlight = false }
        }
    }

    private var processScanGeneration = 0
    private var processScanInFlight = false

    /// One scan at a time; a result older than the latest requested scan is discarded (no stale overwrite).
    func refreshProcessStates() {
        processScanGeneration &+= 1
        guard !processScanInFlight else { return }
        processScanInFlight = true
        let generation = processScanGeneration
        let currentAccounts = accounts
        let pm = controller.processManager
        Task.detached(priority: .utility) {
            let states = pm.allRunningStates(for: currentAccounts)
            await MainActor.run {
                self.processScanInFlight = false
                // Scans run one at a time, so results arrive in order: always publish (only real changes),
                // and if more was requested meanwhile, scan again — a slow system still gets updates.
                if self.runningStates != states { self.runningStates = states }
                self.updateFrontAccount(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
                // A window that has closed will read the new MCP config next time it opens.
                let stillOpen = self.mcpRestartNeeded.filter { states[$0]?.isActive == true }
                if stillOpen != self.mcpRestartNeeded { self.mcpRestartNeeded = stillOpen }
                // A window that has closed will pick up the updated proxy next time it opens.
                let stillNeedsProxy = self.proxyRestartNeeded.filter {
                    states[$0]?.isActive == true || states[$0]?.isFrozen == true
                }
                if stillNeedsProxy != self.proxyRestartNeeded {
                    let cleared = self.proxyRestartNeeded.subtracting(stillNeedsProxy)
                    self.proxyRestartNeeded = stillNeedsProxy
                    for id in cleared {
                        self.activeAlerts.removeValue(forKey: id)
                        Task { await self.controller.egressGuard.clearAlert(for: id) }
                    }
                }
                if generation != self.processScanGeneration { self.refreshProcessStates() }
            }
        }
    }

    func refreshLiveSessions() {
        let currentAccounts = accounts
        let radar = controller.sessionRadar
        Task.detached(priority: .utility) {
            let found = radar.discoverLiveSessions(accounts: currentAccounts)
            await MainActor.run {
                if self.liveSessions != found { self.liveSessions = found }
            }
        }
    }

    /// Reads Clash Verge's files off the main thread.
    func refreshClashDetection() {
        Task.detached(priority: .utility) {
            let info = ClashVergeHelper.detect()
            await MainActor.run {
                if self.clashInfo != info { self.clashInfo = info }
            }
        }
    }

    private func startPollingAndWatchdog() {
        lastStoreMtime = currentStoreMtime()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pollTick &+= 1
                // Relative times and freshness only need a coarse clock; publishing it re-evaluates every view.
                if self.pollTick % 5 == 0 {
                    self.clock = Date()
                    self.recomputeQuotaAlerts()
                }
                let mtime = self.currentStoreMtime()
                if mtime != self.lastStoreMtime {
                    self.lastStoreMtime = mtime
                    self.reloadFromDisk()
                }
                // Menu bar–only: halve the background polling (the watchdog keeps its own schedule).
                if self.isMainWindowVisible || self.pollTick % 2 == 0 { self.refreshProcessStates() }
                if self.pollTick % 5 == 0 { self.refreshClashDetection() }
                if self.pollTick % 40 == 0 { self.migrateCLIProfileDirectoriesInBackground() }
                // A window just passed its reset: read it again so "已恢复" is confirmed, not assumed (at most once a minute).
                if self.pollTick % 20 == 0 {
                    for acc in self.accountsAwaitingReset { self.refreshQuota(for: acc, force: false, silent: true) }
                }
                if self.pollTick % 3 == 0 { self.refreshLiveSessions() }
                // Projects and shared skills are only scanned while something can show them.
                if self.pollTick % 20 == 0 && self.isMainWindowVisible {
                    self.refreshProjects()
                    self.refreshSharedSkills()
                }
                if self.pollTick % 2 == 0 { self.autoSyncMCPIfNeeded() }
                if self.guidedSignIn != nil { self.checkGuidedSignIn() }
                // Quota is read for free, so keep it current without anyone asking.
                if Date().timeIntervalSince(self.lastQuotaSweep ?? .distantPast) > 300 {
                    self.refreshAllQuotas(silent: true)
                }
            }
        }
        restartWatchdog()
    }

    private func currentStoreMtime() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: controller.store.storeFileURL.path)[.modificationDate] as? Date
    }

    func restartWatchdog() {
        guard enableBackgroundServices else { return }
        let interval = settings.watchdogIntervalSeconds
        let guardEngine = controller.egressGuard
        Task { [weak self] in
            await guardEngine.startWatchdog(
                intervalSeconds: interval,
                accountsProvider: { [weak self] in
                    await MainActor.run { self?.accounts ?? [] }
                },
                onObservation: { [weak self] accountID, obs in
                    await MainActor.run {
                        self?.applyObservation(obs, for: accountID)
                    }
                },
                onAlert: { [weak self] alert in
                    await MainActor.run {
                        self?.handleWatchdogAlert(alert)
                    }
                }
            )
        }
    }

    private func applyObservation(_ obs: EgressObservation, for accountID: String) {
        // A running window still bound to an old proxy must never be marked verified by probing the new proxy.
        guard !proxyRestartNeeded.contains(accountID) else { return }
        guard let idx = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        // A probe that finished after the proxy was changed describes the old exit: drop it.
        guard obs.belongs(to: accounts[idx].proxy) else { return }
        accounts[idx].lastEgress = obs
        try? controller.store.mutate { data in
            if let i = data.accounts.firstIndex(where: { $0.id == accountID }), obs.belongs(to: data.accounts[i].proxy) {
                data.accounts[i].lastEgress = obs
            }
        }
        // Only a passing observation resolves an incident; a mismatching one must keep it open.
        if EgressPolicyEvaluator.evaluate(observation: obs, against: accounts[idx].egressPolicy).isAllowed {
            activeAlerts.removeValue(forKey: accountID)
        }
    }

    private func handleWatchdogAlert(_ alert: EgressAlert) {
        guard accounts.contains(where: { $0.id == alert.accountID }) else { return }
        activeAlerts[alert.accountID] = alert
        refreshProcessStates()
        let body: String
        switch alert.actionTaken {
        case .freeze: body = String(localized: "已自动暂停，避免流量走错出口。\(alert.reason)")
        case .quit: body = String(localized: "已自动安全退出。\(alert.reason)")
        case .notify: body = String(localized: "请检查代理节点是否切错。\(alert.reason)")
        }
        NotificationHelper.send(
            title: String(localized: "ClaudeDock 出口守护：\(alert.accountName)"),
            body: body
        )
    }

    private var hotkeySignature: [String] = []

    /// Re-registers ⌘⌥1–9 only when the account order or the setting changed — not on every data refresh.
    func refreshHotkeys() {
        guard enableBackgroundServices else { return }
        guard settings.globalHotkeysEnabled else {
            GlobalHotkeyManager.shared.unregisterSlots()
            registeredHotkeySlots = []
            hotkeySignature = []
            return
        }
        let signature = accounts.prefix(9).map(\.id)
        guard signature != hotkeySignature else { return }
        hotkeySignature = signature
        registeredHotkeySlots = GlobalHotkeyManager.shared.register(count: min(9, accounts.count)) { [weak self] idx in
            guard let self, idx < self.accounts.count else { return }
            let acc = self.accounts[idx]
            self.openOrFocus(account: acc)
        }
    }

    // MARK: - Actions

    func openOrFocus(account: AccountProfile, forceBypass: Bool = false) {
        // A paused account can't be "focused" — it must pass the exit check and resume first.
        if runningStates[account.id]?.isFrozen == true {
            resume(account: account, forceBypass: forceBypass)
            return
        }
        perform(.opening, on: account.id) {
            guard !Task.isCancelled, !self.isBulkQuitting else { return }
            // macOS 14+ activation is cooperative: hand the foreground to Claude so the switch actually takes.
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.anthropic.claudefordesktop")
            do {
                let res = try await self.controller.openOrFocusAccount(nameOrID: account.id, forceBypassGuard: forceBypass)
                if !res.wasAlreadyOpen {
                    self.proxyRestartNeeded.remove(account.id)
                }
                if forceBypass {
                    // The user explicitly accepted this one launch; the incident is acknowledged,
                    // but nothing was measured, so the account must not look verified.
                    await self.controller.egressGuard.clearAlert(for: account.id)
                    if !self.proxyRestartNeeded.contains(account.id) {
                        self.activeAlerts.removeValue(forKey: account.id)
                    }
                    self.invalidateEgressMeasurement(for: account.id)
                }
                self.reloadFromDisk()
                self.refreshProcessStates()
                switch res.verdict {
                case .allowed(let obs):
                    if self.proxyRestartNeeded.contains(account.id) {
                        self.showToast(String(localized: "已切换到 \(account.name)（代理已变更，重启窗口后生效）"), .warning)
                    } else {
                        self.applyObservation(obs, for: account.id)
                        await self.controller.egressGuard.clearAlert(for: account.id)
                        self.showToast(res.wasAlreadyOpen ? String(localized: "已切换到 \(account.name)") : String(localized: "出口已验证（\(obs.locationLabel)），已打开 \(account.name)"), .success)
                    }
                case .blocked(let reason, let obs):
                    // Warn-only policy: launched anyway, so surface both an alert and an immediate warning.
                    if let obs { self.applyObservation(obs, for: account.id) }
                    self.activeAlerts[account.id] = EgressAlert(
                        accountID: account.id,
                        accountName: account.name,
                        reason: reason,
                        actionTaken: .notify,
                        observation: obs
                    )
                    self.showToast(String(localized: "已打开 \(account.name)，但出口不符合规则：\(reason)"), .warning)
                    NotificationHelper.send(
                        title: String(localized: "ClaudeDock 出口守护：\(account.name)"),
                        body: String(localized: "窗口已打开，但出口不符合规则。\(reason)")
                    )
                case .skipped:
                    if self.proxyRestartNeeded.contains(account.id) {
                        self.showToast(String(localized: "已切换到 \(account.name)（代理已变更，重启窗口后生效）"), .warning)
                    } else if forceBypass {
                        self.showToast(String(localized: "已跳过出口检测并打开 \(account.name)"), .warning)
                    } else {
                        self.showToast(res.wasAlreadyOpen ? String(localized: "已切换到 \(account.name)") : String(localized: "已打开 \(account.name)"), .success)
                    }
                }
            } catch is CancellationError {
                // Cancelled by a bulk quit — not a guard decision, nothing to report.
            } catch {
                if Task.isCancelled { return }
                self.showToast(error.localizedDescription, .error)
                NotificationHelper.send(title: String(localized: "ClaudeDock 已阻止启动：\(account.name)"), body: error.localizedDescription)
            }
        }
    }

    func freeze(account: AccountProfile) {
        guard operations[account.id] == nil else { return }
        let n = controller.windowController.freeze(account: account)
        refreshProcessStates()
        if n > 0 {
            showToast(String(localized: "已暂停 \(account.name)"), .info)
        } else {
            showToast(String(localized: "\(account.name) 当前未运行"), .warning)
        }
    }

    /// Resumes a frozen account only after a fresh probe proves the exit matches the policy.
    /// A warn-only mismatch is refused here too: resuming is an explicit trust decision, use `forceBypass`.
    func resume(account: AccountProfile, forceBypass: Bool = false) {
        perform(.resuming, on: account.id) {
            do {
                if !forceBypass {
                    let verdict = try await self.controller.egressGuard.verifyBeforeLaunch(account: account)
                    try Task.checkCancellation()
                    guard !self.isBulkQuitting else { return }
                    guard self.unchangedSinceProbe(account) != nil else {
                        self.showToast(String(localized: "\(account.name) 的网络设置已变更，请重试"), .warning)
                        return
                    }
                    switch verdict {
                    case .allowed(let obs):
                        self.applyObservation(obs, for: account.id)
                    case .skipped:
                        // Guard is off for this account: resuming is the user's configured choice, just say so plainly.
                        break
                    case .blocked(let reason, let obs):
                        if let obs { self.applyObservation(obs, for: account.id) }
                        self.showToast(String(localized: "未恢复 \(account.name)：出口仍不符合规则（\(reason)）"), .error)
                        return
                    }
                }
                try Task.checkCancellation()
                guard !Task.isCancelled, !self.isBulkQuitting else { return }
                let n = self.controller.windowController.resume(account: account)
                guard n > 0 else {
                    self.refreshProcessStates()
                    self.showToast(String(localized: "\(account.name) 已停止运行，可重新打开"), .warning)
                    await self.controller.egressGuard.clearAlert(for: account.id)
                    self.activeAlerts.removeValue(forKey: account.id)
                    self.proxyRestartNeeded.remove(account.id)
                    return
                }
                await self.controller.egressGuard.clearAlert(for: account.id)
                if !self.proxyRestartNeeded.contains(account.id) {
                    self.activeAlerts.removeValue(forKey: account.id)
                }
                if forceBypass { self.invalidateEgressMeasurement(for: account.id) }
                self.refreshProcessStates()
                guard !Task.isCancelled, !self.isBulkQuitting else { return }
                NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.anthropic.claudefordesktop")
                _ = self.controller.windowController.focus(account: account)
                if self.proxyRestartNeeded.contains(account.id) {
                    self.showToast(String(localized: "已恢复 \(account.name)（代理已变更，重启窗口后生效）"), .warning)
                } else if forceBypass {
                    self.showToast(String(localized: "已跳过出口检测并恢复 \(account.name)"), .warning)
                } else if account.egressPolicy.mode == .disabled {
                    self.showToast(String(localized: "已恢复 \(account.name)（这个账号没有开启出口检查）"), .info)
                } else {
                    self.showToast(String(localized: "出口检测通过，已恢复 \(account.name)"), .success)
                }
                _ = n
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self.showToast(String(localized: "未恢复 \(account.name)：\(error.localizedDescription)"), .error)
            }
        }
    }

    func quit(account: AccountProfile) {
        perform(.quitting, on: account.id) {
            let wc = self.controller.windowController
            let ok = await Task.detached(priority: .userInitiated) { wc.quit(account: account) }.value
            if ok {
                self.runningStates.removeValue(forKey: account.id)
                self.mcpRestartNeeded.remove(account.id)
                self.proxyRestartNeeded.remove(account.id)
                await self.controller.egressGuard.clearAlert(for: account.id)
                self.activeAlerts.removeValue(forKey: account.id)
                self.refreshProcessStates()
                self.showToast(String(localized: "已退出 \(account.name)"), .info)
            } else {
                self.refreshProcessStates()
                self.showToast(String(localized: "\(account.name) 退出超时，请重试"), .warning)
            }
        }
    }

    /// Re-probes a running (not frozen) account and resolves its incident only if the exit now passes.
    func recheckEgress(account: AccountProfile) {
        if proxyRestartNeeded.contains(account.id) {
            showToast(String(localized: "\(account.name) 的代理已变更，运行中的窗口仍使用旧代理，请先重启窗口"), .warning)
            return
        }
        perform(.resuming, on: account.id) {
            do {
                let verdict = try await self.controller.egressGuard.verifyBeforeLaunch(account: account)
                try Task.checkCancellation()
                guard self.unchangedSinceProbe(account) != nil else {
                    self.showToast(String(localized: "\(account.name) 的网络设置已变更，请重新检测"), .warning)
                    return
                }
                switch verdict {
                case .allowed(let obs):
                    self.applyObservation(obs, for: account.id)
                    await self.controller.egressGuard.clearAlert(for: account.id)
                    self.activeAlerts.removeValue(forKey: account.id)
                    self.showToast(String(localized: "\(account.name) 的出口已恢复正常（\(obs.locationLabel)）"), .success)
                case .skipped:
                    self.showToast(String(localized: "\(account.name) 未开启出口守护，无法检测"), .warning)
                case .blocked(let reason, let obs):
                    if let obs { self.applyObservation(obs, for: account.id) }
                    self.showToast(String(localized: "\(account.name) 的出口仍不符合规则：\(reason)"), .error)
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self.showToast(String(localized: "\(account.name) 检测失败：\(error.localizedDescription)"), .error)
            }
        }
    }

    /// Forgets the last egress measurement, so the account shows "not verified" until the next probe.
    private func invalidateEgressMeasurement(for accountID: String) {
        if let idx = accounts.firstIndex(where: { $0.id == accountID }) {
            accounts[idx].lastEgress = nil
        }
        try? controller.store.mutate { data in
            if let i = data.accounts.firstIndex(where: { $0.id == accountID }) {
                data.accounts[i].lastEgress = nil
            }
        }
    }

    func quitAll() {
        guard !isBusy, !isBulkQuitting else { return }
        isBusy = true
        Task {
            let drained = await drainOperations()
            guard drained else {
                self.isBusy = false
                self.releaseBulkQuitWhenSettled()
                self.showToast(String(localized: "仍有账号正在检测或启动，请稍候再试退出全部"), .warning)
                return
            }
            let wc = controller.windowController
            let ok = await Task.detached(priority: .userInitiated) { wc.quitAllClaudeDesktop() }.value
            self.isBulkQuitting = false
            self.isBusy = false
            self.refreshProcessStates()
            if ok {
                // Only when everything really closed: an account still running must keep its incident visible.
                for id in self.activeAlerts.keys { await self.controller.egressGuard.clearAlert(for: id) }
                self.activeAlerts.removeAll()
                self.proxyRestartNeeded.removeAll()
                self.mcpRestartNeeded.removeAll()
                self.showToast(String(localized: "已退出全部 Claude"), .info)
            } else {
                self.showToast(String(localized: "已请求退出，部分窗口仍在关闭"), .warning)
            }
        }
    }

    func pinCurrentEgress(for account: AccountProfile, exactIP: Bool = false) {
        perform(.pinning, on: account.id) {
            do {
                let (_, obs) = try await self.controller.pinCurrentEgress(for: account.id, pinExactIP: exactIP)
                try Task.checkCancellation()
                // The new rule is built from this very exit, so the old mismatch is resolved.
                await self.controller.egressGuard.clearAlert(for: account.id)
                if !self.proxyRestartNeeded.contains(account.id) {
                    self.activeAlerts.removeValue(forKey: account.id)
                }
                self.reloadFromDisk()
                self.showToast(String(localized: "已把 \(account.name) 的出口规则设为当前出口：\(obs.locationLabel)（\(obs.maskedIP)）"), .success)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self.showToast(String(localized: "未能设置出口规则：\(error.localizedDescription)"), .error)
            }
        }
    }

    private enum QuotaRefreshOutcome {
        case measured
        case signedOut
        case unavailable
    }

    private func classifyQuota(for accountID: String, startedAt: Date, requireFresh: Bool) -> QuotaRefreshOutcome {
        guard let quota = accounts.first(where: { $0.id == accountID })?.quota else {
            return .unavailable
        }
        if quota.status == .loggedOut {
            return .signedOut
        }
        guard quota.fiveHour != nil || quota.sevenDay != nil else {
            return .unavailable
        }
        if requireFresh && quota.checkedAt < startedAt.addingTimeInterval(-5) {
            return .unavailable
        }
        return .measured
    }

    func refreshQuota(for account: AccountProfile, force: Bool = true, silent: Bool = false) {
        guard !quotaRefreshing.contains(account.id) else { return }
        quotaRefreshing.insert(account.id)
        let startedAt = Date()
        Task {
            defer { self.quotaRefreshing.remove(account.id) }
            do {
                _ = try await self.controller.refreshIdentityAndQuota(for: account.id, force: force)
                self.reloadFromDisk()
                guard !silent else { return }
                switch self.classifyQuota(for: account.id, startedAt: startedAt, requireFresh: force) {
                case .measured:
                    self.showToast(String(localized: "已更新 \(account.name) 的额度"), .success)
                case .signedOut:
                    self.showToast(String(localized: "\(account.name) 请先登录 Claude Code"), .warning)
                case .unavailable:
                    self.showToast(String(localized: "\(account.name) 暂时无法读取额度"), .warning)
                }
            } catch {
                if !silent { self.showToast(String(localized: "\(account.name) 的额度读取失败：\(error.localizedDescription)"), .error) }
            }
        }
    }

    /// Reads every account's quota in parallel (the engine caps concurrency) and reports exactly which failed.
    /// Switching accounts stays available the whole time.
    func refreshAllQuotas(silent: Bool = false) {
        lastQuotaSweep = Date()
        let eligible = accounts.filter { canRunClaudeCode($0) }
        let list = eligible.filter { acc in
            guard !quotaRefreshing.contains(acc.id) else { return false }
            if silent, acc.quota?.status == .loggedOut { return false }
            return true
        }
        guard !list.isEmpty else {
            if !silent {
                if eligible.isEmpty {
                    showToast(String(localized: "没有可读取额度的账号，请先配置 Claude Code 命令行"), .warning)
                } else {
                    showToast(String(localized: "额度正在刷新中"), .info)
                }
            }
            return
        }
        quotaRefreshing.formUnion(list.map(\.id))
        let controller = self.controller
        let startedAt = Date()
        Task {
            let failed: [(String, String)] = await withTaskGroup(of: (String, String, Bool).self) { group in
                for acc in list {
                    group.addTask {
                        let ok = (try? await controller.refreshIdentityAndQuota(for: acc.id, force: true)) != nil
                        return (acc.id, acc.name, ok)
                    }
                }
                var failed: [(String, String)] = []
                for await (id, name, ok) in group {
                    await MainActor.run { _ = self.quotaRefreshing.remove(id) }
                    if !ok { failed.append((id, name)) }
                }
                return failed
            }
            self.reloadFromDisk()
            guard !silent else { return }
            // "Done" only counts accounts that actually returned fresh usage numbers.
            let failedIDs = Set(failed.map(\.0))
            let failedNames = failed.map(\.1)
            var measuredNames: [String] = []
            var signedOut: [String] = []
            var unavailable: [String] = []
            for acc in list where !failedIDs.contains(acc.id) {
                switch self.classifyQuota(for: acc.id, startedAt: startedAt, requireFresh: true) {
                case .measured: measuredNames.append(acc.name)
                case .signedOut: signedOut.append(acc.name)
                case .unavailable: unavailable.append(acc.name)
                }
            }
            let listSeparator = String(localized: "、")
            if !failedNames.isEmpty {
                let names = failedNames.joined(separator: listSeparator)
                self.showToast(String(localized: "\(names) 的额度读取失败"), .warning)
            } else if !signedOut.isEmpty && measuredNames.isEmpty && unavailable.isEmpty {
                let names = signedOut.joined(separator: listSeparator)
                self.showToast(String(localized: "\(names) 请先登录 Claude Code"), .warning)
            } else if !unavailable.isEmpty && measuredNames.isEmpty && signedOut.isEmpty {
                let names = unavailable.joined(separator: listSeparator)
                self.showToast(String(localized: "\(names) 暂时无法读取额度"), .warning)
            } else if !signedOut.isEmpty || !unavailable.isEmpty {
                var parts: [String] = []
                if !measuredNames.isEmpty { parts.append(String(localized: "已更新 \(measuredNames.count) 个账号的额度")) }
                if !signedOut.isEmpty {
                    let names = signedOut.joined(separator: listSeparator)
                    parts.append(String(localized: "\(names) 请先登录 Claude Code"))
                }
                if !unavailable.isEmpty {
                    let names = unavailable.joined(separator: listSeparator)
                    parts.append(String(localized: "\(names) 暂时无法读取额度"))
                }
                self.showToast(parts.joined(separator: String(localized: "；")), .warning)
            } else if !measuredNames.isEmpty {
                self.showToast(measuredNames.count == 1 ? String(localized: "已更新 \(measuredNames[0]) 的额度") : String(localized: "已更新 \(measuredNames.count) 个账号的额度"), .success)
            } else {
                self.showToast(String(localized: "暂时无法读取额度"), .warning)
            }
        }
    }

    func addAccount(
        name: String,
        isDefault: Bool,
        iconStyle: IconStyle,
        colorHex: String,
        proxy: ProxyConfig,
        egressPolicy: EgressPolicy,
        handoffGroup: String?,
        cliLinked: Bool
    ) throws {
        _ = try controller.addAccount(
            name: name,
            isDefault: isDefault,
            iconStyle: iconStyle,
            colorHex: colorHex,
            proxy: proxy,
            egressPolicy: egressPolicy,
            handoffGroup: handoffGroup,
            cliLinked: cliLinked
        )
        reloadFromDisk()
        refreshProcessStates()
        showToast(String(localized: "已创建 \(name)，可以打开并登录了"), .success)
    }

    /// Saves configuration edits. Returns the stored profile, or nil when the save failed (the error is shown).
    @discardableResult
    func saveAccount(_ updated: AccountProfile) -> AccountProfile? {
        let previous = accounts.first { $0.id == updated.id }
        let proxyChanged = previous != nil && previous?.proxy != updated.proxy
        let runningOrFrozen = runningStates[updated.id]?.isActive == true || runningStates[updated.id]?.isFrozen == true
        do {
            _ = try controller.updateAccount(updated)
            if proxyChanged {
                invalidateEgressMeasurement(for: updated.id)
            }
            reloadFromDisk()
            if proxyChanged && runningOrFrozen {
                proxyRestartNeeded.insert(updated.id)
                activeAlerts[updated.id] = EgressAlert(
                    accountID: updated.id,
                    accountName: updated.name,
                    reason: String(localized: "代理设置已修改，运行中的窗口仍在使用旧代理，重启窗口后生效"),
                    actionTaken: .notify,
                    observation: nil
                )
                showToast(String(localized: "已保存 \(updated.name)；运行中的窗口仍使用旧代理，重启后生效"), .warning)
            } else {
                showToast(String(localized: "已保存 \(updated.name)"), .success)
            }
            return accounts.first { $0.id == updated.id }
        } catch {
            showToast(String(localized: "无法保存：\(error.localizedDescription)"), .error)
            return nil
        }
    }

    func removeAccount(_ account: AccountProfile, deleteData: Bool) {
        guard !removingAccountIDs.contains(account.id) else { return }
        let pendingOp = operationTasks[account.id]
        let pendingGuided = (guidedSignIn?.accountID == account.id) ? guidedSignInTask : nil
        if pendingOp != nil || pendingGuided != nil {
            removingAccountIDs.insert(account.id)
            pendingOp?.cancel()
            pendingGuided?.cancel()
            Task {
                await pendingOp?.value
                await pendingGuided?.value
                self.removingAccountIDs.remove(account.id)
                self.executeRemoveAccount(account, deleteData: deleteData)
            }
            return
        }
        executeRemoveAccount(account, deleteData: deleteData)
    }

    private func executeRemoveAccount(_ account: AccountProfile, deleteData: Bool) {
        let wasGuidedTarget = guidedSignIn?.accountID == account.id
        do {
            _ = try controller.removeAccount(nameOrID: account.id, deleteData: deleteData)
            if resolvedAccountID == account.id { unsavedEdits = nil }
            if selectedAccountID == account.id { selectedAccountID = nil }
            activeAlerts.removeValue(forKey: account.id)
            awaitingSignIn.removeValue(forKey: account.id)
            mcpRestartNeeded.remove(account.id)
            proxyRestartNeeded.remove(account.id)
            guidedSignIn?.pausedAccountIDs.removeAll { $0 == account.id }
            Task { await controller.egressGuard.clearAlert(for: account.id) }
            reloadFromDisk()
            refreshProcessStates()
            if wasGuidedTarget {
                finishGuidedSignIn(message: String(localized: "已移除 \(account.name) 并取消登录助手"), tone: .info, refocusAccount: nil)
            } else {
                showToast(String(localized: "已移除 \(account.name)"), .info)
            }
        } catch {
            showToast(error.localizedDescription, .error)
        }
    }

    /// Keyboard/VoiceOver alternative to dragging: move one account up or down (changes its ⌘⌥ number).
    func moveAccount(_ account: AccountProfile, by offset: Int) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let j = i + offset
        guard accounts.indices.contains(j) else { return }
        moveAccounts(from: IndexSet(integer: i), to: offset > 0 ? j + 1 : j)
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        let orderByID = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($1.id, $0) })
        // Mutate ONLY `sortOrder` for matching IDs inside transactional lock so concurrent CLI edits are preserved.
        try? controller.store.mutate { data in
            for idx in data.accounts.indices {
                if let newOrder = orderByID[data.accounts[idx].id] {
                    data.accounts[idx].sortOrder = newOrder
                }
            }
        }
        reloadFromDisk()
    }

    private enum JSONValue: Codable, Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let i = try? c.decode(Int64.self) { self = .int(i) }
            else if let d = try? c.decode(Double.self) { self = .double(d) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
            else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
            else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .int(let i): try c.encode(i)
            case .double(let d): try c.encode(d)
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }
    }

    /// Merges only fields that changed between `base` and `incoming` onto `disk`, preserving unrelated CLI edits.
    private static func mergeSettings(base: AppSettings, incoming: AppSettings, onto disk: AppSettings) -> AppSettings {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        guard let baseData = try? encoder.encode(base),
              let incomingData = try? encoder.encode(incoming),
              let diskData = try? encoder.encode(disk),
              let baseMap = try? decoder.decode([String: JSONValue].self, from: baseData),
              let incomingMap = try? decoder.decode([String: JSONValue].self, from: incomingData),
              var diskMap = try? decoder.decode([String: JSONValue].self, from: diskData) else {
            return incoming
        }
        let allKeys = Set(baseMap.keys).union(incomingMap.keys)
        for key in allKeys where baseMap[key] != incomingMap[key] {
            if let updatedValue = incomingMap[key] {
                diskMap[key] = updatedValue
            } else {
                diskMap.removeValue(forKey: key)
            }
        }
        guard let mergedData = try? encoder.encode(diskMap),
              let merged = try? decoder.decode(AppSettings.self, from: mergedData) else {
            return incoming
        }
        return merged
    }

    func saveSettings(_ newSettings: AppSettings) {
        let previousSettings = self.settings
        let loginChanged = newSettings.launchAtLogin != previousSettings.launchAtLogin
        var newSettings = newSettings
        if loginChanged && Bundle.main.bundleIdentifier != nil {
            do {
                if newSettings.launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                newSettings.launchAtLogin = previousSettings.launchAtLogin
                showToast(String(localized: "无法修改开机启动：\(error.localizedDescription)"), .error)
            }
        }
        var committed = newSettings
        do {
            try controller.store.mutate { data in
                let merged = Self.mergeSettings(base: previousSettings, incoming: newSettings, onto: data.settings)
                data.settings = merged
                committed = merged
            }
        } catch {
            showToast(String(localized: "无法保存设置：\(error.localizedDescription)"), .error)
            return
        }
        let shareChanged = committed.shareClaudeCodeResources != previousSettings.shareClaudeCodeResources
            || committed.shareClaudeCodeSessions != previousSettings.shareClaudeCodeSessions
        let intervalChanged = committed.watchdogIntervalSeconds != previousSettings.watchdogIntervalSeconds
        self.settings = committed
        if shareChanged {
            controller.reconcileCLIWrappers(shareResources: committed.shareClaudeCodeResources,
                                            shareSessions: committed.shareClaudeCodeSessions)
        }
        recomputeQuotaAlerts()
        refreshHotkeys()
        if intervalChanged { restartWatchdog() }
    }

    /// Set by the menu commands (which have SwiftUI's openWindow): opens or reopens the main window.
    var openMainWindowAction: (() -> Void)?

    func showMainWindow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }

    // MARK: - URL scheme

    /// Handles claudedock:// links from Raycast, Alfred, Shortcuts or scripts. Only non-destructive actions:
    /// open/switch an account, open the switcher, start adding an account, refresh quota.
    func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "claudedock" else { return }
        let action = (url.host ?? "").lowercased()
        let argument = url.pathComponents.dropFirst().first?.removingPercentEncoding ?? ""
        switch action {
        case "open", "switch":
            if let acc = accounts.first(where: { $0.id == argument || $0.name.caseInsensitiveCompare(argument) == .orderedSame || $0.slug == argument }) {
                openOrFocus(account: acc)
            } else {
                showToast(String(localized: "没有找到账号“\(argument)”"), .warning)
            }
        case "switcher":
            QuickSwitcher.shared.show()
        case "add":
            showMainWindow()
            requestAddAccount()
        case "projects":
            showMainWindow()
            navigate(to: .projects)
        case "refresh":
            refreshAllQuotas()
        case "show":
            showMainWindow()
        default:
            showToast(String(localized: "不认识的链接：\(url.absoluteString)"), .warning)
        }
    }

    // MARK: - Guided Desktop sign-in

    @Published private(set) var guidedSignIn: GuidedSignIn?
    private var guidedSignInToken: UUID?
    /// Whether the main window is open (tracked by the window observer), so background work can slow down.
    var isMainWindowVisible = true

    /// Other Claude windows that would intercept the sign-in callback.
    func otherRunningAccounts(than account: AccountProfile) -> [AccountProfile] {
        runningAccounts.filter { $0.id != account.id }
    }

    /// Signs an account in to Claude Desktop safely: closes the other Claude windows, opens this one, and
    /// reopens the others as soon as the sign-in shows up (or when the user ends it).
    func beginGuidedSignIn(_ account: AccountProfile) {
        // One at a time: a second session would forget which windows the first one closed.
        if let current = guidedSignIn {
            if current.isRestoring {
                showToast(String(localized: "正在恢复之前关闭的窗口，请稍候再开始新的登录"), .warning)
            } else {
                let name = accounts.first { $0.id == current.accountID }?.name ?? String(localized: "另一个账号")
                showToast(String(localized: "正在为 \(name) 登录，先结束它再开始新的登录"), .warning)
            }
            return
        }
        let others = otherRunningAccounts(than: account)
        let dir = account.userDataDirectory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        // A sign-in only counts if it's a different (or first) account than what was there before.
        let baseline = DesktopProfileReader.readSignedIn(userDataDirectory: dir)?.accountUUID
        let token = UUID()
        guidedSignInToken = token
        let session = GuidedSignIn(accountID: account.id, pausedAccountIDs: [], startedAt: Date(), baselineUUID: baseline)
        guidedSignIn = session
        guidedSignInTask = Task {
            let wc = self.controller.windowController
            var closedIDs: [String] = []
            var closedNames: [String] = []
            var stillOpen: [String] = []
            for other in others {
                // If the user ended the assistant meanwhile, stop: don't keep closing windows.
                guard self.guidedSignInToken == token, self.guidedSignIn?.isRestoring == false, !Task.isCancelled else { return }
                let ok = await Task.detached(priority: .userInitiated) { wc.quit(account: other) }.value
                if ok {
                    closedIDs.append(other.id)
                    closedNames.append(other.name)
                    self.runningStates.removeValue(forKey: other.id)
                    if self.guidedSignInToken == token {
                        self.guidedSignIn?.pausedAccountIDs = closedIDs
                    }
                } else {
                    stillOpen.append(other.name)
                }
            }
            guard self.guidedSignInToken == token, self.guidedSignIn?.isRestoring == false, !Task.isCancelled else { return }
            self.refreshProcessStates()
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard self.guidedSignInToken == token, self.guidedSignIn?.isRestoring == false, !Task.isCancelled else { return }
            let listSeparator = String(localized: "、")
            if !stillOpen.isEmpty {
                let stillOpenList = stillOpen.joined(separator: listSeparator)
                self.showToast(String(localized: "\(stillOpenList) 没能关闭，登录结果可能会被它接走。可以手动关闭后再继续。"), .warning)
            }
            let opened = await self.openAccountForGuidedSignIn(account)
            guard self.guidedSignInToken == token, self.guidedSignIn?.isRestoring == false, !Task.isCancelled else { return }
            if !opened {
                self.guidedSignInTask = nil
                self.finishGuidedSignIn(message: String(localized: "未能打开 \(account.name)"), tone: .error, refocusAccount: nil)
                return
            }
            if stillOpen.isEmpty {
                if closedNames.isEmpty {
                    self.showToast(String(localized: "在 \(account.name) 的窗口里登录；邮件里的链接请用浏览器打开"), .info)
                } else {
                    let closedList = closedNames.joined(separator: listSeparator)
                    self.showToast(String(localized: "已暂时关闭 \(closedList)，现在在 \(account.name) 的窗口里登录"), .info)
                }
            }
        }
    }

    private func openAccountForGuidedSignIn(_ account: AccountProfile) async -> Bool {
        guard !isBulkQuitting, !Task.isCancelled else { return false }
        if runningStates[account.id]?.isFrozen == true {
            do {
                let verdict = try await controller.egressGuard.verifyBeforeLaunch(account: account)
                try Task.checkCancellation()
                guard !isBulkQuitting else { return false }
                switch verdict {
                case .allowed(let obs):
                    applyObservation(obs, for: account.id)
                case .skipped:
                    break
                case .blocked(let reason, let obs):
                    if let obs { applyObservation(obs, for: account.id) }
                    showToast(String(localized: "未恢复 \(account.name)：出口不符合规则（\(reason)）"), .error)
                    return false
                }
                let n = controller.windowController.resume(account: account)
                if n > 0 {
                    await controller.egressGuard.clearAlert(for: account.id)
                    if !proxyRestartNeeded.contains(account.id) {
                        activeAlerts.removeValue(forKey: account.id)
                    }
                    refreshProcessStates()
                    NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.anthropic.claudefordesktop")
                    _ = controller.windowController.focus(account: account)
                    return true
                }
            } catch is CancellationError {
                return false
            } catch {
                if !Task.isCancelled {
                    showToast(String(localized: "未恢复 \(account.name)：\(error.localizedDescription)"), .error)
                }
                return false
            }
        }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.anthropic.claudefordesktop")
        do {
            let res = try await controller.openOrFocusAccount(nameOrID: account.id, forceBypassGuard: false)
            if !res.wasAlreadyOpen {
                proxyRestartNeeded.remove(account.id)
            }
            reloadFromDisk()
            refreshProcessStates()
            switch res.verdict {
            case .allowed(let obs):
                if !proxyRestartNeeded.contains(account.id) {
                    applyObservation(obs, for: account.id)
                    await controller.egressGuard.clearAlert(for: account.id)
                }
            case .blocked(let reason, let obs):
                if let obs { applyObservation(obs, for: account.id) }
                activeAlerts[account.id] = EgressAlert(
                    accountID: account.id,
                    accountName: account.name,
                    reason: reason,
                    actionTaken: .notify,
                    observation: obs
                )
                showToast(String(localized: "已打开 \(account.name)，但出口不符合规则：\(reason)"), .warning)
                NotificationHelper.send(
                    title: String(localized: "ClaudeDock 出口守护：\(account.name)"),
                    body: String(localized: "窗口已打开，但出口不符合规则。\(reason)")
                )
            case .skipped:
                break
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled {
                showToast(error.localizedDescription, .error)
                NotificationHelper.send(title: String(localized: "ClaudeDock 已阻止启动：\(account.name)"), body: error.localizedDescription)
            }
            return false
        }
    }

    private func reopenAccountForGuidedSignIn(_ account: AccountProfile) async -> Bool {
        guard !isBulkQuitting else { return false }
        do {
            let res = try await controller.openOrFocusAccount(nameOrID: account.id, forceBypassGuard: false)
            if !res.wasAlreadyOpen {
                proxyRestartNeeded.remove(account.id)
            }
            switch res.verdict {
            case .allowed(let obs):
                if !proxyRestartNeeded.contains(account.id) {
                    applyObservation(obs, for: account.id)
                    await controller.egressGuard.clearAlert(for: account.id)
                }
            case .blocked(let reason, let obs):
                if let obs { applyObservation(obs, for: account.id) }
                activeAlerts[account.id] = EgressAlert(
                    accountID: account.id,
                    accountName: account.name,
                    reason: reason,
                    actionTaken: .notify,
                    observation: obs
                )
                NotificationHelper.send(
                    title: String(localized: "ClaudeDock 出口守护：\(account.name)"),
                    body: String(localized: "窗口已打开，但出口不符合规则。\(reason)")
                )
            case .skipped:
                break
            }
            return true
        } catch {
            return false
        }
    }

    /// Called every poll: finishes the guided sign-in once the account's Desktop shows a signed-in user.
    private func checkGuidedSignIn() {
        guard let session = guidedSignIn, !session.isRestoring,
              let token = guidedSignInToken,
              let account = accounts.first(where: { $0.id == session.accountID }) else { return }
        let dir = account.userDataDirectory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        let since = session.startedAt
        Task.detached(priority: .utility) {
            // Only a sign-in written after the assistant started counts — not an old record in the cache.
            let idb = dir.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.leveldb")
            let newest = ((try? FileManager.default.contentsOfDirectory(at: idb, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max() ?? .distantPast
            let candidate = newest > since ? DesktopProfileReader.readSignedIn(userDataDirectory: dir) : nil
            let signedIn = candidate.flatMap { $0.accountUUID == session.baselineUUID ? nil : $0 }
            await MainActor.run {
                guard self.guidedSignInToken == token, self.guidedSignIn?.isRestoring == false, let signedIn else { return }
                let message: String
                if let email = signedIn.profile.email, !email.isEmpty {
                    message = String(localized: "\(account.name) 已登录（\(email)）")
                } else {
                    message = String(localized: "\(account.name) 已登录")
                }
                self.finishGuidedSignIn(message: message, tone: .success, refocusAccount: account)
                self.refreshQuota(for: account, force: true, silent: true)
            }
        }
    }

    /// Ends the guided sign-in and reopens the windows that were closed for it.
    func finishGuidedSignIn(message: String? = nil) {
        finishGuidedSignIn(message: message, tone: .success, refocusAccount: nil)
    }

    private func finishGuidedSignIn(message: String?, tone: Toast.Tone, refocusAccount: AccountProfile?) {
        guard let session = guidedSignIn, !session.isRestoring else { return }
        guidedSignIn?.isRestoring = true
        let pending = guidedSignInTask
        guidedSignInTask = nil
        Task {
            // Let a quit that was already in flight finish first, so it can't close a window we just reopened.
            await pending?.value
            let pausedIDs = self.guidedSignIn?.pausedAccountIDs ?? session.pausedAccountIDs
            let reopen = self.accounts.filter { pausedIDs.contains($0.id) }
            var restoredNames: [String] = []
            var failedNames: [String] = []
            for acc in reopen {
                guard !self.isBulkQuitting else {
                    failedNames.append(acc.name)
                    continue
                }
                if await self.reopenAccountForGuidedSignIn(acc) {
                    restoredNames.append(acc.name)
                } else {
                    failedNames.append(acc.name)
                }
            }
            if let refocusAccount, !self.isBulkQuitting,
               self.accounts.contains(where: { $0.id == refocusAccount.id }) {
                NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.anthropic.claudefordesktop")
                _ = self.controller.windowController.focus(account: refocusAccount)
            }
            self.reloadFromDisk()
            self.refreshProcessStates()
            self.guidedSignIn = nil
            self.guidedSignInToken = nil
            let listSeparator = String(localized: "、")
            var parts = [message ?? String(localized: "登录助手已结束")]
            if !restoredNames.isEmpty {
                let names = restoredNames.joined(separator: listSeparator)
                parts.append(String(localized: "已重新打开 \(names)"))
            }
            if !failedNames.isEmpty {
                let names = failedNames.joined(separator: listSeparator)
                parts.append(String(localized: "未能恢复 \(names)"))
            }
            let summary = parts.joined(separator: String(localized: "，"))
            let finalTone: Toast.Tone = (!failedNames.isEmpty && tone == .success) ? .warning : tone
            self.showToast(summary, finalTone)
        }
    }

    private var guidedSignInTask: Task<Void, Never>?

    // MARK: - Desktop MCP sync

    /// MCP servers per account (account id → server names), for the sharing matrix.
    @Published private(set) var mcpInventory: [String: [String]] = [:]
    @Published private(set) var lastMCPSyncAt: Date?
    /// Accounts whose MCP config changed while their window was open: Claude Desktop reads it at launch.
    @Published private(set) var mcpRestartNeeded: Set<String> = []
    /// Local Claude Code skills (~/.claude/skills), shared by every account's command line and Desktop's built-in Claude Code.
    @Published private(set) var sharedSkills: [String] = []
    private var mcpFingerprint: String?
    private var mcpSyncInFlight = false

    func refreshSharedSkills() {
        Task.detached(priority: .utility) {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
            let skills = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted()
            await MainActor.run {
                if self.sharedSkills != skills { self.sharedSkills = skills }
            }
        }
    }

    func refreshMCPInventory() {
        let engine = controller.configSyncEngine
        let list = accounts
        refreshSharedSkills()
        Task.detached(priority: .utility) {
            let inv = engine.mcpInventory(accounts: list)
            await MainActor.run { if self.mcpInventory != inv { self.mcpInventory = inv } }
        }
    }

    /// Automatic sync: runs only when some account's Desktop config actually changed (or a new account appeared).
    private func autoSyncMCPIfNeeded() {
        guard settings.shareDesktopMCP, !mcpSyncInFlight, accounts.count > 1 else { return }
        mcpSyncInFlight = true
        let engine = controller.configSyncEngine
        let list = accounts
        let previous = mcpFingerprint
        let running = Set(runningAccounts.map(\.id))
        Task {
            defer { self.mcpSyncInFlight = false }
            let fp = await Task.detached(priority: .utility) { engine.configFingerprint(accounts: list) }.value
            guard fp != previous else { return }
            do {
                let report = try await Task.detached(priority: .utility) { try engine.syncDesktopMCPConfigs(accounts: list) }.value
                // Retain the pre-sync fingerprint: if nothing was written, we're converged; if we wrote,
                // the next poll reconciles both our writes and any concurrent edit made in the gap.
                self.mcpFingerprint = fp
                if !report.syncedAccounts.isEmpty || self.lastMCPSyncAt == nil {
                    self.lastSyncReport = report
                    self.lastMCPSyncAt = Date()
                    self.refreshMCPInventory()
                }
                // Any running window whose config we changed needs a restart — including on the very first sync.
                let changedRunning = list.filter { report.syncedAccounts.contains($0.name) && running.contains($0.id) }
                self.mcpRestartNeeded.formUnion(changedRunning.map(\.id))
                if previous != nil, !report.syncedAccounts.isEmpty {
                    let names = report.syncedAccounts.joined(separator: String(localized: "、"))
                    self.showToast(changedRunning.isEmpty
                                   ? String(localized: "MCP 服务器已同步到 \(names)")
                                   : String(localized: "MCP 服务器已同步到 \(names)，重启这些窗口后生效"), .success, passive: true)
                }
            } catch {
                // Don't retry a broken config every few seconds, but do try again after a minute.
                self.mcpFingerprint = fp
                Task { try? await Task.sleep(for: .seconds(60)); if self.mcpFingerprint == fp { self.mcpFingerprint = nil } }
                self.showToast(String(localized: "MCP 自动同步暂停：\(error.localizedDescription)"), .warning)
            }
        }
    }

    /// Quits and reopens an account's window (e.g. so Claude Desktop picks up new MCP servers or proxy changes).
    func restartAccount(_ account: AccountProfile) {
        guard operations[account.id] == nil, !isBulkQuitting, !removingAccountIDs.contains(account.id) else { return }
        perform(.quitting, on: account.id) {
            let wc = self.controller.windowController
            let ok = await Task.detached(priority: .userInitiated) { wc.quit(account: account) }.value
            guard ok else {
                if !Task.isCancelled {
                    self.showToast(String(localized: "\(account.name) 没能退出，请手动关闭后再打开"), .warning)
                }
                return
            }
            self.mcpRestartNeeded.remove(account.id)
            self.proxyRestartNeeded.remove(account.id)
            self.runningStates.removeValue(forKey: account.id)
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                self.refreshProcessStates()
                return
            }
            guard !Task.isCancelled, !self.isBulkQuitting else {
                self.refreshProcessStates()
                return
            }
            self.refreshProcessStates()
            // Reopen only after this quit really happened; the operation slot frees up right after we return.
            let quitTask = self.operationTasks[account.id]
            Task { @MainActor in
                await quitTask?.value
                guard !self.isBulkQuitting, !self.removingAccountIDs.contains(account.id) else { return }
                guard let current = self.accounts.first(where: { $0.id == account.id }) else { return }
                self.openOrFocus(account: current)
            }
        }
    }

    func syncDesktopMCP() {
        guard !mcpSyncInFlight else { return }
        mcpSyncInFlight = true
        let engine = controller.configSyncEngine
        let list = accounts
        Task {
            defer { self.mcpSyncInFlight = false }
            do {
                // File locking, fingerprinting and merging run off the main thread.
                let (preFP, report) = try await Task.detached(priority: .userInitiated) {
                    let fp = engine.configFingerprint(accounts: list)
                    let report = try engine.syncDesktopMCPConfigs(accounts: list)
                    return (fp, report)
                }.value
                self.lastSyncReport = report
                self.lastMCPSyncAt = Date()
                // Retain the pre-sync fingerprint so any edit made right after sync is reconciled on the next poll.
                self.mcpFingerprint = preFP
                self.refreshMCPInventory()
                let running = Set(self.runningAccounts.map(\.id))
                self.mcpRestartNeeded.formUnion(list.filter { report.syncedAccounts.contains($0.name) && running.contains($0.id) }.map(\.id))
                self.showToast(String(localized: "MCP 已同步：\(report.mergedMCPServerCount) 个服务器，\(report.syncedAccounts.count) 个账号有更新"), .success)
            } catch {
                self.showToast(error.localizedDescription, .error)
            }
        }
    }

    func startUpdateGuard() {
        guard !isBusy, !isBulkQuitting else { return }
        isBusy = true
        Task {
            let drained = await drainOperations()
            guard drained else {
                self.isBusy = false
                self.releaseBulkQuitWhenSettled()
                self.showToast(String(localized: "仍有账号正在检测或启动，请稍候再进入更新保护"), .warning)
                return
            }
            defer {
                self.isBulkQuitting = false
                self.isBusy = false
            }
            do {
                let controller = self.controller
                // Quitting windows waits on processes; keep it off the main thread.
                let res = try await Task.detached(priority: .userInitiated) { try controller.startUpdateGuard() }.value
                reloadFromDisk()
                refreshProcessStates()
                if res.allClosed {
                    self.proxyRestartNeeded.removeAll()
                    self.mcpRestartNeeded.removeAll()
                    showToast(String(localized: "已退出全部窗口并记下 \(res.savedNames.count) 个账号，现在可以更新 Claude"), .success)
                } else {
                    showToast(String(localized: "仍有 Claude 正在运行，请先全部退出后再更新"), .warning)
                }
            } catch {
                showToast(error.localizedDescription, .error)
            }
        }
    }

    func restoreAfterUpdate() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { self.isBusy = false }
            do {
                let res = try await controller.restoreAfterUpdate()
                reloadFromDisk()
                refreshProcessStates()
                if res.failed.isEmpty {
                    showToast(String(localized: "已恢复 \(res.restored.count) 个账号窗口"), .success)
                } else {
                    let failedNames = res.failed.map(\.0).joined(separator: ", ")
                    showToast(String(localized: "已恢复 \(res.restored.count) 个，\(res.failed.count) 个失败（\(failedNames)），可重试"), .warning)
                }
            } catch {
                showToast(error.localizedDescription, .error)
            }
        }
    }

    private func recomputeQuotaAlerts() {
        let healthyPool = accounts.filter {
            runningStates[$0.id]?.isFrozen != true && !egressHealth(for: $0).needsAttention
        }
        let healthyIDs = Set(healthyPool.map(\.id))
        var alerts = AccountScheduler.evaluateThresholdAlerts(
            accounts: healthyPool,
            thresholdPercentage: settings.quotaAlertThreshold,
            mode: settings.schedulingMode
        )
        for acc in accounts where !healthyIDs.contains(acc.id) {
            let extra = AccountScheduler.evaluateThresholdAlerts(
                accounts: [acc] + healthyPool,
                thresholdPercentage: settings.quotaAlertThreshold,
                mode: settings.schedulingMode
            ).filter { $0.accountID == acc.id }
            alerts.append(contentsOf: extra)
        }
        let order = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($1.id, $0) })
        alerts.sort { (order[$0.accountID] ?? Int.max) < (order[$1.accountID] ?? Int.max) }
        if self.quotaAlerts != alerts { self.quotaAlerts = alerts }
        for alert in alerts {
            let acc = accounts.first { $0.id == alert.accountID }
            let window = alert.windowName == "5-hour" ? acc?.quota?.fiveHour : acc?.quota?.sevenDay
            // One notification per account, window and reset cycle.
            let key = "\(alert.accountID)-\(alert.windowName)-\(window?.resetsAt ?? 0)"
            if !notifiedQuotaIDs.contains(key) {
                notifiedQuotaIDs.insert(key)
                let left = Int((100 - alert.usedPercentage).rounded())
                let title = alert.windowName == "5-hour"
                    ? String(localized: "\(alert.accountName) 的5 小时额度只剩 \(left)%")
                    : String(localized: "\(alert.accountName) 的7 天额度只剩 \(left)%")
                let reset = window.map { QuotaFormat.resetText($0, now: Date()) } ?? ""
                let validNext = alert.recommendedNext.flatMap { healthyIDs.contains($0.id) ? $0 : nil }
                let emptyCopy = (acc?.handoffGroup?.isEmpty == false)
                    ? String(localized: "暂时没有可用的同组其他账号。")
                    : String(localized: "暂时没有可用的其他账号。")
                let next = validNext.map { String(localized: "可以切到 \($0.name) 继续。") } ?? emptyCopy
                NotificationHelper.send(
                    title: title,
                    body: [reset, next].filter { !$0.isEmpty }.joined(separator: String(localized: "，"))
                )
            }
        }
    }

    func showToast(_ text: String, _ tone: Toast.Tone, passive: Bool = false) {
        let toast = Toast(text: text, tone: tone)
        // Only passive background notifications defer to an undismissed warning or error.
        if passive, let current = self.toast, current.isPersistent, !toast.isPersistent { return }
        withAnimation(.snappy(duration: 0.25)) { self.toast = toast }
        guard !toast.isPersistent else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.toast?.id == toast.id {
                withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
            }
        }
    }

    func dismissToast() {
        withAnimation(.easeOut(duration: 0.2)) { toast = nil }
    }
}
