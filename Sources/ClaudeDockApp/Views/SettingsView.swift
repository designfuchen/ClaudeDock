// FILE: Views/SettingsView.swift
import AppKit
import ClaudeDockCore
import SwiftUI

struct AccountsManagerTab: View {
    @ObservedObject var vm: DockViewModel

    private var resolvedID: String? { vm.resolvedAccountID }

    var body: some View {
        // The sidebar is the account list; this page is the selected account.
        if let id = resolvedID, let account = vm.accounts.first(where: { $0.id == id }) {
            AccountDetailEditor(account: account, vm: vm) { dirty, save in
                vm.setUnsavedEdits(dirty ? save : nil)
            }
            .id(account.id)
            .onAppear { if vm.selectedAccountID == nil { vm.selectedAccountID = account.id } }
        } else {
            VStack(spacing: DS.Space.m) {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("还没有账号")
                    .font(.system(size: 15, weight: .semibold))
                Button("添加账号") { vm.requestAddAccount() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ConfigSyncTab: View {
    @ObservedObject var vm: DockViewModel
    @State private var showAllSkills = false
    @State private var pendingRestart: [AccountProfile] = []

    /// Every MCP server name across accounts, sorted.
    private var allServers: [String] {
        Array(Set(vm.mcpInventory.values.flatMap { $0 })).sorted()
    }

    var body: some View {
        PageScroll {
            PageHeader(String(localized: "配置共享"), subtitle: String(localized: "MCP 服务器和 Skills 在所有账号间保持一致"))
            mcpSection
            skillsSection
            cliSection
        }
        .onAppear { vm.refreshMCPInventory() }
        .confirmationDialog(
            pendingRestart.count > 1 ? String(localized: "重启 \(pendingRestart.count) 个窗口？") : String(localized: "重启 \(pendingRestart.first?.name ?? "") 的窗口？"),
            isPresented: Binding(get: { !pendingRestart.isEmpty }, set: { if !$0 { pendingRestart = [] } })
        ) {
            Button("重启") {
                let targets = pendingRestart.compactMap { pending in
                    vm.accounts.first(where: { $0.id == pending.id })
                }
                for acc in targets { vm.restartAccount(acc) }
                pendingRestart = []
            }
            Button("取消", role: .cancel) { pendingRestart = [] }
        } message: {
            Text("会关闭并重新打开：\(pendingRestart.map(\.name).joined(separator: String(localized: "、")))。窗口里还没发送的内容可能会丢失。")
        }
    }

    // MARK: MCP

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionLabel(String(localized: "Claude Desktop 的 MCP 服务器"), detail: vm.lastMCPSyncAt.map { String(localized: "上次同步 \(RelativeTime.string(from: $0, now: vm.clock))") })
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: Binding(
                    get: { vm.settings.shareDesktopMCP },
                    set: { var s = vm.settings; s.shareDesktopMCP = $0; vm.saveSettings(s); if $0 { vm.syncDesktopMCP() } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动同步 MCP 服务器")
                            .font(DS.Typo.headline)
                        Text("在任一账号里新增、修改或删除服务器，其他账号会自动跟上。只同步 MCP 服务器，每个账号自己的设置不受影响；每次写入前都会备份。")
                            .font(DS.Typo.secondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .padding(DS.Space.l)

                Divider()
                matrix
                Divider()

                VStack(alignment: .leading, spacing: DS.Space.s) {
                    let names = vm.accounts.filter { vm.mcpRestartNeeded.contains($0.id) }
                    if !names.isEmpty {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                            Text("\(names.map(\.name).joined(separator: String(localized: "、"))) 需要重启窗口才能用上新的服务器")
                                .font(DS.Typo.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: DS.Space.s)
                            Button(names.count > 1 ? String(localized: "全部重启…") : String(localized: "重启…")) {
                                pendingRestart = names
                            }
                            .controlSize(.small)
                            .fixedSize()
                            .disabled(names.contains { vm.operation(for: $0.id) != nil })
                        }
                    }
                    ForEach(vm.lastSyncReport?.warnings ?? [], id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle")
                            .font(DS.Typo.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text(vm.settings.shareDesktopMCP
                             ? String(localized: "新账号第一次打开后会自动补齐服务器。每次写入前都会备份，保留最近 10 份。")
                             : String(localized: "自动同步已关闭。点“立即同步”可以手动合并一次，写入前同样会备份。"))
                            .font(DS.Typo.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("立即同步") { vm.syncDesktopMCP() }
                            .fixedSize()
                            .disabled(vm.accounts.count < 2)
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
            }
            .surface()
        }
    }

    /// Servers × accounts: a check where the account has the server, a dash where it's missing.
    @ViewBuilder
    private var matrix: some View {
        let servers = allServers
        let accs = vm.accounts
        if servers.isEmpty {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                Text(accs.isEmpty
                     ? String(localized: "账号打开过一次之后，这里会显示它的 MCP 服务器。")
                     : (vm.settings.shareDesktopMCP
                        ? String(localized: "还没有任何账号配置 MCP 服务器。在 Claude Desktop 的“设置 → 开发者”里添加一个，就会自动同步到其他账号。")
                        : String(localized: "还没有任何账号配置 MCP 服务器。在 Claude Desktop 的“设置 → 开发者”里添加后，可点“立即同步”合并到其他账号。")))
                    .font(DS.Typo.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(DS.Space.l)
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.s) {
                    GridRow {
                        Text("服务器").font(DS.Typo.caption).foregroundStyle(.secondary)
                        ForEach(accs) { acc in
                            VStack(spacing: 2) {
                                HStack(spacing: 6) {
                                    AccountAvatar(account: acc, state: vm.runningStates[acc.id] ?? .stopped, size: 20)
                                    Text(acc.name).font(DS.Typo.caption).lineLimit(1).frame(maxWidth: 110)
                                }
                                if vm.mcpInventory[acc.id] == nil {
                                    Text("未打开").font(.system(size: 10)).foregroundStyle(.secondary)
                                } else if vm.mcpRestartNeeded.contains(acc.id) {
                                    Text("重启后生效").font(.system(size: 10)).foregroundStyle(.orange)
                                }
                            }
                            .gridColumnAlignment(.center)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(servers, id: \.self) { server in
                        GridRow {
                            Text(server)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .textSelection(.enabled)
                            ForEach(accs) { acc in
                                let opened = vm.mcpInventory[acc.id] != nil
                                let has = vm.mcpInventory[acc.id]?.contains(server) == true
                                let pending = has && vm.mcpRestartNeeded.contains(acc.id)
                                Image(systemName: !opened ? "circle.dashed" : (has ? (pending ? "clock.arrow.circlepath" : "checkmark.circle.fill") : "minus.circle"))
                                    .foregroundStyle(!opened ? Color.secondary.opacity(0.4) : (has ? (pending ? Color.orange : Color.green) : Color.secondary.opacity(0.5)))
                                    .help(!opened
                                          ? (vm.settings.shareDesktopMCP ? String(localized: "这个账号还没打开过，打开后会自动补齐") : String(localized: "这个账号还没打开过，打开后可点“立即同步”合并"))
                                          : (pending ? String(localized: "已写入，重启这个账号后生效") : (has ? String(localized: "已有") : String(localized: "没有"))))
                                    .accessibilityLabel(!opened
                                                        ? String(localized: "\(acc.name)：未打开 \(server)")
                                                        : (pending
                                                           ? String(localized: "\(acc.name)：已写入，重启后生效 \(server)")
                                                           : (has
                                                              ? String(localized: "\(acc.name)：已有 \(server)")
                                                              : String(localized: "\(acc.name)：没有 \(server)"))))
                            }
                        }
                    }
                }
                .padding(DS.Space.l)
            }
        }
    }

    // MARK: Skills

    private var skillsSection: some View {
        let skills = vm.sharedSkills
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionLabel("Skills", detail: skills.isEmpty ? nil : String(localized: "\(skills.count) 个本地 Skills"))
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    let shared = vm.settings.shareClaudeCodeResources
                    Image(systemName: shared ? "checkmark.seal.fill" : "exclamationmark.circle")
                        .foregroundStyle(shared ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shared ? String(localized: "本地 Skills 在所有账号间共享") : String(localized: "本地 Skills 只给主账号使用"))
                            .font(DS.Typo.headline)
                        Text(shared
                             ? String(localized: "~/.claude/skills 里的 Skills 同时供 Claude Desktop 内置的 Claude Code 和每个账号的终端命令使用，放进去一次，所有账号都能用。")
                             : String(localized: "已关闭下面的“共享 Skills、Agents、命令和 CLAUDE.md”。打开它，其他账号的终端命令也能用这些 Skills。"))
                            .font(DS.Typo.secondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("在访达中显示") {
                        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    .controlSize(.small)
                }
                if skills.isEmpty {
                    Text(vm.settings.shareClaudeCodeResources
                         ? String(localized: "还没有本地 Skills。把一个包含 SKILL.md 的文件夹放进 ~/.claude/skills，所有账号就都能用。")
                         : String(localized: "还没有本地 Skills。把一个包含 SKILL.md 的文件夹放进 ~/.claude/skills 即可使用。"))
                        .font(DS.Typo.secondary)
                        .foregroundStyle(.secondary)
                } else {
                    let shown = showAllSkills ? skills : Array(skills.prefix(18))
                    FlowLayout(spacing: 6) {
                        ForEach(shown, id: \.self) { name in
                            Text(name)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 220)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                                .help(name)
                        }
                        if skills.count > 18 {
                            Button(showAllSkills ? String(localized: "收起") : String(localized: "还有 \(skills.count - shown.count) 个")) {
                                withAnimation(DS.Motion.standard) { showAllSkills.toggle() }
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                    }
                }
                Divider()
                HStack(alignment: .top, spacing: DS.Space.m) {
                    Image(systemName: "icloud").foregroundStyle(.secondary)
                    Text("在 claude.ai 账号里上传的 Skills 保存在 Anthropic 的服务器上，按账号分开，本地工具没法同步。需要时请在每个账号的“设置 → 功能”里分别上传。")
                        .font(DS.Typo.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Space.l)
            .surface()
        }
    }

    // MARK: Claude Code CLI

    private var cliSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionLabel(String(localized: "Claude Code 命令行"))
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Toggle(isOn: Binding(
                    get: { vm.settings.shareClaudeCodeResources },
                    set: { var s = vm.settings; s.shareClaudeCodeResources = $0; vm.saveSettings(s) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("共享 Skills、Agents、命令和 CLAUDE.md")
                            .font(DS.Typo.headline)
                        Text("所有账号的命令行都使用 ~/.claude 里的这些资源，登录信息仍然各自独立。")
                            .font(DS.Typo.secondary)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Divider()
                Toggle(isOn: Binding(
                    get: { vm.settings.shareClaudeCodeSessions },
                    set: { var s = vm.settings; s.shareClaudeCodeSessions = $0; vm.saveSettings(s); vm.refreshProjects() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("在账号之间共享会话")
                            .font(DS.Typo.headline)
                        Text("所有账号共用同一份对话记录、历史版本和计划，切换账号也能继续。关闭后各账号恢复独立记录，已有内容不会删除。")
                            .font(DS.Typo.secondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                let linked = vm.accounts.filter { $0.cliLinked || $0.isDefault }
                if !linked.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("可用命令").font(DS.Typo.caption).foregroundStyle(.secondary)
                        ForEach(linked) { acc in
                            HStack(spacing: DS.Space.s) {
                                AccountAvatar(account: acc, state: vm.runningStates[acc.id] ?? .stopped, size: 20)
                                // The default account without its own wrapper uses plain `claude`.
                                let command = acc.cliLinked ? "claude-\(acc.slug)" : "claude"
                                Text(acc.name)
                                    .font(DS.Typo.secondary)
                                    .frame(width: 110, alignment: .leading)
                                    .lineLimit(1)
                                    .help(acc.name)
                                Text(verbatim: command)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(command, forType: .string)
                                    vm.showToast(String(localized: "已复制 \(command)"), .success)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .help("复制命令")
                                .accessibilityLabel("复制 \(acc.name) 的命令 \(command)")
                            }
                        }
                    }
                }
            }
            .padding(DS.Space.l)
            .surface()
        }
    }
}

/// Wrapping row layout for tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Native ⌘, settings window.
struct SettingsWindowView: View {
    @ObservedObject var vm: DockViewModel

    var body: some View {
        TabView {
            GeneralSettingsTab(vm: vm)
                .tabItem { Label("通用", systemImage: "gearshape") }
            AboutSettingsTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 470)
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var vm: DockViewModel
    @State private var remainingThreshold: Double = 20
    @State private var lastSyncedThreshold: Double = 20
    @State private var thresholdSave: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Picker("推荐账号时", selection: Binding(
                    get: { vm.settings.schedulingMode },
                    set: { var s = vm.settings; s.schedulingMode = $0; vm.saveSettings(s) }
                )) {
                    Text("优先剩余额度最多的").tag(SchedulingMode.mostHeadroom)
                    Text("按列表顺序").tag(SchedulingMode.orderPriority)
                }
                LabeledContent("剩余额度低于") {
                    HStack {
                        // Saved once it settles (mouse, keyboard or VoiceOver alike), not on every tick of a drag.
                        Slider(value: $remainingThreshold, in: 2...50, step: 1)
                            .accessibilityLabel("剩余额度低于")
                            .accessibilityValue("\(Int(remainingThreshold))% 时提醒")
                            .onChange(of: remainingThreshold) { _, value in
                                thresholdSave?.cancel()
                                thresholdSave = nil
                                guard value != lastSyncedThreshold else { return }
                                let target = 100 - value
                                guard target != vm.settings.quotaAlertThreshold else { return }
                                thresholdSave = Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(400))
                                    guard !Task.isCancelled else { return }
                                    thresholdSave = nil
                                    lastSyncedThreshold = value
                                    guard 100 - value != vm.settings.quotaAlertThreshold else { return }
                                    var s = vm.settings
                                    s.quotaAlertThreshold = 100 - value
                                    vm.saveSettings(s)
                                }
                            }
                        Text("\(Int(remainingThreshold))% 时提醒")
                            .monospacedDigit()
                            .frame(width: 90, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }
            } header: {
                Text("额度")
            }

            Section {
                Picker("运行中每隔多久检测一次", selection: Binding(
                    get: { vm.settings.watchdogIntervalSeconds },
                    set: { var s = vm.settings; s.watchdogIntervalSeconds = $0; vm.saveSettings(s) }
                )) {
                    Text("10 秒").tag(10)
                    Text("15 秒（推荐）").tag(15)
                    Text("30 秒").tag(30)
                    Text("60 秒").tag(60)
                }
            } header: {
                Text("出口守护")
            } footer: {
                FooterText(String(localized: "间隔越短，发现节点切错越快。"))
            }

            Section {
                Toggle("全局快捷键 ⌘⌥1–9 切换账号", isOn: Binding(
                    get: { vm.settings.globalHotkeysEnabled },
                    set: { var s = vm.settings; s.globalHotkeysEnabled = $0; vm.saveSettings(s) }
                ))
                if vm.settings.globalHotkeysEnabled {
                    LabeledContent("状态", value: vm.hotkeySummary)
                }
                LabeledContent("快速切换") {
                    HStack(spacing: DS.Space.s) {
                        KeyCap(text: QuickSwitcher.shortcutLabel)
                        Text(QuickSwitcher.shared.isRegistered ? String(localized: "可用") : String(localized: "被其他应用占用"))
                            .foregroundStyle(QuickSwitcher.shared.isRegistered ? Color.secondary : Color.orange)
                    }
                }
                Toggle("关闭主窗口后只留在菜单栏", isOn: Binding(
                    get: { vm.settings.hideDockIconWhenClosed },
                    set: { var s = vm.settings; s.hideDockIconWhenClosed = $0; vm.saveSettings(s) }
                ))
                .help("关闭主窗口后隐藏程序坞图标，ClaudeDock 继续在菜单栏和后台工作")
                Toggle("启动时打开主窗口", isOn: Binding(
                    get: { vm.settings.openMainWindowAtLaunch },
                    set: { var s = vm.settings; s.openMainWindowAtLaunch = $0; vm.saveSettings(s) }
                ))
                .help("关闭后，ClaudeDock 启动时只出现在菜单栏")
                Toggle("登录 Mac 时自动打开 ClaudeDock", isOn: Binding(
                    get: { vm.settings.launchAtLogin },
                    set: { var s = vm.settings; s.launchAtLogin = $0; vm.saveSettings(s) }
                ))
            } header: {
                Text("系统")
            } footer: {
                FooterText(String(localized: "快捷键按侧边栏里账号的顺序对应，拖动即可调整。"))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let clamped = min(max((100 - vm.settings.quotaAlertThreshold).rounded(), 2), 50)
            lastSyncedThreshold = clamped
            remainingThreshold = clamped
            thresholdSave?.cancel()
            thresholdSave = nil
        }
        .onDisappear {
            guard let pending = thresholdSave else { return }
            pending.cancel()
            thresholdSave = nil
            lastSyncedThreshold = remainingThreshold
            let target = 100 - remainingThreshold
            if target != vm.settings.quotaAlertThreshold {
                var s = vm.settings
                s.quotaAlertThreshold = target
                vm.saveSettings(s)
            }
        }
    }
}

struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("ClaudeDock")
                .font(.system(size: 18, weight: .semibold))
            Text("版本 \(DockConstants.version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("原生 macOS 多账号工作台，适用于 Claude Desktop 与 Claude Code。\nMIT 许可证开源。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity)
    }
}

struct AccountDetailEditor: View {
    let sourceAccount: AccountProfile
    @State var draft: AccountProfile
    @ObservedObject var vm: DockViewModel
    /// Reports whether the form has unsaved edits, plus a closure that saves them.
    var onDirtyChange: (Bool, (() -> Bool)?) -> Void = { _, _ in }
    /// The configuration the form was last loaded from. Runtime observations are excluded.
    @State private var baseline: AccountProfile
    /// A newer configuration written elsewhere (e.g. by the CLI) while the user had unsaved edits.
    @State private var externalChange: AccountProfile?
    @State private var portText: String
    @State private var regionsText: String
    @State private var countriesText: String
    @State private var pinnedIPText: String
    @State private var tzText: String
    @State private var citiesText: String
    @State private var tzRulesText: String
    @State private var nodeText: String
    @State private var groupText: String
    @State private var showDeleteConfirm = false
    private var isRunning: Bool { vm.runningStates[sourceAccount.id]?.isActive == true }

    /// Proxy-timezone field that keeps the timezone rule in step while the rule merely mirrors it,
    /// without resurrecting a cleared egress rule or erasing an egress rule when launch timezone is cleared.
    private var tzBinding: Binding<String> {
        Binding(get: { tzText }, set: { new in
            let old = tzText.trimmingCharacters(in: .whitespaces)
            let newTrimmed = new.trimmingCharacters(in: .whitespaces)
            let rule = tzRulesText.trimmingCharacters(in: .whitespaces)
            if !old.isEmpty && !newTrimmed.isEmpty && rule == old {
                tzRulesText = new
            }
            tzText = new
        })
    }

    /// Re-enabling a proxy defaults Egress Guard back to `.failClosed` (matching AddAccountSheet)
    /// while still letting the user explicitly pick `.disabled` in the revealed picker.
    private var proxyEnabledBinding: Binding<Bool> {
        Binding(
            get: { draft.proxy.enabled },
            set: { enabled in
                draft.proxy.enabled = enabled
                if enabled && draft.egressPolicy.mode == .disabled {
                    draft.egressPolicy.mode = .failClosed
                }
            }
        )
    }

    init(account: AccountProfile, vm: DockViewModel, onDirtyChange: @escaping (Bool, (() -> Bool)?) -> Void = { _, _ in }) {
        self.sourceAccount = account
        _draft = State(initialValue: account)
        _baseline = State(initialValue: account.configurationOnly)
        self.vm = vm
        self.onDirtyChange = onDirtyChange
        _portText = State(initialValue: "\(account.proxy.port)")
        _regionsText = State(initialValue: account.egressPolicy.allowedRegions.joined(separator: ", "))
        _countriesText = State(initialValue: account.egressPolicy.allowedCountries.joined(separator: ", "))
        _pinnedIPText = State(initialValue: account.egressPolicy.pinnedIP ?? "")
        _tzText = State(initialValue: account.proxy.timezone ?? "")
        _citiesText = State(initialValue: account.egressPolicy.allowedCities.joined(separator: ", "))
        _tzRulesText = State(initialValue: account.egressPolicy.allowedTimezones.joined(separator: ", "))
        _nodeText = State(initialValue: account.proxy.clashNodeName ?? "")
        _groupText = State(initialValue: account.handoffGroup ?? "")
    }

    private var liveAccount: AccountProfile {
        vm.accounts.first { $0.id == sourceAccount.id } ?? sourceAccount
    }

    private var previewSlug: String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return AccountProfile(name: trimmed.isEmpty ? sourceAccount.name : trimmed).slug
    }

    /// Live status of the account being edited: identity, quota, exit and the main action.
    private var overview: some View {
        let acc = liveAccount
        let state = vm.runningStates[acc.id] ?? .stopped
        let op = vm.operation(for: acc.id)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                AccountAvatar(account: acc, state: state, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(acc.name)
                        .font(.system(size: 17, weight: .semibold))
                    Text(acc.identity?.email.map { [acc.identity?.displayName, $0].compactMap { $0 }.joined(separator: " · ") }
                         ?? (acc.identity?.loggedIn == true ? String(localized: "已登录") : (acc.identity?.accountUUID != nil ? String(localized: "已登录 Claude Desktop") : String(localized: "打开后登录"))))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if let op {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(op.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    Button(state.isFrozen ? String(localized: "重新检测并恢复") : (state.isActive ? String(localized: "切换") : String(localized: "打开"))) {
                        let target: AccountProfile
                        if !state.isActive || state.isFrozen {
                            if isDirty {
                                guard let saved = saveChanges() else { return }
                                target = saved
                            } else {
                                target = acc
                            }
                        } else {
                            target = acc
                        }
                        if state.isFrozen { vm.resume(account: target) } else { vm.openOrFocus(account: target) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.isFrozen ? .orange : acc.accentColor)
                }
            }
            QuotaPanel(quota: acc.quota, now: vm.clock, isRefreshing: vm.isRefreshingQuota(acc.id),
                       onRefresh: { vm.refreshQuota(for: acc) },
                       onSignIn: { vm.signInClaudeCode(for: acc) })
            if acc.egressPolicy.mode != .disabled {
                EgressHealthChip(health: vm.egressHealth(for: acc), now: vm.clock)
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    private var isDirty: Bool {
        buildEdited().configurationOnly != baseline || portProblem != nil
    }

    private var portProblem: String? {
        guard draft.proxy.enabled else { return nil }
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else {
            return String(localized: "端口需在 1–65535 之间")
        }
        return nil
    }

    private var nameProblem: String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.contains("--") {
            return String(localized: "名称不能包含连续的“--”")
        }
        if (try? Validation.validateAccountName(name)) == nil {
            return String(localized: "名称仅支持文字、数字、空格、“-”和“_”，最多 30 个字符")
        }
        if vm.accounts.contains(where: { $0.id != draft.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return String(localized: "已存在同名账号")
        }
        let slug = AccountProfile(name: name).slug
        if let clash = vm.accounts.first(where: { $0.id != draft.id && $0.slug == slug }) {
            return String(localized: "和“\(clash.name)”的终端命令重名（claude-\(slug)），请换个名称")
        }
        return nil
    }

    private var hostProblem: String? {
        guard draft.proxy.enabled else { return nil }
        return draft.proxy.host.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "请填写代理主机，通常是 127.0.0.1") : nil
    }

    private var countryCodeProblem: String? {
        guard draft.proxy.enabled && draft.egressPolicy.mode != .disabled else { return nil }
        return EgressInput.countryCodeProblem(countriesText)
    }

    private var hasRunningProxyMutation: Bool {
        guard isRunning else { return false }
        let edited = buildEdited().proxy
        let active = liveAccount.proxy
        return edited.enabled != active.enabled
            || edited.scheme != active.scheme
            || edited.host != active.host
            || edited.port != active.port
            || edited.timezone != active.timezone
    }

    private var runningProxyProblem: String? {
        guard hasRunningProxyMutation else { return nil }
        return String(localized: "\(liveAccount.name) 正在运行，请先退出窗口或还原代理修改")
    }

    private var validationProblem: String? {
        nameProblem ?? portProblem ?? hostProblem ?? countryCodeProblem ?? runningProxyProblem
    }

    private var guardFooter: String {
        switch draft.egressPolicy.mode {
        case .disabled: return String(localized: "打开时不检查出口，直接启动。")
        case .warnOnly: return String(localized: "打开账号前会先检测代理的真实出口，不符合规则时提醒你，但仍会打开。“用当前出口填写规则”会先保存当前修改，再按现在检测到的国家/地区、州/省和时区写入规则。")
        case .failClosed: return String(localized: "打开账号前会先检测代理的真实出口，符合规则才放行。“用当前出口填写规则”会先保存当前修改，再按现在检测到的国家/地区、州/省和时区写入规则。")
        }
    }

    private func syncFromBacking(_ updated: AccountProfile) {
        baseline = updated.configurationOnly
        externalChange = nil
        draft = updated
        portText = "\(updated.proxy.port)"
        regionsText = updated.egressPolicy.allowedRegions.joined(separator: ", ")
        countriesText = updated.egressPolicy.allowedCountries.joined(separator: ", ")
        pinnedIPText = updated.egressPolicy.pinnedIP ?? ""
        tzText = updated.proxy.timezone ?? ""
        citiesText = updated.egressPolicy.allowedCities.joined(separator: ", ")
        tzRulesText = updated.egressPolicy.allowedTimezones.joined(separator: ", ")
        nodeText = updated.proxy.clashNodeName ?? ""
        groupText = updated.handoffGroup ?? ""
    }

    private func conflictingFieldLabels(with external: AccountProfile) -> [String] {
        let edited = buildEdited()
        let ext = external.configurationOnly
        var names: [String] = []
        if edited.name != baseline.name && ext.name != baseline.name && edited.name != ext.name { names.append(String(localized: "名称")) }
        if edited.colorHex != baseline.colorHex && ext.colorHex != baseline.colorHex && edited.colorHex != ext.colorHex { names.append(String(localized: "颜色")) }
        if edited.iconStyle != baseline.iconStyle && ext.iconStyle != baseline.iconStyle && edited.iconStyle != ext.iconStyle { names.append(String(localized: "启动器图标")) }
        if edited.handoffGroup != baseline.handoffGroup && ext.handoffGroup != baseline.handoffGroup && edited.handoffGroup != ext.handoffGroup { names.append(String(localized: "分组")) }
        if edited.cliLinked != baseline.cliLinked && ext.cliLinked != baseline.cliLinked && edited.cliLinked != ext.cliLinked { names.append(String(localized: "终端命令")) }
        if edited.proxy != baseline.proxy && ext.proxy != baseline.proxy && edited.proxy != ext.proxy { names.append(String(localized: "网络设置")) }
        if edited.egressPolicy != baseline.egressPolicy && ext.egressPolicy != baseline.egressPolicy && edited.egressPolicy != ext.egressPolicy { names.append(String(localized: "出口守护")) }
        return names
    }

    /// Merges the fields edited by the user on top of the latest external configuration,
    /// carrying over unrelated external changes instead of overwriting them.
    private func keepMyEdits(over external: AccountProfile) {
        let edited = buildEdited()
        let preservedPortText = portProblem != nil ? portText : nil
        var merged = external
        if edited.name != baseline.name { merged.name = edited.name }
        if edited.colorHex != baseline.colorHex { merged.colorHex = edited.colorHex }
        if edited.iconStyle != baseline.iconStyle { merged.iconStyle = edited.iconStyle }
        if edited.handoffGroup != baseline.handoffGroup { merged.handoffGroup = edited.handoffGroup }
        if edited.cliLinked != baseline.cliLinked { merged.cliLinked = edited.cliLinked }
        if edited.proxy.enabled != baseline.proxy.enabled { merged.proxy.enabled = edited.proxy.enabled }
        if edited.proxy.scheme != baseline.proxy.scheme { merged.proxy.scheme = edited.proxy.scheme }
        if edited.proxy.host != baseline.proxy.host { merged.proxy.host = edited.proxy.host }
        if edited.proxy.port != baseline.proxy.port { merged.proxy.port = edited.proxy.port }
        if edited.proxy.timezone != baseline.proxy.timezone { merged.proxy.timezone = edited.proxy.timezone }
        if edited.proxy.clashNodeName != baseline.proxy.clashNodeName { merged.proxy.clashNodeName = edited.proxy.clashNodeName }
        if edited.egressPolicy.mode != baseline.egressPolicy.mode { merged.egressPolicy.mode = edited.egressPolicy.mode }
        if edited.egressPolicy.allowedCountries != baseline.egressPolicy.allowedCountries { merged.egressPolicy.allowedCountries = edited.egressPolicy.allowedCountries }
        if edited.egressPolicy.allowedRegions != baseline.egressPolicy.allowedRegions { merged.egressPolicy.allowedRegions = edited.egressPolicy.allowedRegions }
        if edited.egressPolicy.allowedCities != baseline.egressPolicy.allowedCities { merged.egressPolicy.allowedCities = edited.egressPolicy.allowedCities }
        if edited.egressPolicy.allowedTimezones != baseline.egressPolicy.allowedTimezones { merged.egressPolicy.allowedTimezones = edited.egressPolicy.allowedTimezones }
        if edited.egressPolicy.pinnedIP != baseline.egressPolicy.pinnedIP { merged.egressPolicy.pinnedIP = edited.egressPolicy.pinnedIP }
        if edited.egressPolicy.watchdogEnabled != baseline.egressPolicy.watchdogEnabled { merged.egressPolicy.watchdogEnabled = edited.egressPolicy.watchdogEnabled }
        if edited.egressPolicy.watchdogAction != baseline.egressPolicy.watchdogAction { merged.egressPolicy.watchdogAction = edited.egressPolicy.watchdogAction }

        baseline = external.configurationOnly
        externalChange = nil
        draft = merged
        portText = preservedPortText ?? "\(merged.proxy.port)"
        regionsText = merged.egressPolicy.allowedRegions.joined(separator: ", ")
        countriesText = merged.egressPolicy.allowedCountries.joined(separator: ", ")
        pinnedIPText = merged.egressPolicy.pinnedIP ?? ""
        tzText = merged.proxy.timezone ?? ""
        citiesText = merged.egressPolicy.allowedCities.joined(separator: ", ")
        tzRulesText = merged.egressPolicy.allowedTimezones.joined(separator: ", ")
        nodeText = merged.proxy.clashNodeName ?? ""
        groupText = merged.handoffGroup ?? ""
    }

    var body: some View {
        Form {
            if let external = externalChange {
                let conflicts = conflictingFieldLabels(with: external)
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("这个账号已在别处被修改")
                                .font(.system(size: 13, weight: .semibold))
                            Text(conflicts.isEmpty
                                 ? String(localized: "可能来自命令行或另一个窗口。点“保留我的修改”会合并外部改动并保留你编辑的字段。")
                                 : String(localized: "双方都修改了：\(conflicts.joined(separator: String(localized: "、")))。请选择“加载最新”或“保留我的修改”。"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("加载最新") { syncFromBacking(external) }
                        Button("保留我的修改") { keepMyEdits(over: external) }
                    }
                }
            }

            Section {
                overview
            }

            Section {
                TextField("名称", text: $draft.name)
                if let nameProblem {
                    Text(nameProblem).font(.system(size: 12)).foregroundStyle(.red)
                }
                LabeledContent("颜色") {
                    HStack(spacing: 7) {
                        ForEach(AccountProfile.palette, id: \.self) { hex in
                            let selected = draft.colorHex == hex
                            Button {
                                draft.colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(nsColor: IconRenderer.nsColor(fromHex: hex) ?? .systemBlue))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2 : 0))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.5 : 0), lineWidth: 1).padding(-2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(PaletteName.name(hex))
                            .help(PaletteName.name(hex))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
                Picker("启动器图标", selection: $draft.iconStyle) {
                    Text("Claude 图标 + 彩色角标").tag(IconStyle.claudeBadge)
                    Text("彩色字母").tag(IconStyle.letter)
                }
                TextField("分组", text: $groupText, prompt: Text("default"))
                Toggle("启用终端命令 claude-\(previewSlug)", isOn: $draft.cliLinked)
                LabeledContent("数据目录") {
                    Text("~/Library/Application Support/\(draft.dataDirName)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("基本信息")
            } footer: {
                FooterText(String(localized: "同一分组的账号之间才会互相推荐。数据目录保存这个账号的登录状态，改名不会影响它。"))
            }

            Section {
                if isRunning {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        Text("\(liveAccount.name) 正在运行。代理设置要等下次打开才生效，请先退出再修改。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DS.Space.s)
                        Button("退出窗口") { vm.quit(account: liveAccount) }
                            .controlSize(.small)
                            .disabled(vm.operation(for: sourceAccount.id) != nil)
                    }
                }
                Toggle("使用独立代理", isOn: proxyEnabledBinding)
                    .disabled(isRunning)
                if draft.proxy.enabled {
                    Picker("协议", selection: $draft.proxy.scheme) {
                        Text("HTTP").tag(ProxyScheme.http)
                        Text("SOCKS5").tag(ProxyScheme.socks5)
                    }
                    .disabled(isRunning)
                    TextField("主机", text: $draft.proxy.host, prompt: Text("127.0.0.1"))
                        .disabled(isRunning)
                    if let hostProblem {
                        Text(hostProblem).font(.system(size: 12)).foregroundStyle(.red)
                    }
                    TextField("端口", text: $portText, prompt: Text("7897"))
                        .disabled(isRunning)
                    if let portProblem {
                        Text(portProblem).font(.system(size: 12)).foregroundStyle(.red)
                    }
                    TextField("Clash 节点名", text: $nodeText, prompt: Text("选填，用于生成多端口配置"))
                    TextField("窗口时区", text: tzBinding, prompt: Text("IANA 时区，如 Asia/Tokyo"))
                        .disabled(isRunning)
                }
            } header: {
                Text("网络")
            } footer: {
                FooterText(draft.proxy.enabled ? String(localized: "代理在打开窗口时生效，修改后需重新打开这个账号。") : String(localized: "不使用独立代理时，这个账号走系统网络，也不做出口检查。"))
            }

            if draft.proxy.enabled {
            Section {
                Picker("出口检查", selection: $draft.egressPolicy.mode) {
                    Text("不检查").tag(EgressGuardMode.disabled)
                    Text("不符合时提醒").tag(EgressGuardMode.warnOnly)
                    Text("不符合时阻止（推荐）").tag(EgressGuardMode.failClosed)
                }

                if draft.egressPolicy.mode != .disabled {
                    TextField("国家/地区代码", text: $countriesText, prompt: Text("两位代码，多个用逗号分隔，如 SG, JP"))
                    if let countryCodeProblem {
                        Text(countryCodeProblem).font(.system(size: 12)).foregroundStyle(.red)
                    }
                    TextField("州/省", text: $regionsText, prompt: Text("选填，出口所在的州或省（英文）"))
                    TextField("城市", text: $citiesText, prompt: Text("选填"))
                    TextField("允许的时区", text: $tzRulesText, prompt: Text("选填，IANA 时区，多个用逗号分隔"))
                    TextField("固定 IP", text: $pinnedIPText, prompt: Text("选填，填写后仅允许这个 IP"))
                    Toggle("运行中持续检测", isOn: $draft.egressPolicy.watchdogEnabled)
                    Picker("运行中出口不符合规则时", selection: $draft.egressPolicy.watchdogAction) {
                        Text("暂停这个账号（推荐）").tag(WatchdogAction.freeze)
                        Text("仅发送提醒").tag(WatchdogAction.notify)
                        Text("退出").tag(WatchdogAction.quit)
                    }
                    .disabled(!draft.egressPolicy.watchdogEnabled)

                    HStack {
                        Button("用当前出口填写规则") {
                            guard let target = isDirty ? saveChanges() : liveAccount else { return }
                            vm.pinCurrentEgress(for: target, exactIP: false)
                        }
                        Button("仅允许当前 IP") {
                            guard let target = isDirty ? saveChanges() : liveAccount else { return }
                            vm.pinCurrentEgress(for: target, exactIP: true)
                        }
                        Spacer()
                    }
                    .disabled(vm.operation(for: draft.id) != nil || externalChange != nil)
                }
            } header: {
                Text("出口守护")
            } footer: {
                FooterText(guardFooter)
            }
            }

            Section {
                HStack {
                    Button("移除账号…", role: .destructive) { showDeleteConfirm = true }
                        .disabled(vm.operation(for: sourceAccount.id) != nil)
                    Spacer()
                    if let validationProblem {
                        Text(validationProblem)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else if externalChange != nil {
                        Text("请先处理上方的外部修改冲突")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else if isDirty {
                        Text("有还没保存的修改")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if isDirty {
                        Button("还原") { syncFromBacking(liveAccount) }
                    }
                    Button("保存") { _ = saveChanges() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty || validationProblem != nil || externalChange != nil)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: sourceAccount) { _, newValue in
            // Background refreshes (quota, identity, egress) never touch the form.
            guard newValue.configurationOnly != baseline else {
                // The other edit was undone: nothing is in conflict any more.
                externalChange = nil
                return
            }
            if isDirty {
                externalChange = newValue
            } else {
                syncFromBacking(newValue)
            }
        }
        .onChange(of: isDirty, initial: true) { _, dirty in
            onDirtyChange(dirty, dirty ? { saveChanges() != nil } : nil)
        }
        .onDisappear { onDirtyChange(false, nil) }
        .confirmationDialog("移除账号“\(liveAccount.name)”？", isPresented: $showDeleteConfirm) {
            if isRunning {
                Button("退出窗口") { vm.quit(account: liveAccount) }
            } else {
                Button("移除，保留本地登录状态和数据") {
                    vm.removeAccount(liveAccount, deleteData: false)
                }
                if !liveAccount.isDefault {
                    Button("移除，并删除这个账号的全部本地数据", role: .destructive) {
                        vm.removeAccount(liveAccount, deleteData: true)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(isRunning
                 ? String(localized: "\(liveAccount.name) 正在运行，请先退出它的窗口。")
                 : (liveAccount.isDefault
                    ? String(localized: "只移除 ClaudeDock 里的这一项，Claude 原本的登录和数据不受影响。")
                    : String(localized: "保留数据时，登录状态和本地记录会留在这台 Mac 上。删除数据会清掉这个账号的登录和本地记录，无法恢复。")))
        }
    }

    /// The profile the form currently describes. Empty text fields map back to nil so an untouched form is not "dirty".
    private func buildEdited() -> AccountProfile {
        var copy = draft
        copy.proxy.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? draft.proxy.port
        let tz = tzText.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.proxy.timezone = tz.isEmpty ? nil : tz
        let node = nodeText.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.proxy.clashNodeName = node.isEmpty ? nil : node
        let group = groupText.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.handoffGroup = group.isEmpty ? nil : group
        copy.egressPolicy.allowedCountries = EgressInput.splitCSV(countriesText).map { $0.uppercased() }
        copy.egressPolicy.allowedRegions = EgressInput.splitCSV(regionsText)
        let ipTrimmed = pinnedIPText.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.egressPolicy.pinnedIP = ipTrimmed.isEmpty ? nil : ipTrimmed
        // Every rule that can block a launch is a visible, editable field — nothing hidden.
        copy.egressPolicy.allowedCities = EgressInput.splitCSV(citiesText)
        copy.egressPolicy.allowedTimezones = EgressInput.splitCSV(tzRulesText)
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Without a proxy there is nothing to check: the guard goes off with it (same as when adding an account).
        copy.proxy.host = copy.proxy.host.trimmingCharacters(in: .whitespaces)
        if !copy.proxy.enabled { copy.egressPolicy.mode = .disabled }
        return copy
    }

    /// Saves and reloads the form from what was actually stored. Returns the saved profile, or nil (keeping the draft) on failure.
    @discardableResult
    private func saveChanges() -> AccountProfile? {
        if externalChange != nil {
            vm.showToast(String(localized: "这个账号已在别处被修改，请先选择“加载最新”或“保留我的修改”"), .warning)
            return nil
        }
        if let validationProblem {
            vm.showToast(String(localized: "无法保存：\(validationProblem)"), .error)
            return nil
        }
        guard let saved = vm.saveAccount(buildEdited()) else { return nil }
        syncFromBacking(saved)
        return saved
    }
}
