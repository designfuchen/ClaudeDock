// FILE: Views/MenuBarPopoverView.swift
import AppKit
import ClaudeDockCore
import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var vm: DockViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismissPopover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var confirmingMCPRestartAll = false
    @State private var isRestoringAfterUpdate = false

    private var restartingAccounts: [AccountProfile] {
        vm.accounts.filter { vm.mcpRestartNeeded.contains($0.id) }
    }

    private var hasBanners: Bool {
        vm.guidedSignIn != nil || !vm.activeAlerts.isEmpty
            || vm.updateGuardSavedCount > 0 || !restartingAccounts.isEmpty
    }

    private var oldestQuotaCheckedAt: Date? {
        let validQuotas = vm.accounts
            .compactMap(\.quota)
            .filter { $0.fiveHour != nil || $0.sevenDay != nil }
        let liveOldest = validQuotas.filter { $0.status == .reported || $0.status == .partial }.map(\.checkedAt).min()
        return liveOldest ?? validQuotas.map(\.checkedAt).min()
    }

    private var quotaSubtitle: String? {
        if !vm.quotaRefreshing.isEmpty {
            return String(localized: "正在刷新额度…")
        }
        if let oldest = oldestQuotaCheckedAt {
            return QuotaFormat.updatedText(oldest, now: vm.clock)
        }
        return nil
    }

    private var headerStatusText: String {
        let guardText = String(localized: "出口守护 · \(vm.guardSummary.title)")
        if vm.accounts.isEmpty {
            return guardText
        }
        return String(localized: "\(vm.activeRunningCount)/\(vm.accounts.count) 运行中 · \(guardText)")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if vm.guidedSignIn != nil || !vm.activeAlerts.isEmpty {
                VStack(spacing: DS.Space.s) {
                    if vm.guidedSignIn != nil {
                        GuidedSignInBanner(vm: vm, compact: true)
                    }
                    if !vm.activeAlerts.isEmpty {
                        IncidentStack(vm: vm, compact: true)
                    }
                }
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .frame(maxWidth: .infinity)
                Divider()
            }

            if vm.updateGuardSavedCount > 0 {
                updateGuardNotice
            }
            let needRestart = restartingAccounts
            if !needRestart.isEmpty {
                mcpRestartBanner(needRestart)
            }
            if let project = vm.projects.first(where: \.exists),
               let account = vm.suggestedAccount(for: project) {
                recentProjectStrip(project, account)
            }

            if vm.accounts.isEmpty {
                emptyState
            } else {
                accountList
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .toastOverlay(vm, edge: .top)
        .background {
            // Ensure standard Mac shortcuts work inside the popover even in `.accessory` mode when the menu is closed.
            Group {
                Button("") { openSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onChange(of: vm.isBusy) { _, busy in
            if !busy { isRestoringAfterUpdate = false }
        }
        .onChange(of: vm.updateGuardSavedCount) { _, count in
            if count == 0 { isRestoringAfterUpdate = false }
        }
        .onChange(of: restartingAccounts.count) { _, count in
            if count <= 1 { confirmingMCPRestartAll = false }
        }
        .onDisappear {
            confirmingMCPRestartAll = false
        }
    }

    private func activateAccount(_ account: AccountProfile) {
        if vm.runningStates[account.id]?.isFrozen == true {
            vm.resume(account: account)
        } else {
            vm.openOrFocus(account: account)
        }
    }

    private var accountList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 2) {
                let recommendedID = vm.accounts.count > 1 ? vm.recommendedAccount?.id : nil
                ForEach(Array(vm.accounts.enumerated()), id: \.element.id) { index, acc in
                    MenuAccountRow(
                        account: acc,
                        state: vm.runningStates[acc.id] ?? .stopped,
                        health: vm.egressHealth(for: acc),
                        isRecommended: acc.id == recommendedID,
                        operation: vm.operation(for: acc.id),
                        hotkey: vm.hotkeyLabel(forIndex: index),
                        now: vm.clock,
                        onPrimary: { activateAccount(acc) },
                        onSignIn: { vm.signInClaudeCode(for: acc) },
                        onRefresh: { vm.refreshQuota(for: acc) },
                        onFreeze: { vm.freeze(account: acc) },
                        onQuit: { vm.quit(account: acc) },
                        onEdit: { openMain { vm.showAccount(acc.id) } }
                    )
                    .appearAnimation(index: index)
                }
            }
            .padding(DS.Space.s)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: hasBanners ? 280 : 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        let guardSummary = vm.guardSummary
        let refreshing = !vm.quotaRefreshing.isEmpty
        return HStack(spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ClaudeDock")
                    .font(DS.Typo.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(guardSummary.tone.color)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(headerStatusText)
                        .font(DS.Typo.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help(guardSummary.detail)
                if let quotaSubtitle {
                    Text(quotaSubtitle)
                        .font(DS.Typo.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DS.Space.xs) {
                PopoverIconButton(systemImage: "arrow.clockwise", spinning: refreshing && !reduceMotion) {
                    vm.refreshAllQuotas()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(refreshing || vm.accounts.isEmpty)
                .help("刷新全部额度 (⌘R)")
                .accessibilityLabel("刷新全部额度")

                PopoverIconButton(systemImage: "macwindow") { openMain {} }
                    .help("打开工作台")
                    .accessibilityLabel("打开工作台")
            }
            .fixedSize()
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 10)
    }

    private func mcpRestartBanner(_ accounts: [AccountProfile]) -> some View {
        let isRestarting = accounts.contains { vm.operation(for: $0.id) != nil }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(confirmingMCPRestartAll
                     ? String(localized: "重启这 \(accounts.count) 个窗口可能会中断进行中的对话")
                     : String(localized: "重启后生效：MCP 配置已同步至 \(accounts.count) 个账号"))
                    .font(DS.Typo.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(accounts.map(\.name).joined(separator: String(localized: "、")))
                if isRestarting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在重启")
                } else if !confirmingMCPRestartAll {
                    Button(accounts.count > 1 ? String(localized: "全部重启") : String(localized: "重启")) {
                        if accounts.count > 1 {
                            confirmingMCPRestartAll = true
                        } else if let account = accounts.first {
                            vm.restartAccount(account)
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            if confirmingMCPRestartAll && !isRestarting {
                HStack(spacing: DS.Space.s) {
                    Spacer(minLength: 0)
                    Button("取消") {
                        confirmingMCPRestartAll = false
                    }
                    .controlSize(.small)
                    Button("确认重启") {
                        confirmingMCPRestartAll = false
                        for account in accounts { vm.restartAccount(account) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func recentProjectStrip(_ project: ClaudeProject, _ acc: AccountProfile) -> some View {
        let title = project.sessions.first?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HStack(spacing: DS.Space.s) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                if !title.isEmpty {
                    Text(title)
                        .font(DS.Typo.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)
            .help(project.path)

            ContinueButton(
                vm: vm,
                title: String(localized: "继续"),
                suggested: acc,
                lastAccountID: project.lastAccountID,
                compact: true,
                terminalAction: { account in
                    vm.launchClaudeCode(account: account, in: project.path, continueLatest: true)
                }
            ) { account in
                activateAccount(account)
            } more: {
                Divider()
                Button("查看全部项目…") { openMain { vm.navigate(to: .projects) } }
            }
            .frame(maxWidth: 148, alignment: .trailing)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var updateGuardNotice: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("更新前退出了 \(vm.updateGuardSavedCount) 个窗口")
                .font(DS.Typo.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isRestoringAfterUpdate && vm.isBusy {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("正在恢复…")
                        .font(DS.Typo.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            } else {
                Button("全部恢复") {
                    isRestoringAfterUpdate = true
                    vm.restoreAfterUpdate()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(vm.isBusy)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: DS.Space.xs) {
                Text("还没有添加账号")
                    .font(DS.Typo.headline)
                Text("添加账号后可在这里查看额度并一键切换")
                    .font(DS.Typo.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Button("添加第一个账号") { openMain { vm.requestAddAccount() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.xxl)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.xs) {
            PopoverFooterButton(title: String(localized: "添加账号"), systemImage: "plus") {
                openMain { vm.requestAddAccount() }
            }
            .keyboardShortcut("n", modifiers: .command)

            PopoverFooterButton(
                title: String(localized: "快速切换"), systemImage: "command",
                shortcut: QuickSwitcher.shared.isRegistered ? QuickSwitcher.shortcutLabel : nil
            ) {
                dismissPopover()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    QuickSwitcher.shared.show()
                }
            }
            .help(QuickSwitcher.shared.isRegistered
                  ? String(localized: "在任何应用里按 \(QuickSwitcher.shortcutLabel) 打开")
                  : String(localized: "打开快速切换（全局快捷键未注册，可能被其他应用占用）"))

            Spacer(minLength: DS.Space.xs)
            PopoverMenuButton(systemImage: "ellipsis.circle") {
                Button("更新 Claude 前退出全部窗口…") { openMain { vm.pendingConfirmation = .updateGuard } }
                    .disabled(vm.activeRunningCount == 0)
                Button("退出全部 Claude…") { openMain { vm.pendingConfirmation = .quitAll } }
                    .disabled(vm.activeRunningCount == 0)
                Button("同步 MCP 配置") { vm.syncDesktopMCP() }
                    .disabled(vm.accounts.isEmpty || vm.isBusy)
                Divider()
                Button("设置…") { openSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("退出 ClaudeDock") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .help("更多操作")
            .accessibilityLabel("更多")
        }
        .font(DS.Typo.secondary)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity)
    }

    private func openSettingsWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        openSettings()
        dismissPopover()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows
                where window.canBecomeMain && window.identifier?.rawValue.contains("main") != true {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func openMain(_ then: () -> Void) {
        then()
        if vm.openMainWindowAction == nil {
            let open = openWindow
            vm.openMainWindowAction = { open(id: "main") }
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        vm.showMainWindow()
        dismissPopover()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Account row

private struct MenuAccountRow: View {
    let account: AccountProfile
    let state: RunningState
    let health: EgressHealth
    let isRecommended: Bool
    let operation: AccountOperation?
    let hotkey: String?
    let now: Date
    let onPrimary: () -> Void
    let onSignIn: () -> Void
    let onRefresh: () -> Void
    let onFreeze: () -> Void
    let onQuit: () -> Void
    let onEdit: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var isCLIAvailable: Bool {
        account.cliLinked || account.isDefault
    }

    private var needsCLISignIn: Bool {
        account.quota == nil || account.quota?.status == .loggedOut
    }

    private var canSignIn: Bool {
        needsCLISignIn && isCLIAvailable
    }

    private var hasEgressCheck: Bool {
        !health.title.contains("未开启")
    }

    private var showsActionPill: Bool {
        (isHovered || isFocused) && operation == nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPrimary) {
                HStack(spacing: 0) {
                    rowContent
                    if operation == nil && !canSignIn {
                        primaryTrailingIndicator
                            .frame(width: 48, alignment: .trailing)
                            .padding(.trailing, 10)
                            .transaction {
                                $0.animation = nil
                                $0.disablesAnimations = true
                            }
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .disabled(operation != nil)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint(helpText)

            if operation != nil || canSignIn {
                secondaryTrailingSlot
                    .transaction {
                        $0.animation = nil
                        $0.disablesAnimations = true
                    }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .background(
            showsActionPill ? Color.primary.opacity(0.07) : .clear,
            in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .modifier(PopoverHoverState(isHovered: $isHovered))
        .help(tooltipText)
        .contextMenu { contextMenuItems }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            AccountAvatar(account: account, state: state, size: AccountAvatar.Size.row.rawValue)
            VStack(alignment: .leading, spacing: 3) {
                identityLine
                detailLine
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(primaryTitle, action: onPrimary).disabled(operation != nil)
        if canSignIn {
            Button("登录 Claude Code…", action: onSignIn).disabled(operation != nil)
        }
        Button("刷新额度", action: onRefresh)
        Button("编辑设置…", action: onEdit)
        if state.isActive {
            Divider()
            if !state.isFrozen {
                Button("暂停", action: onFreeze).disabled(operation != nil)
            }
            Button("退出", role: .destructive, action: onQuit).disabled(operation != nil)
        }
    }

    /// Reserves readable room for the account name and badges so urgent reset text never crushes the identity.
    private var identityMinWidth: CGFloat {
        // The badge is measured from its localized text: "推荐" is short, "Recommended" is not.
        let badge = String(localized: "推荐")
        let badgeWidth = badge.unicodeScalars.reduce(CGFloat(14)) { $0 + ($1.value > 0x2E80 ? 11 : 6.2) }
        return 76 + (isRecommended ? badgeWidth : 0) + (health.needsAttention ? 18 : 0)
    }

    private var identityLine: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(account.name)
                    .font(DS.Typo.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isRecommended {
                    Tag(text: String(localized: "推荐"), color: .green)
                        .fixedSize()
                }
                if health.needsAttention {
                    Image(systemName: health.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(health.tone.color)
                        .symbolRenderingMode(.hierarchical)
                        .fixedSize()
                        .help(health.title)
                }
            }
            .frame(minWidth: identityMinWidth, alignment: .leading)

            if let urgent = urgentResetWindow {
                Spacer(minLength: 6)
                urgentResetCaptionView(label: urgent.label, window: urgent.window)
            }
        }
    }

    private var urgentResetWindow: (label: String, window: QuotaWindow)? {
        guard let quota = account.quota, quota.status != .loggedOut else { return nil }
        let liveWindows: [(String, QuotaWindow)] = [
            quota.fiveHour.map { ("5h", $0) },
            quota.sevenDay.map { ("7d", $0) }
        ]
        .compactMap { $0 }
        .filter { !$0.1.isExpired(at: now) && $0.1.resetsAt > 0 }

        guard let best = liveWindows.min(by: { $0.1.remainingPercentage < $1.1.remainingPercentage }),
              best.1.remainingPercentage <= 30,
              !QuotaFormat.shortReset(best.1, now: now).isEmpty else { return nil }
        return best
    }

    private func urgentResetCaptionView(label: String, window: QuotaWindow) -> some View {
        let color = QuotaFormat.tone(remaining: window.remainingPercentage)
        let short = "\(label) \(QuotaFormat.shortReset(window, now: now))"
        let clock = QuotaFormat.resetClock(window, now: now)
        let medium = clock.isEmpty ? nil : "\(short) · \(clock)"
        return ViewThatFits(in: .horizontal) {
            if let medium {
                urgentText(medium, color: color)
            }
            urgentText(short, color: color)
            Text(short)
                .font(DS.Typo.caption)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func urgentText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(DS.Typo.caption)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private var detailLine: some View {
        if let operation {
            Text(operation.label)
                .font(DS.Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if let quota = account.quota, quota.status == .loggedOut {
            if quota.fiveHour != nil || quota.sevenDay != nil {
                Text("已退出登录 · 上次 \(cachedQuotaSummary(quota))")
                    .font(DS.Typo.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(missingQuotaCopy)
                    .font(DS.Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if let quota = account.quota, quota.fiveHour != nil || quota.sevenDay != nil {
            HStack(spacing: 12) {
                if let window = quota.fiveHour {
                    CompactQuotaMeter(label: "5h", window: window, now: now)
                }
                if let window = quota.sevenDay {
                    CompactQuotaMeter(label: "7d", window: window, now: now)
                }
            }
        } else {
            Text(missingQuotaCopy)
                .font(DS.Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func cachedQuotaSummary(_ quota: QuotaSnapshot) -> String {
        var items: [String] = []
        if let w = quota.fiveHour {
            items.append("5h \(cachedWindowValue(w))")
        }
        if let w = quota.sevenDay {
            items.append("7d \(cachedWindowValue(w))")
        }
        return items.joined(separator: " · ")
    }

    private func cachedWindowValue(_ window: QuotaWindow) -> String {
        if window.isExpired(at: now) { return String(localized: "待刷新") }
        if QuotaFormat.isConfirmedRecovered(window, now: now) { return String(localized: "已恢复") }
        return "\(Int(max(0, min(100, window.remainingPercentage)).rounded()))%"
    }

    private var missingQuotaCopy: String {
        if needsCLISignIn && !isCLIAvailable {
            return String(localized: "未关联 Claude Code，在设置中开启后显示额度")
        }
        if account.quota?.status == .loggedOut {
            return String(localized: "未登录 Claude Code，登录后显示额度")
        }
        return QuotaCopy.missing(account.quota)
    }

    @ViewBuilder
    private var primaryTrailingIndicator: some View {
        if showsActionPill {
            Text(state.isFrozen ? String(localized: "恢复") : primaryTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    state.isFrozen ? Color(red: 0.72, green: 0.33, blue: 0) : Color.accentColor,
                    in: Capsule()
                )
        } else if let hotkey {
            KeyCap(text: hotkey)
        } else {
            Color.clear.frame(height: 20)
        }
    }

    @ViewBuilder
    private var secondaryTrailingSlot: some View {
        if operation != nil {
            ProgressView()
                .controlSize(.small)
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 10)
                .accessibilityHidden(true)
        } else if canSignIn {
            Button("登录", action: onSignIn)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help("打开终端，登录这个账号的 Claude Code")
                .accessibilityLabel("登录 \(account.name) 的 Claude Code")
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 10)
        }
    }

    private var primaryTitle: String {
        if state.isFrozen { return hasEgressCheck ? String(localized: "检测并恢复") : String(localized: "恢复") }
        return state.isActive ? String(localized: "切换") : String(localized: "打开")
    }

    private var helpText: String {
        if state.isFrozen {
            return hasEgressCheck ? String(localized: "检测出口，通过后恢复 \(account.name)") : String(localized: "恢复 \(account.name)")
        }
        return state.isActive ? String(localized: "切换到 \(account.name) 的窗口") : String(localized: "打开 \(account.name)")
    }

    private var accessibilitySummary: String {
        var parts = [account.name, state.label]
        if let operation { parts.append(operation.label) }
        if let quota = account.quota, quota.status == .loggedOut {
            parts.append(String(localized: "Claude Code 已退出登录"))
        } else if let quota = account.quota, quota.fiveHour != nil || quota.sevenDay != nil {
            let windows = [quota.fiveHour, quota.sevenDay].compactMap { $0 }
            if windows.contains(where: { $0.isExpired(at: now) }) {
                parts.append(String(localized: "额度待刷新"))
            } else if windows.allSatisfy({ QuotaFormat.isConfirmedRecovered($0, now: now) }) {
                parts.append(String(localized: "额度已恢复"))
            } else if let minRemaining = windows.map(\.remainingPercentage).min() {
                parts.append(String(localized: "剩余额度 \(Int(minRemaining.rounded()))%"))
            }
        } else {
            parts.append(missingQuotaCopy)
        }
        parts.append(contentsOf: quotaDetails)
        if let quota = account.quota, quota.fiveHour != nil || quota.sevenDay != nil {
            parts.append(QuotaFormat.updatedText(quota.checkedAt, now: now))
        }
        if isRecommended { parts.append(String(localized: "推荐")) }
        if health.needsAttention { parts.append(health.title) }
        if let hotkey { parts.append(String(localized: "快捷键 \(hotkey)")) }
        return parts.joined(separator: String(localized: "，"))
    }

    private var tooltipText: String {
        var lines: [String] = []
        if let email = account.identity?.email, !email.isEmpty {
            lines.append(email)
        }
        lines.append(contentsOf: quotaDetails)
        lines.append(helpText)
        if let quota = account.quota, quota.fiveHour != nil || quota.sevenDay != nil {
            lines.append(QuotaFormat.updatedText(quota.checkedAt, now: now))
        }
        return lines.joined(separator: "\n")
    }

    private var quotaDetails: [String] {
        guard let quota = account.quota else { return [] }
        var lines: [String] = []
        if let window = quota.fiveHour {
            lines.append(windowTooltipLine(String(localized: "5 小时额度"), window))
        }
        if let window = quota.sevenDay {
            lines.append(windowTooltipLine(String(localized: "7 天额度"), window))
        }
        if quota.status == .loggedOut && !lines.isEmpty {
            lines.append(String(localized: "Claude Code 未登录（当前为缓存额度）"))
        }
        return lines
    }

    private func windowTooltipLine(_ title: String, _ window: QuotaWindow) -> String {
        let reset = QuotaFormat.resetText(window, now: now)
        if window.isExpired(at: now) {
            return String(localized: "\(title)：待刷新，\(reset)")
        }
        if QuotaFormat.isConfirmedRecovered(window, now: now) {
            return String(localized: "\(title)：已恢复，\(reset)")
        }
        return String(localized: "\(title)：剩余 \(Int(window.remainingPercentage.rounded()))%，\(reset)")
    }
}

private struct CompactQuotaMeter: View {
    let label: String
    let window: QuotaWindow
    let now: Date

    var body: some View {
        let expired = window.isExpired(at: now)
        let recovered = QuotaFormat.isConfirmedRecovered(window, now: now)
        let remaining = max(0, min(100, window.remainingPercentage))
        let tone: Color = QuotaFormat.tone(remaining: remaining)
        return HStack(spacing: 5) {
            Text(label)
                .font(DS.Typo.micro)
                .foregroundStyle(.secondary)
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 30, height: 4)
                .overlay(alignment: .leading) {
                    if !expired {
                        // Reveal the exact fraction of the track, even below one endcap's width.
                        Rectangle()
                            .fill(tone)
                            .frame(width: 30 * CGFloat(remaining) / 100)
                    }
                }
                .clipShape(Capsule())
            Group {
                if expired {
                    Text("待刷新")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if recovered {
                    Text("已恢复")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Text("\(Int(remaining.rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(remaining <= 30 ? tone : Color.primary)
                }
            }
            .frame(minWidth: 34, alignment: .leading)
        }
        .monospacedDigit()
        .fixedSize()
        .accessibilityHidden(true)
    }
}

// MARK: - Popover controls

private struct PopoverHoverState: ViewModifier {
    @Binding var isHovered: Bool
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content
            .onHover { isHovered = $0 }
            .onChange(of: activeState) { _, state in
                if state != .key { isHovered = false }
            }
            .onDisappear { isHovered = false }
    }
}

private struct PopoverIconButton: View {
    let systemImage: String
    var spinning = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(spinning ? phase * 360 : 0))
                    .transaction { $0.animation = nil }
            }
            .foregroundStyle(isEnabled ? HierarchicalShapeStyle.primary : .tertiary)
            .frame(width: 24, height: 24)
            .background(
                isHovered && isEnabled ? Color.primary.opacity(0.07) : .clear,
                in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(PopoverHoverState(isHovered: $isHovered))
    }
}

private struct PopoverMenuButton<MenuItems: View>: View {
    let systemImage: String
    @ViewBuilder let menuItems: () -> MenuItems

    @State private var isHovered = false

    var body: some View {
        Menu {
            menuItems()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .background(
            isHovered ? Color.primary.opacity(0.07) : .clear,
            in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
        )
        .contentShape(Rectangle())
        .modifier(PopoverHoverState(isHovered: $isHovered))
    }
}

private struct PopoverFooterButton: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(DS.Typo.secondary)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let shortcut {
                    KeyCap(text: shortcut)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                isHovered ? Color.primary.opacity(0.07) : .clear,
                in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(PopoverHoverState(isHovered: $isHovered))
        .accessibilityLabel(shortcut.map { String(localized: "\(title)，快捷键 \($0)") } ?? title)
    }
}
