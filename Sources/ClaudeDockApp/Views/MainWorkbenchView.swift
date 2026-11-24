// FILE: Views/MainWorkbenchView.swift
import AppKit
import ClaudeDockCore
import SwiftUI
import UniformTypeIdentifiers

/// Main window: unified seamless titlebar, translucent custom sidebar, pinned incident banners, and bottom toasts.
struct MainWorkbenchView: View {
    @ObservedObject var vm: DockViewModel
    @State private var draggedAccountID: String?
    @State private var dragPreviewOrder: [String]?
    @State private var dragResetTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 208, ideal: 228, max: 268)
        } detail: {
            GeometryReader { proxy in
                let topClearance = max(0, DS.Space.titlebarHeight - proxy.safeAreaInsets.top)
                VStack(spacing: 0) {
                    if topClearance > 0 {
                        Spacer().frame(height: topClearance)
                    }
                    if vm.guidedSignIn != nil {
                        GuidedSignInBanner(vm: vm)
                            .padding(.horizontal, DS.Space.page)
                            .padding(.top, DS.Space.s)
                            .padding(.bottom, DS.Space.xs)
                    }
                    if !vm.activeAlerts.isEmpty {
                        IncidentStack(vm: vm)
                            .padding(.horizontal, DS.Space.page)
                            .padding(.top, DS.Space.s)
                            .padding(.bottom, DS.Space.xs)
                    }
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(vm.route)
                        .transition(DS.Motion.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .background(DS.canvas.ignoresSafeArea())
            .navigationTitle("")
            .hidingToolbarTitle()
        }
        .seamlessWindowToolbar()
        .frame(minWidth: 880, minHeight: 580)
        .toolbar { toolbarContent }
        .toastOverlay(vm)
        .background(WindowObserver { window in
            WindowObserver.applyUnifiedChrome(to: window)

            if !MainWindowLifecycle.didLaunch {
                MainWindowLifecycle.didLaunch = true
                if !vm.settings.openMainWindowAtLaunch, ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15 {
                    window.close()
                    AppDelegate.mainWindowVisibilityChanged(visible: false, hideDockWhenClosed: vm.settings.hideDockIconWhenClosed)
                    return
                }
            }
            vm.isMainWindowVisible = true
            vm.refreshProjects()
            AppDelegate.mainWindowVisibilityChanged(visible: true, hideDockWhenClosed: vm.settings.hideDockIconWhenClosed)
        } onBecomeKey: {
            if !vm.isMainWindowVisible {
                vm.isMainWindowVisible = true
                vm.refreshProjects()
            }
            AppDelegate.mainWindowVisibilityChanged(visible: true, hideDockWhenClosed: vm.settings.hideDockIconWhenClosed)
        } onClose: {
            vm.isMainWindowVisible = false
            AppDelegate.mainWindowVisibilityChanged(visible: false, hideDockWhenClosed: vm.settings.hideDockIconWhenClosed)
        })
        .sheet(isPresented: $vm.isAddingAccount) {
            AddAccountSheet(vm: vm)
        }
        .confirmationDialog(
            "有还没保存的修改",
            isPresented: Binding(
                get: { vm.pendingNavigation != nil },
                set: { presented in
                    if !presented {
                        Task { @MainActor in
                            if vm.pendingNavigation != nil {
                                vm.resolvePendingNavigation(save: nil)
                            }
                        }
                    }
                }
            )
        ) {
            Button("保存并继续") { vm.resolvePendingNavigation(save: true) }
            Button("不保存", role: .destructive) { vm.resolvePendingNavigation(save: false) }
            Button("继续编辑", role: .cancel) { vm.resolvePendingNavigation(save: nil) }
        } message: {
            Text("离开前要保存这个账号的修改吗？")
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { vm.pendingConfirmation != nil }, set: { if !$0 { vm.pendingConfirmation = nil } }),
            presenting: vm.pendingConfirmation
        ) { kind in
            switch kind {
            case .updateGuard:
                Button("退出并记住") { vm.startUpdateGuard() }
            case .quitAll:
                Button("全部退出", role: .destructive) { vm.quitAll() }
            case .guidedSignIn(let acc):
                Button(vm.otherRunningAccounts(than: acc).isEmpty ? String(localized: "开始登录") : String(localized: "暂时关闭并登录")) {
                    vm.beginGuidedSignIn(acc)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { kind in
            Text(confirmationMessage(kind))
        }
    }

    @ViewBuilder
    private var page: some View {
        switch vm.route {
        case .deck: DeckPage(vm: vm)
        case .accounts: AccountsManagerTab(vm: vm)
        case .projects: ProjectsPage(vm: vm)
        case .network: NetworkPage(vm: vm)
        case .sharing: ConfigSyncTab(vm: vm)
        }
    }

    // MARK: Custom Translucent Sidebar

    private var activeSelection: SidebarItem {
        if vm.route == .accounts, let id = vm.selectedAccountID, vm.accounts.contains(where: { $0.id == id }) {
            return .account(id)
        }
        return .route(vm.route)
    }

    private var displayedSidebarAccounts: [AccountProfile] {
        guard let order = dragPreviewOrder else { return vm.accounts }
        let byID = Dictionary(vm.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = order.compactMap { byID[$0] }
        guard ordered.count == vm.accounts.count else { return vm.accounts }
        return ordered
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: DS.Space.titlebarHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(AppRoute.allCases) { route in
                            let item = SidebarItem.route(route)
                            let selected = activeSelection == item
                            let count = badge(for: route)
                            let isUrgent = route == .network && count > 0

                            Button {
                                if route == .accounts, vm.unsavedEdits == nil {
                                    vm.selectedAccountID = nil
                                }
                                vm.navigate(to: route)
                            } label: {
                                HStack(spacing: DS.Space.s) {
                                    Image(systemName: route.symbol)
                                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                                        .frame(width: 18, alignment: .center)
                                    Text(route.title)
                                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if count > 0 {
                                        SidebarBadge(
                                            "\(count)",
                                            tone: isUrgent ? DS.Semantic.caution : Color.accentColor,
                                            emphasized: true
                                        )
                                    }
                                }
                                .sidebarRowStyle(selected: selected, accent: .accentColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }

                    if !vm.accounts.isEmpty {
                        let accounts = displayedSidebarAccounts
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            HStack(spacing: DS.Space.xs) {
                                Text("账号列表")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .help("拖动排序，顺序对应 ⌘⌥1–9")
                                Spacer()
                                Button {
                                    vm.requestAddAccount()
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.dsGhostIcon(size: 22))
                                .help("添加一个 Claude 账号（⌘N）")
                                .accessibilityLabel("添加账号")
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(accounts.enumerated()), id: \.element.id) { idx, acc in
                                    let selected = activeSelection == .account(acc.id)
                                    SidebarAccountRow(
                                        account: acc,
                                        state: vm.runningStates[acc.id] ?? .stopped,
                                        hotkey: vm.hotkeyLabel(forIndex: idx),
                                        isSelected: selected,
                                        now: vm.clock,
                                        onSelect: { vm.navigate(to: .accounts, account: acc.id) },
                                        onDoubleClick: { vm.openOrFocus(account: acc) }
                                    )
                                    .onDrag {
                                        dragResetTask?.cancel()
                                        dragResetTask = nil
                                        draggedAccountID = acc.id
                                        dragPreviewOrder = vm.accounts.map(\.id)
                                        return AccountSidebarDropDelegate.itemProvider(for: acc.id)
                                    }
                                    .onDrop(
                                        of: [AccountSidebarDropDelegate.dragType],
                                        delegate: AccountSidebarDropDelegate(
                                            targetID: acc.id,
                                            draggedID: draggedAccountID,
                                            onCancelReset: {
                                                dragResetTask?.cancel()
                                                dragResetTask = nil
                                            },
                                            onPreviewMove: { draggedID, targetID in
                                                previewMoveAccount(draggedID: draggedID, toTarget: targetID)
                                            },
                                            onCommit: { draggedID in
                                                commitAccountDrop(draggedID: draggedID)
                                            },
                                            onScheduleReset: {
                                                scheduleDragReset()
                                            }
                                        )
                                    )
                                    .contextMenu {
                                        Button("打开或切换") { vm.openOrFocus(account: acc) }
                                        Button("编辑设置…") { vm.showAccount(acc.id) }
                                        Divider()
                                        Button("上移") { vm.moveAccount(acc, by: -1) }
                                            .disabled(idx == 0)
                                        Button("下移") { vm.moveAccount(acc, by: 1) }
                                            .disabled(idx == accounts.count - 1)
                                    }
                                    .accessibilityAction(named: "打开或切换") { vm.openOrFocus(account: acc) }
                                    .accessibilityAction(named: "上移") { vm.moveAccount(acc, by: -1) }
                                    .accessibilityAction(named: "下移") { vm.moveAccount(acc, by: 1) }
                                }
                            }
                            .onHover { _ in
                                if dragPreviewOrder == nil, draggedAccountID != nil {
                                    draggedAccountID = nil
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.top, DS.Space.s)
                .padding(.bottom, DS.Space.m)
            }

            guardFooter
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow).ignoresSafeArea())
    }

    private func previewMoveAccount(draggedID: String, toTarget targetID: String) {
        dragResetTask?.cancel()
        dragResetTask = nil
        var order = dragPreviewOrder ?? vm.accounts.map(\.id)
        guard draggedID != targetID,
              let from = order.firstIndex(of: draggedID),
              let to = order.firstIndex(of: targetID)
        else {
            if dragPreviewOrder == nil { dragPreviewOrder = order }
            return
        }
        withAnimation(DS.Motion.quick) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            dragPreviewOrder = order
        }
    }

    private func commitAccountDrop(draggedID: String) {
        dragResetTask?.cancel()
        dragResetTask = nil
        defer {
            draggedAccountID = nil
            dragPreviewOrder = nil
        }
        guard let order = dragPreviewOrder,
              let originalIndex = vm.accounts.firstIndex(where: { $0.id == draggedID }),
              let finalIndex = order.firstIndex(of: draggedID),
              originalIndex != finalIndex
        else { return }
        let destination = finalIndex > originalIndex ? finalIndex + 1 : finalIndex
        vm.moveAccounts(from: IndexSet(integer: originalIndex), to: destination)
    }

    private func scheduleDragReset() {
        dragResetTask?.cancel()
        dragResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.quick) {
                dragPreviewOrder = nil
            }
            dragResetTask = nil
        }
    }

    private func badge(for route: AppRoute) -> Int {
        switch route {
        case .network: return vm.accounts.filter { vm.egressHealth(for: $0).needsAttention }.count
        case .projects: return vm.liveSessions.count
        default: return 0
        }
    }

    private var guardFooter: some View {
        SidebarGuardFooter(summary: vm.guardSummary) {
            vm.navigate(to: .network)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.m)
        .padding(.top, DS.Space.xs)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                vm.requestAddAccount()
            } label: {
                Label("添加账号", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .help("添加一个 Claude 账号（⌘N）")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if vm.updateGuardSavedCount > 0 {
                Button {
                    vm.restoreAfterUpdate()
                } label: {
                    Label(
                        vm.isBusy ? String(localized: "正在恢复…") : String(localized: "恢复 \(vm.updateGuardSavedCount) 个窗口"),
                        systemImage: "arrow.uturn.backward.circle"
                    )
                }
                .disabled(vm.isBusy)
                .help("重新打开更新 Claude 前退出的窗口")
            }

            Button {
                vm.refreshAllQuotas()
            } label: {
                Label("刷新额度", systemImage: "arrow.clockwise")
            }
            .disabled(!vm.quotaRefreshing.isEmpty || vm.accounts.isEmpty)
            .help("刷新全部账号的剩余额度，不消耗用量（⇧⌘R）")

            Menu {
                Button("更新 Claude 前退出全部窗口…") { vm.pendingConfirmation = .updateGuard }
                    .disabled(vm.activeRunningCount == 0)
                Button("退出全部 Claude…") { vm.pendingConfirmation = .quitAll }
                    .disabled(vm.activeRunningCount == 0)
                Divider()
                Button("同步 MCP 配置") { vm.syncDesktopMCP() }
                SettingsLink { Text("设置…") }
                    .keyboardShortcut(",", modifiers: .command)
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Confirmations

    private var confirmationTitle: String {
        switch vm.pendingConfirmation {
        case .updateGuard: return String(localized: "退出全部窗口，准备更新 Claude？")
        case .quitAll: return String(localized: "退出全部 Claude？")
        case .guidedSignIn(let acc): return String(localized: "为 \(acc.name) 登录 Claude")
        case nil: return ""
        }
    }

    private func confirmationMessage(_ kind: PendingConfirmation) -> String {
        let names = vm.runningAccounts.map(\.name)
        switch kind {
        case .updateGuard:
            guard !names.isEmpty else { return String(localized: "当前没有运行中的 Claude 窗口，可直接更新 Claude。") }
            return String(localized: "会退出：\(names.joined(separator: String(localized: "、")))。ClaudeDock 会记住它们，更新完成后可以一键恢复。")
        case .quitAll:
            guard !names.isEmpty else { return String(localized: "当前没有运行中的 Claude 窗口。") }
            return String(localized: "会退出：\(names.joined(separator: String(localized: "、")))。未发送的内容可能会丢失。")
        case .guidedSignIn(let acc):
            let others = vm.otherRunningAccounts(than: acc).map(\.name)
            guard !others.isEmpty else {
                return String(localized: "即将打开 \(acc.name) 的窗口进行登录，收到登录邮件时请用浏览器打开链接。")
            }
            return String(localized: "登录时浏览器会把结果交回 Claude，但同时开着多个 Claude 窗口时，结果会被先打开的那个接走。登录期间会暂时关闭 \(others.joined(separator: String(localized: "、")))，登录成功后自动重新打开。")
        }
    }
}

// MARK: - Sidebar Supporting Components

private struct SidebarAccountRow: View {
    let account: AccountProfile
    let state: RunningState
    let hotkey: String?
    let isSelected: Bool
    let now: Date
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            AccountAvatar(account: account, state: state, size: AccountAvatar.Size.small.rawValue)
            Text(account.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let headroom = account.quota?.effectiveHeadroom(at: now) {
                let low = headroom <= 30
                SidebarBadge(
                    "\(Int(headroom.rounded()))%",
                    tone: low ? QuotaFormat.tone(remaining: headroom) : .secondary,
                    emphasized: low
                )
                .help("剩余额度（取 5\u{00A0}小时与 7\u{00A0}天中较少的一个）")
            }
        }
        .sidebarRowStyle(selected: isSelected, accent: account.accentColor)
        .onTapGesture(count: 2) {
            onDoubleClick()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .focusable()
        .onKeyPress(.return) {
            onSelect()
            return .handled
        }
        .onKeyPress(.space) {
            onSelect()
            return .handled
        }
        .help(hotkey.map { String(localized: "双击打开或切换 · \($0)") } ?? String(localized: "双击打开或切换"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction {
            onSelect()
        }
    }
}

private struct SidebarGuardFooter: View {
    let summary: GuardSummary
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                ZStack {
                    Circle()
                        .fill(summary.tone.color.opacity(0.14))
                        .frame(width: 26, height: 26)
                    Image(systemName: summary.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(summary.tone.color)
                        .symbolRenderingMode(.hierarchical)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("出口守护 · \(summary.title)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(summary.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(DS.Space.m)
            .background(shape.fill(Color.primary.opacity(isHovered ? 0.065 : 0.04)))
            .overlay(shape.strokeBorder(DS.hairline, lineWidth: 1 / max(1, displayScale)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.quick) { isHovered = hovering }
        }
        .help("查看每个账号的出口守护状态")
    }
}

private struct AccountSidebarDropDelegate: DropDelegate {
    static let dragType: UTType =
        UTType(tag: "claudedock-account-id", tagClass: .filenameExtension, conformingTo: .data) ?? .data

    let targetID: String
    let draggedID: String?
    let onCancelReset: () -> Void
    let onPreviewMove: (String, String) -> Void
    let onCommit: (String) -> Void
    let onScheduleReset: () -> Void

    static func itemProvider(for accountID: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(accountID.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil && info.hasItemsConforming(to: [Self.dragType])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info), let draggedID else { return }
        onPreviewMove(draggedID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return DropProposal(operation: .cancel)
        }
        onCancelReset()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard draggedID != nil else { return }
        onScheduleReset()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let draggedID else { return false }
        onCommit(draggedID)
        return true
    }
}

// MARK: - Workbench Page

struct DeckPage: View {
    @ObservedObject var vm: DockViewModel

    var body: some View {
        if vm.accounts.isEmpty {
            OnboardingView(vm: vm)
        } else {
            PageScroll {
                PageHeader(String(localized: "工作台"), subtitle: subtitle)
                metrics
                quotaWarnings
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    SectionHeader(
                        String(localized: "全部账号"),
                        detail: String(localized: "双击卡片切换 · 快捷键 \(vm.hotkeySummary)"),
                        count: vm.accounts.count
                    )
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 350, maximum: .infinity), spacing: DS.Space.l)],
                        spacing: DS.Space.l
                    ) {
                        let recommendedID = vm.recommendedAccount?.id
                        ForEach(Array(vm.accounts.enumerated()), id: \.element.id) { idx, acc in
                            AccountCardView(
                                account: acc,
                                index: idx,
                                state: vm.runningStates[acc.id] ?? .stopped,
                                alert: vm.activeAlerts[acc.id],
                                health: vm.egressHealth(for: acc),
                                isRecommended: acc.id == recommendedID && vm.accounts.count > 1,
                                operation: vm.operation(for: acc.id),
                                hotkeyLabel: vm.hotkeyLabel(forIndex: idx),
                                isRefreshingQuota: vm.isRefreshingQuota(acc.id),
                                now: vm.clock,
                                onOpenOrFocus: { vm.openOrFocus(account: acc) },
                                onFreeze: { vm.freeze(account: acc) },
                                onResume: { vm.resume(account: acc) },
                                onQuit: { vm.quit(account: acc) },
                                onPinEgress: { vm.pinCurrentEgress(for: acc) },
                                onRefreshQuota: { vm.refreshQuota(for: acc) },
                                onEdit: { vm.showAccount(acc.id) },
                                onSignIn: { vm.signInClaudeCode(for: acc) },
                                onDesktopSignIn: acc.isDefault ? nil : {
                                    if vm.otherRunningAccounts(than: acc).isEmpty { vm.beginGuidedSignIn(acc) }
                                    else { vm.pendingConfirmation = .guidedSignIn(acc) }
                                }
                            )
                            .appearAnimation(index: idx)
                        }
                        AddAccountCard { vm.requestAddAccount() }
                            .appearAnimation(index: vm.accounts.count)
                    }
                }
                RecentProjectsSection(vm: vm)
            }
        }
    }

    private var subtitle: String {
        let running = vm.activeRunningCount
        return running == 0
            ? String(localized: "共 \(vm.accounts.count) 个账号 · 当前均未运行")
            : String(localized: "共 \(vm.accounts.count) 个账号 · \(running) 个正在运行")
    }

    private var metrics: some View {
        let headrooms: [(AccountProfile, Double)] = vm.accounts.compactMap { acc in
            guard let headroom = acc.quota?.effectiveHeadroom(at: vm.clock) else { return nil }
            return (acc, headroom)
        }
        let topHeadroom = headrooms.max { $0.1 < $1.1 }

        return HStack(alignment: .top, spacing: DS.Space.l) {
            if let best = vm.recommendedAccount, vm.accounts.count > 1 {
                let bestTone: Color = {
                    if let headroom = best.quota?.effectiveHeadroom(at: vm.clock), headroom <= 30 {
                        return QuotaFormat.tone(remaining: headroom)
                    }
                    return DS.Semantic.verified
                }()
                MetricTile(
                    title: String(localized: "推荐账号"),
                    value: best.name,
                    detail: vm.recommendationReason(for: best),
                    symbol: "sparkles",
                    tone: bestTone
                ) {
                    Button(vm.runningStates[best.id]?.isActive == true ? String(localized: "切换") : String(localized: "打开")) {
                        vm.openOrFocus(account: best)
                    }
                    .buttonStyle(.dsSecondary(tint: best.accentColor))
                    .controlSize(.small)
                    .disabled(vm.operation(for: best.id) != nil)
                }
            }
            MetricTile(
                title: String(localized: "正在运行"),
                value: "\(vm.activeRunningCount) / \(vm.accounts.count)",
                detail: vm.runningAccounts.isEmpty ? String(localized: "当前没有打开的窗口") : vm.runningAccounts.map(\.name).joined(separator: String(localized: "、")),
                symbol: "macwindow.on.rectangle",
                tone: .accentColor,
                isNumeric: true
            )
            MetricTile(
                title: String(localized: "最高余量"),
                value: topHeadroom.map { "\(max(0, Int($0.1.rounded())))%" } ?? String(localized: "未检测"),
                detail: topHeadroom.map { best in
                    headrooms.count == 1
                        ? String(localized: "\(best.0.name) 当前余量")
                        : String(localized: "\(best.0.name) 最高 · 已检测 \(headrooms.count) / \(vm.accounts.count) 个账号")
                } ?? String(localized: "刷新额度不消耗对话用量"),
                symbol: "gauge.with.dots.needle.67percent",
                tone: topHeadroom.map { QuotaFormat.tone(remaining: $0.1) } ?? .secondary,
                isNumeric: topHeadroom != nil
            ) {
                Button(vm.quotaRefreshing.isEmpty ? String(localized: "刷新") : String(localized: "刷新中")) {
                    vm.refreshAllQuotas()
                }
                .buttonStyle(.dsSecondary)
                .controlSize(.small)
                .disabled(!vm.quotaRefreshing.isEmpty || vm.accounts.isEmpty)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func resetText(_ alert: QuotaThresholdAlert) -> String {
        let acc = vm.accounts.first { $0.id == alert.accountID }
        let window = alert.windowName == "5-hour" ? acc?.quota?.fiveHour : acc?.quota?.sevenDay
        guard let window else { return String(localized: "额度稍后重置") }
        let text = QuotaFormat.resetText(window, now: vm.clock)
        if text == String(localized: "待刷新") { return String(localized: "额度重置时间已到（待刷新）") }
        if text == String(localized: "已恢复") { return String(localized: "额度已恢复") }
        return String(localized: "重置倒计时：\(text)")
    }

    @ViewBuilder
    private var quotaWarnings: some View {
        if !vm.quotaAlerts.isEmpty {
            VStack(spacing: DS.Space.s) {
                ForEach(vm.quotaAlerts, id: \.key) { alert in
                    HStack(spacing: DS.Space.m) {
                        ZStack {
                            Circle()
                                .fill(DS.Semantic.caution.opacity(0.15))
                                .frame(width: 32, height: 32)
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DS.Semantic.caution)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            let windowLabel = alert.windowName == "5-hour" ? String(localized: "5\u{00A0}小时") : String(localized: "7\u{00A0}天")
                            let remaining = max(0, Int((100 - alert.usedPercentage).rounded()))
                            Text(
                                remaining == 0
                                    ? String(localized: "\(alert.accountName) 的 \(windowLabel)额度已用尽")
                                    : String(localized: "\(alert.accountName) 的 \(windowLabel)额度仅剩 \(remaining)%")
                            )
                            .font(DS.Typo.headline)
                            Text(
                                alert.recommendedNext.map { String(localized: "\($0.name) 还有余量，可无缝切换继续使用") }
                                    ?? String(localized: "\(resetText(alert))，暂时没有同组的其他账号可切换")
                            )
                            .font(DS.Typo.secondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: DS.Space.s)
                        if let next = alert.recommendedNext {
                            Button("切换到 \(next.name)") { vm.openOrFocus(account: next) }
                                .buttonStyle(.dsPrimary(tint: DS.Semantic.caution))
                                .disabled(vm.operation(for: next.id) != nil)
                        }
                    }
                    .padding(DS.Space.l)
                    .surface(accent: DS.Semantic.caution, tint: DS.Semantic.caution)
                }
            }
        }
    }
}

// MARK: - Onboarding

/// First run: concise three-pillar introduction and a single prominent call to action.
struct OnboardingView: View {
    @ObservedObject var vm: DockViewModel

    init(vm: DockViewModel) {
        self.vm = vm
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.xxl) {
                Spacer(minLength: DS.Space.l)

                EmptyStateView(
                    symbol: "square.stack.3d.up.fill",
                    title: String(localized: "把你的 Claude 账号放在一起"),
                    message: String(localized: "并行打开多个官方桌面窗口，实时掌握剩余额度与出口状态，一键从容切换。")
                ) {
                    VStack(spacing: DS.Space.s) {
                        Button {
                            vm.requestAddAccount()
                        } label: {
                            Label("添加第一个账号", systemImage: "plus")
                                .padding(.horizontal, DS.Space.s)
                        }
                        .buttonStyle(.dsPrimary(tint: DS.Semantic.brand))
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)

                        Text("支持直接接入已登录的本地 Claude，无需重新登录")
                            .font(DS.Typo.secondary)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, DS.Space.xs)
                }

                HStack(alignment: .top, spacing: DS.Space.l) {
                    feature(
                        "rectangle.stack.fill",
                        String(localized: "多账号并行在线"),
                        String(localized: "每个账号拥有独立配置与窗口，登录态与本地会话互不干扰。")
                    )
                    feature(
                        "gauge.with.dots.needle.67percent",
                        String(localized: "剩余额度一目了然"),
                        String(localized: "直观对比 5\u{00A0}小时与 7\u{00A0}天窗口余量，刷新检测不消耗对话额度。")
                    )
                    feature(
                        "checkmark.shield.fill",
                        String(localized: "出口节点实时守护"),
                        String(localized: "启动前校验代理出口，运行中节点漂移可自动暂停账号请求。")
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 820)

                Spacer(minLength: DS.Space.l)
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.vertical, DS.Space.xl)
            .frame(maxWidth: .infinity, minHeight: 500)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Semantic.brand.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Semantic.brand)
                    .symbolRenderingMode(.hierarchical)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Typo.headline)
                Text(text)
                    .font(DS.Typo.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface()
    }
}

extension QuotaThresholdAlert {
    var key: String { "\(accountID)-\(windowName)" }
}

enum SidebarItem: Hashable {
    case route(AppRoute)
    case account(String)
}

/// Interactive placeholder card at the end of the account grid.
private struct AddAccountCard: View {
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)

        Button(action: action) {
            VStack(spacing: DS.Space.m) {
                ZStack {
                    Circle()
                        .fill(isHovered ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                        .frame(width: 42, height: 42)
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                }
                VStack(spacing: DS.Space.xxs) {
                    Text("添加账号")
                        .font(DS.Typo.headline)
                        .foregroundStyle(isHovered ? Color.accentColor : .primary)
                    Text("开启一个独立隔离的 Claude\u{00A0}Desktop 窗口")
                        .font(DS.Typo.secondary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(
                shape.fill(isHovered ? Color.accentColor.opacity(0.045) : DS.subtleFill.opacity(0.6))
            )
            .overlay(
                shape
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.25, dash: [6, 5]))
                    .foregroundStyle(isHovered ? Color.accentColor.opacity(0.55) : DS.hairlineStrong)
            )
            .offset(y: isHovered && !reduceMotion ? -1.5 : 0)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.quick) { isHovered = hovering }
        }
        .help("添加一个 Claude 账号（⌘N）")
    }
}

@MainActor
enum MainWindowLifecycle {
    static var didLaunch = false
}

/// Configures seamless NSWindow chrome and reports window lifecycle events.
struct WindowObserver: NSViewRepresentable {
    let onAppear: (NSWindow) -> Void
    let onBecomeKey: () -> Void
    let onClose: () -> Void

    init(
        _ onAppear: @escaping (NSWindow) -> Void,
        onBecomeKey: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.onAppear = onAppear
        self.onBecomeKey = onBecomeKey
        self.onClose = onClose
    }

    func makeNSView(context: Context) -> NSView {
        let view = HostingProbeView()
        let coordinator = context.coordinator
        view.onWindowChange = { [weak coordinator] window in
            coordinator?.handleWindowChange(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onAppear = onAppear
        coordinator.onBecomeKey = onBecomeKey
        coordinator.onClose = onClose
        if let window = nsView.window {
            coordinator.handleWindowChange(window)
            Self.applyUnifiedChrome(to: window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onAppear: onAppear, onBecomeKey: onBecomeKey, onClose: onClose)
    }

    @MainActor
    static func applyUnifiedChrome(to window: NSWindow) {
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titlebarSeparatorStyle != .automatic { window.titlebarSeparatorStyle = .automatic }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
        removeSplitTitlebarSeparators(in: window)
    }

    @MainActor
    static func removeSplitTitlebarSeparators(in window: NSWindow) {
        guard let splitVC = findSplitViewController(in: window.contentViewController) else { return }
        for (index, item) in splitVC.splitViewItems.enumerated() {
            let desired: NSTitlebarSeparatorStyle = (item.behavior == .sidebar || index == 0) ? .none : .automatic
            if item.titlebarSeparatorStyle != desired {
                item.titlebarSeparatorStyle = desired
            }
        }
    }

    @MainActor
    private static func findSplitViewController(in controller: NSViewController?) -> NSSplitViewController? {
        guard let controller else { return nil }
        if let split = controller as? NSSplitViewController { return split }
        for child in controller.children {
            if let found = findSplitViewController(in: child) { return found }
        }
        return nil
    }

    @MainActor
    final class HostingProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onAppear: (NSWindow) -> Void
        var onBecomeKey: () -> Void
        var onClose: () -> Void
        private weak var attachedWindow: NSWindow?
        nonisolated(unsafe) private var token: NSObjectProtocol?
        nonisolated(unsafe) private var keyToken: NSObjectProtocol?

        init(
            onAppear: @escaping (NSWindow) -> Void,
            onBecomeKey: @escaping () -> Void,
            onClose: @escaping () -> Void
        ) {
            self.onAppear = onAppear
            self.onBecomeKey = onBecomeKey
            self.onClose = onClose
        }

        func handleWindowChange(_ window: NSWindow?) {
            guard let window else {
                detach()
                return
            }
            if attachedWindow === window {
                return
            }
            attach(window)
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, self.attachedWindow === window else { return }
                WindowObserver.applyUnifiedChrome(to: window)
                self.onAppear(window)
            }
        }

        func attach(_ window: NSWindow) {
            detach()
            attachedWindow = window
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose() }
            }
            keyToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let window { WindowObserver.applyUnifiedChrome(to: window) }
                    self?.onBecomeKey()
                }
            }
        }

        private func detach() {
            attachedWindow = nil
            if let token {
                NotificationCenter.default.removeObserver(token)
                self.token = nil
            }
            if let keyToken {
                NotificationCenter.default.removeObserver(keyToken)
                self.keyToken = nil
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
            if let keyToken { NotificationCenter.default.removeObserver(keyToken) }
        }
    }
}

/// Status while a guided sign-in is running: what was closed, what to do, and a way out.
struct GuidedSignInBanner: View {
    @ObservedObject var vm: DockViewModel
    var compact: Bool = false

    init(vm: DockViewModel, compact: Bool = false) {
        self.vm = vm
        self.compact = compact
    }

    var body: some View {
        if let session = vm.guidedSignIn, let acc = vm.accounts.first(where: { $0.id == session.accountID }) {
            let paused = vm.accounts.filter { session.pausedAccountIDs.contains($0.id) }.map(\.name)
            let isActionDisabled = vm.isBusy || vm.operation(for: acc.id) != nil
            Group {
                if compact {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        bannerText(for: acc, paused: paused)
                        bannerActions(for: acc, hasPaused: !paused.isEmpty, disabled: isActionDisabled)
                    }
                } else {
                    HStack(alignment: .center, spacing: DS.Space.m) {
                        bannerText(for: acc, paused: paused)
                        Spacer(minLength: DS.Space.s)
                        bannerActions(for: acc, hasPaused: !paused.isEmpty, disabled: isActionDisabled)
                            .fixedSize()
                    }
                }
            }
            .padding(compact ? DS.Space.m : DS.Space.l)
            .surface(accent: acc.accentColor, tint: acc.accentColor)
        }
    }

    private func bannerText(for acc: AccountProfile, paused: [String]) -> some View {
        HStack(alignment: compact ? .top : .center, spacing: DS.Space.m) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, compact ? 2 : 0)
            VStack(alignment: .leading, spacing: 3) {
                Text("正在为 \(acc.name) 登录 Claude")
                    .font(DS.Typo.headline)
                Text(
                    paused.isEmpty
                        ? String(localized: "请在它的窗口里完成登录。收到登录邮件时用浏览器打开链接；登录成功后这里会自动结束。")
                        : String(localized: "已暂时关闭 \(paused.joined(separator: String(localized: "、")))。请在 \(acc.name) 的窗口里登录，邮件链接用浏览器打开；成功后会自动恢复它们。")
                )
                .font(DS.Typo.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bannerActions(for acc: AccountProfile, hasPaused: Bool, disabled: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            Button("打开登录窗口") { vm.openOrFocus(account: acc) }
                .buttonStyle(.dsSecondary(tint: acc.accentColor))
                .controlSize(compact ? .small : .regular)
                .disabled(disabled)
                .help("找不到 \(acc.name) 的窗口时点这里")
            Button(hasPaused ? String(localized: "结束并恢复") : String(localized: "结束")) { vm.finishGuidedSignIn() }
                .buttonStyle(.dsSecondary)
                .controlSize(compact ? .small : .regular)
                .disabled(disabled)
        }
    }
}
