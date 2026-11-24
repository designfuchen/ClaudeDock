// FILE: ClaudeDockApp.swift
import AppKit
import ClaudeDockCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app so URL events and Dock clicks can reach the view model.
    @MainActor static weak var viewModel: DockViewModel?
    @MainActor private static var lastHideDockWhenClosed: Bool?
    @MainActor private var windowCloseObserver: NSObjectProtocol?
    @MainActor private var isTerminatingAfterQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LaunchPreferences.openMainWindowAtLaunch {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Quiet launch: menu bar only, no Dock icon, no focus stealing.
            NSApp.setActivationPolicy(.accessory)
            AppDelegate.viewModel?.isMainWindowVisible = false
        }

        // Restore `.accessory` mode when auxiliary windows (e.g. Settings) close while the main window is hidden.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Read the window identity before hopping onto the main actor (Notification isn't Sendable).
            let closingID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let closingID,
                      let window = NSApp.windows.first(where: { ObjectIdentifier($0) == closingID }),
                      window.canBecomeMain,
                      let vm = AppDelegate.viewModel,
                      !vm.isMainWindowVisible,
                      NSApp.activationPolicy() == .regular else { return }
                AppDelegate.mainWindowVisibilityChanged(
                    visible: false,
                    hideDockWhenClosed: AppDelegate.shouldHideDockWhenClosed(vm: vm)
                )
            }
        }
    }

    /// claudedock:// links arrive here (the window scene doesn't claim them), so actions like "refresh" or
    /// "switcher" never force the main window open.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { AppDelegate.viewModel?.handleURL(url) }
        }
    }

    /// Menu bar–only mode: no Dock icon while the main window is closed; it comes back with the window.
    @MainActor
    static func mainWindowVisibilityChanged(visible: Bool, hideDockWhenClosed: Bool) {
        lastHideDockWhenClosed = hideDockWhenClosed
        if visible {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        } else if hideDockWhenClosed {
            // Defer past the close, and keep the Dock icon while another real window (e.g. Settings) is open.
            DispatchQueue.main.async {
                guard AppDelegate.viewModel?.isMainWindowVisible != true else { return }
                let others = NSApp.windows.filter {
                    $0.isVisible && $0.canBecomeMain && $0.identifier?.rawValue.contains("main") != true
                }
                if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    @MainActor
    private static func shouldHideDockWhenClosed(vm: DockViewModel) -> Bool {
        if let mirrored = Mirror(reflecting: vm.settings).children.first(where: {
            $0.label?.localizedCaseInsensitiveContains("hidedock") == true
        })?.value as? Bool {
            return mirrored
        }
        return lastHideDockWhenClosed ?? !LaunchPreferences.openMainWindowAtLaunch
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep Menu Bar Watchdog & global hotkeys alive even when main window is closed
        return false
    }

    /// Clicking the Dock icon always brings back the *main* window (never Settings), restoring it if minimized.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in AppDelegate.viewModel?.showMainWindow() }
        return false // we handled it; don't let AppKit pick an arbitrary window (e.g. Settings)
    }

    /// Warn before quitting while accounts protected by Fail-Closed EgressGuard are still running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminatingAfterQuit { return .terminateLater }
        guard let vm = AppDelegate.viewModel else { return .terminateNow }
        let protected = vm.runningAccounts.filter { !vm.egressHealth(for: $0).title.contains(String(localized: "未开启")) }
        guard !protected.isEmpty else { return .terminateNow }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "仍有 \(protected.count) 个受出口守护保护的账号正在运行")
        let names = protected.map(\.name).joined(separator: String(localized: "、"))
        alert.informativeText = String(localized: "退出 ClaudeDock 将停止对 \(names) 的出口监控与自动暂停保护。")
        alert.addButton(withTitle: String(localized: "取消"))
        alert.addButton(withTitle: String(localized: "关闭受保护窗口并退出"))
        alert.addButton(withTitle: String(localized: "仅退出 ClaudeDock"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .terminateCancel
        case .alertThirdButtonReturn:
            return .terminateNow
        case .alertSecondButtonReturn:
            isTerminatingAfterQuit = true
            let protectedIDs = Set(protected.map(\.id))
            for account in protected {
                vm.quit(account: account)
            }
            Task { @MainActor in
                let deadline = ContinuousClock.now + .seconds(5)
                while ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(150))
                    let stillActive = protectedIDs.contains { id in
                        vm.runningStates[id]?.isActive == true || vm.operation(for: id) != nil
                    }
                    if !stillActive { break }
                }
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }
}

@main
struct ClaudeDockApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: DockViewModel

    @MainActor
    init() {
        let vm = DockViewModel()
        _viewModel = StateObject(wrappedValue: vm)
        AppDelegate.viewModel = vm
    }

    var body: some Scene {
        // Primary workbench window — opens on launch so notch MacBook users never lose the app.
        Window("ClaudeDock", id: "main") {
            MainWorkbenchView(vm: viewModel)
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .quietLaunchIfRequested(!LaunchPreferences.openMainWindowAtLaunch)
        .handlesExternalEvents(matching: []) // URLs go to AppDelegate, not "open the window"
        .commands { DockCommands(vm: viewModel) }

        // Native ⌘, settings window for low-frequency preferences.
        Settings {
            SettingsWindowView(vm: viewModel)
        }

        // Menu bar switcher (stays active after the main window is closed).
        MenuBarExtra {
            MenuBarPopoverView(vm: viewModel)
        } label: {
            MenuBarLabelView(vm: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabelView: View {
    @ObservedObject var vm: DockViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = ensureOpenWindowAction()
        HStack(spacing: 3) {
            Image(nsImage: vm.menuBarImage)
            if let text = vm.menuBarText {
                Text(text)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(vm.menuBarAccessibilitySummary)
        .onAppear {
            let open = openWindow
            vm.openMainWindowAction = { open(id: "main") }
        }
    }

    private func ensureOpenWindowAction() {
        if vm.openMainWindowAction == nil {
            let open = openWindow
            vm.openMainWindowAction = { open(id: "main") }
        }
    }
}

/// Menu bar commands: every primary action has a keyboard path.
struct DockCommands: Commands {
    @ObservedObject var vm: DockViewModel
    @Environment(\.openWindow) private var openWindow

    private func showMain(_ then: () -> Void = {}) {
        if vm.openMainWindowAction == nil {
            let open = openWindow
            vm.openMainWindowAction = { open(id: "main") }
        }
        vm.showMainWindow()
        then()
    }

    private func activateAccount(_ account: AccountProfile) {
        if vm.runningStates[account.id]?.isFrozen == true {
            vm.resume(account: account)
        } else {
            vm.openOrFocus(account: account)
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加账号…") {
                showMain { vm.requestAddAccount() }
            }
            .keyboardShortcut("n")
        }

        CommandGroup(before: .sidebar) {
            ForEach(Array(AppRoute.allCases.enumerated()), id: \.element) { idx, route in
                Button(route.title) {
                    showMain { vm.navigate(to: route) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
            }
            Divider()
        }

        CommandMenu("账号") {
            Button(QuickSwitcher.shared.isRegistered ? String(localized: "快速切换…  \(QuickSwitcher.shortcutLabel)") : String(localized: "快速切换…")) {
                QuickSwitcher.shared.show()
            }
            Divider()
            Button("刷新全部额度") { vm.refreshAllQuotas() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!vm.quotaRefreshing.isEmpty || vm.accounts.isEmpty)
            if let best = vm.recommendedAccount, vm.accounts.count > 1 {
                Button("切换到推荐账号：\(best.name)") { activateAccount(best) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
            }
            Divider()
            ForEach(vm.accounts.prefix(9)) { acc in
                Button(acc.name) { activateAccount(acc) }
            }
            if !vm.accounts.isEmpty { Divider() }
            Button("更新 Claude 前退出全部窗口…") {
                showMain { vm.pendingConfirmation = .updateGuard }
            }
            .disabled(vm.activeRunningCount == 0)
            if vm.updateGuardSavedCount > 0 {
                Button("恢复更新前的 \(vm.updateGuardSavedCount) 个窗口") { vm.restoreAfterUpdate() }
                    .disabled(vm.isBusy)
            }
            Button("退出全部 Claude…") {
                showMain { vm.pendingConfirmation = .quitAll }
            }
            .disabled(vm.activeRunningCount == 0)
        }
    }
}

/// Reads the one launch-time preference SwiftUI needs before the view model exists.
enum LaunchPreferences {
    static let openMainWindowAtLaunch: Bool = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudedock/profiles.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = obj["settings"] as? [String: Any],
              let open = settings["openMainWindowAtLaunch"] as? Bool else { return true }
        return open
    }()
}

extension Scene {
    /// macOS 15+: don't present the main window at launch when the user chose to start in the menu bar
    /// (no flash). On macOS 14 the window observer closes it on first appearance instead.
    func quietLaunchIfRequested(_ quiet: Bool) -> some Scene {
        if #available(macOS 15.0, *) {
            return self.defaultLaunchBehavior(quiet ? .suppressed : .presented)
        } else {
            return self
        }
    }
}
