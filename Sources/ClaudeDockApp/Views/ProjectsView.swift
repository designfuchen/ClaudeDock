// FILE: Views/ProjectsView.swift
import AppKit
import ClaudeDockCore
import SwiftUI

/// Projects are folders on this Mac; accounts are interchangeable. Every Claude Code conversation from every
/// account shows up here, and any of them can be continued with any account.
struct ProjectsPage: View {
    @ObservedObject var vm: DockViewModel
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var collapsedDuringSearch: Set<String> = []

    private var filtered: [ClaudeProject] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return vm.projects }
        return vm.projects.filter { p in
            p.name.lowercased().contains(q) || p.path.lowercased().contains(q)
                || p.sessions.contains { $0.title.lowercased().contains(q) }
        }
    }

    var body: some View {
        // Filter and auto-expand are computed once per render, not once per row.
        let list = filtered
        let auto = autoExpanded(in: list)
        PageScroll {
            PageHeader(String(localized: "项目"), subtitle: subtitle) {
                HStack(spacing: DS.Space.s) {
                    SearchField(text: $query, prompt: String(localized: "搜索项目或会话"))
                        .frame(width: 220)
                    Button {
                        vm.refreshProjects()
                    } label: {
                        if vm.isScanningProjects {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("重新扫描")
                    .accessibilityLabel("重新扫描项目")
                }
            }

            if !vm.settings.shareClaudeCodeSessions {
                sharingOffBanner
            }

            if vm.codeAccounts.isEmpty && !vm.projects.isEmpty {
                noCodeAccountsBanner
            }

            if !vm.liveSessions.isEmpty {
                liveStrip
            }

            if vm.projects.isEmpty && vm.isScanningProjects {
                HStack(spacing: DS.Space.m) {
                    ProgressView().controlSize(.small)
                    Text("正在读取 Claude Code 会话…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(DS.Space.xl)
                .surface()
            } else if vm.projects.isEmpty && vm.codeAccounts.isEmpty {
                emptyCard(
                    symbol: "terminal",
                    title: String(localized: "还没有可以运行 Claude Code 的账号"),
                    text: String(localized: "在账号设置里打开“启用终端命令”，就能在这里用它继续任何项目。")
                ) {
                    Button("前往账号设置") {
                        vm.navigate(to: .accounts)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if vm.projects.isEmpty && !vm.isScanningProjects {
                emptyCard(
                    symbol: "folder",
                    title: String(localized: "还没有 Claude Code 项目"),
                    text: String(localized: "在任意文件夹里用 claude 或 claude-<账号名> 开始一次对话，它就会出现在这里。")
                )
            } else if list.isEmpty && !query.isEmpty {
                emptyCard(
                    symbol: "magnifyingglass",
                    title: String(localized: "没有找到“\(query)”"),
                    text: String(localized: "试试项目名、路径或会话标题里的词。")
                )
            } else {
                LazyVStack(spacing: DS.Space.s) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { idx, project in
                        ProjectRow(
                            vm: vm,
                            project: project,
                            isExpanded: expanded.contains(project.id)
                                || (auto.contains(project.id) && !collapsedDuringSearch.contains(project.id)),
                            query: query,
                            onToggle: {
                                withAnimation(DS.Motion.standard) {
                                    // Toggle what the user sees, whether it's open by hand or by a search match.
                                    let open = expanded.contains(project.id)
                                        || (auto.contains(project.id) && !collapsedDuringSearch.contains(project.id))
                                    if open {
                                        expanded.remove(project.id)
                                        if auto.contains(project.id) { collapsedDuringSearch.insert(project.id) }
                                    } else {
                                        expanded.insert(project.id)
                                        collapsedDuringSearch.remove(project.id)
                                    }
                                }
                            }
                        )
                        .appearAnimation(index: idx)
                    }
                }
            }

            DesktopHandoffSection(vm: vm)
        }
        .onAppear { vm.refreshProjects() }
        .onChange(of: query) { _, _ in collapsedDuringSearch = [] }
    }

    /// While searching, projects that match through a session title (rather than project name) open by themselves.
    private func autoExpanded(in list: [ClaudeProject]) -> Set<String> {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return Set(list.filter { p in
            !p.name.lowercased().contains(q) && p.sessions.contains { $0.title.lowercased().contains(q) }
        }.map(\.id))
    }

    private var subtitle: String {
        let n = vm.projects.count
        let shared = vm.settings.shareClaudeCodeSessions ? String(localized: "所有账号共用同一份会话，切换账号也能继续") : String(localized: "各账号的会话分开保存")
        return n == 0 ? shared : String(localized: "\(n) 个项目 · \(shared)")
    }

    private var sharingOffBanner: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("打开会话共享，换账号也能接着聊")
                    .font(.system(size: 13, weight: .semibold))
                Text("所有账号使用同一份 Claude Code 对话记录，登录信息仍然各自独立。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开共享") {
                var s = vm.settings
                s.shareClaudeCodeSessions = true
                vm.saveSettings(s)
                vm.refreshProjects()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(DS.Space.l)
        .surface(accent: .accentColor, tint: .accentColor)
    }

    private var noCodeAccountsBanner: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "terminal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("还没有可以运行 Claude Code 的账号")
                    .font(.system(size: 13, weight: .semibold))
                Text("在账号设置里打开“启用终端命令”，就可以在终端里直接继续这些项目。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("前往账号设置") {
                vm.navigate(to: .accounts)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(DS.Space.l)
        .surface()
    }

    private var liveStrip: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionLabel(String(localized: "正在运行"), detail: String(localized: "\(vm.liveSessions.count) 个 Claude Code 会话"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
                    ForEach(liveGroups, id: \.key) { group in
                        let s = group.sessions[0]
                        let acc = vm.accounts.first { $0.name == s.accountName }
                        let state = acc.flatMap { vm.runningStates[$0.id] } ?? .running(pids: [s.pid])
                        let chipTint: Color = state.isFrozen ? .orange : .green
                        HStack(spacing: 6) {
                            if let acc { AccountAvatar(account: acc, state: state, size: 18) }
                            Text(liveSessionLabel(s))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            if group.sessions.count > 1 {
                                Text("×\(group.sessions.count)")
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                            }
                            Text(state.isFrozen ? String(localized: "\(s.accountName) · 已暂停") : s.accountName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(chipTint.opacity(0.1), in: Capsule())
                        .hairlineBorder(Capsule(), chipTint.opacity(0.35))
                        .help(liveSessionHelp(s))
                    }
                }
            }
        }
    }

    private func liveSessionLabel(_ s: LiveClaudeSession) -> String {
        if let cwd = s.cwd, !cwd.isEmpty {
            let last = (cwd as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        return s.name.isEmpty ? String(localized: "会话") : s.name
    }

    private func liveSessionHelp(_ s: LiveClaudeSession) -> String {
        guard let cwd = s.cwd, !cwd.isEmpty else { return "" }
        return (cwd as NSString).abbreviatingWithTildeInPath
    }

    /// Live sessions grouped by folder and account, so two sessions in one project show as one chip "×2".
    private var liveGroups: [(key: String, sessions: [LiveClaudeSession])] {
        let grouped = Dictionary(grouping: vm.liveSessions) { "\($0.cwd ?? $0.name)|\($0.accountName)" }
        return grouped.map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
    }

    private func emptyCard(symbol: String, title: String, text: String) -> some View {
        emptyCard(symbol: symbol, title: title, text: text) { EmptyView() }
    }

    private func emptyCard<Action: View>(
        symbol: String,
        title: String,
        text: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
        .padding(DS.Space.xl)
        .surface()
    }
}

// MARK: - Project row

private struct ProjectRow: View {
    @ObservedObject var vm: DockViewModel
    let project: ClaudeProject
    let isExpanded: Bool
    var query: String = ""
    let onToggle: () -> Void

    @State private var isHovered = false
    @State private var showAll = false

    /// When searching and the project name itself didn't match, show matching sessions when any exist.
    private var visibleSessions: [ClaudeSessionSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, !project.name.lowercased().contains(q) else {
            return project.sessions
        }
        let matching = project.sessions.filter { $0.title.lowercased().contains(q) }
        return matching.isEmpty ? project.sessions : matching
    }

    var body: some View {
        let suggested = vm.suggestedAccount(for: project)
        let sessions = visibleSessions
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Button(action: onToggle) {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: project.exists ? "folder.fill" : "folder.badge.questionmark")
                            .font(.system(size: 18))
                            .foregroundStyle(project.exists ? Color.accentColor.opacity(0.85) : .secondary)
                            .frame(width: 22) // fixed icon column: titles never shift between glyphs
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(project.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                if let parent = project.worktreeParent {
                                    Tag(text: String(localized: "工作树 · \((parent as NSString).lastPathComponent)"), color: .secondary)
                                }
                            }
                            Text((project.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: DS.Space.m)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(RelativeTime.string(from: project.lastActivity, now: vm.clock))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                            Text("\(project.sessions.count) 个会话")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        if let lastID = project.lastAccountID, let acc = vm.accounts.first(where: { $0.id == lastID }) {
                            AccountAvatar(account: acc, state: vm.runningStates[acc.id] ?? .stopped, size: 20)
                                .help("上次用 \(acc.name)")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(project.name)，\(project.sessions.count) 个会话")
                .accessibilityHint(isExpanded ? String(localized: "收起会话列表") : String(localized: "展开会话列表"))

                ContinueButton(
                    vm: vm,
                    title: String(localized: "继续"),
                    suggested: suggested,
                    lastAccountID: project.lastAccountID ?? project.sessions.first?.lastAccountID,
                    disabled: !project.exists,
                    terminalAction: { acc in
                        if !vm.settings.shareClaudeCodeSessions, let latestID = project.sessions.first?.id {
                            vm.launchClaudeCode(account: acc, in: project.path, resume: latestID)
                        } else {
                            vm.launchClaudeCode(account: acc, in: project.path, continueLatest: true)
                        }
                    }
                ) { acc in
                    vm.openOrFocus(account: acc)
                } more: {
                    if !vm.codeAccounts.isEmpty {
                        Menu("新会话") {
                            ForEach(vm.codeAccounts) { acc in
                                Button(acc.name) { vm.launchClaudeCode(account: acc, in: project.path) }
                                    .disabled(!project.exists || vm.runningStates[acc.id]?.isFrozen == true)
                            }
                        }
                        .disabled(!project.exists)
                        Divider()
                    }
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                    }
                    .disabled(!project.exists)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)

            if isExpanded, !sessions.isEmpty {
                Divider().padding(.leading, 72)
                let shown = showAll ? sessions : Array(sessions.prefix(12))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, session in
                        if idx > 0 { Divider().padding(.leading, 72) }
                        SessionRow(vm: vm, project: project, session: session)
                    }
                    if sessions.count > shown.count {
                        Button("显示全部 \(sessions.count) 个会话") {
                            withAnimation(DS.Motion.standard) { showAll = true }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .padding(.vertical, DS.Space.s)
                    }
                }
                .padding(.bottom, DS.Space.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .surface(hovered: isHovered)
        .onHover { h in withAnimation(DS.Motion.quick) { isHovered = h } }
    }
}

private struct SessionRow: View {
    @ObservedObject var vm: DockViewModel
    let project: ClaudeProject
    let session: ClaudeSessionSummary
    @State private var isHovered = false

    private var suggested: AccountProfile? {
        vm.suggestedAccount(lastAccountID: session.lastAccountID ?? project.lastAccountID)
    }

    private var terminalResumeAccounts: [AccountProfile] {
        if !vm.settings.shareClaudeCodeSessions, let ownerID = session.lastAccountID {
            return vm.codeAccounts.filter { $0.id == ownerID }
        }
        return vm.codeAccounts
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            // Same columns as the project header: chevron (10) · icon (22) · text — so titles share one left edge.
            Color.clear.frame(width: 10, height: 1)
            Image(systemName: "text.bubble")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(RelativeTime.string(from: session.lastActivity, now: vm.clock))
                    if let id = session.lastAccountID, let acc = vm.accounts.first(where: { $0.id == id }) {
                        Text("·")
                        Text(acc.name)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: DS.Space.m)
            // Revealed on hover so a long list stays calm; double-clicking the row does the same thing.
            ContinueButton(
                vm: vm,
                title: String(localized: "继续"),
                suggested: suggested,
                lastAccountID: session.lastAccountID,
                disabled: !project.exists,
                compact: true,
                terminalAction: { acc in
                    vm.launchClaudeCode(account: acc, in: project.path, resume: session.id)
                }
            ) { acc in
                vm.openOrFocus(account: acc)
            } more: {
                if !vm.settings.shareClaudeCodeSessions && !vm.codeAccounts.isEmpty {
                    Menu("新会话") {
                        ForEach(vm.codeAccounts) { acc in
                            Button(acc.name) { vm.launchClaudeCode(account: acc, in: project.path) }
                                .disabled(!project.exists || vm.runningStates[acc.id]?.isFrozen == true)
                        }
                    }
                    .disabled(!project.exists)
                }
                Divider()
                Button("复制会话 ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                    vm.showToast(String(localized: "已复制会话 ID"), .success)
                }
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(isHovered ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(DS.Motion.quick) { isHovered = h } }
        .onTapGesture(count: 2) {
            if let suggested, project.exists { vm.openOrFocus(account: suggested) }
        }
        .help(suggested.map { String(localized: "回到 \($0.name) 的 Claude Desktop 窗口") } ?? "")
        .contextMenu {
            Section("用哪个账号继续") {
                ForEach(vm.accounts) { acc in
                    Button("\(acc.name)  ·  \(vm.headroomText(acc) ?? String(localized: "额度未知"))") {
                        vm.openOrFocus(account: acc)
                    }
                    .disabled(!project.exists || vm.runningStates[acc.id]?.isFrozen == true)
                }
            }
            if !terminalResumeAccounts.isEmpty {
                Divider()
                Menu("在终端用 Claude Code 继续") {
                    ForEach(terminalResumeAccounts) { acc in
                        Button("\(acc.name)  ·  \(vm.headroomText(acc) ?? String(localized: "额度未知"))") {
                            vm.launchClaudeCode(account: acc, in: project.path, resume: session.id)
                        }
                        .disabled(!project.exists || vm.runningStates[acc.id]?.isFrozen == true)
                    }
                }
                .disabled(!project.exists)
            }
            if !vm.settings.shareClaudeCodeSessions && !vm.codeAccounts.isEmpty {
                Menu("在终端开始新会话") {
                    ForEach(vm.codeAccounts) { acc in
                        Button(acc.name) {
                            vm.launchClaudeCode(account: acc, in: project.path)
                        }
                        .disabled(!project.exists || vm.runningStates[acc.id]?.isFrozen == true)
                    }
                }
                .disabled(!project.exists)
            }
            Divider()
            Button("复制会话 ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
                vm.showToast(String(localized: "已复制会话 ID"), .success)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "继续") {
            if let suggested, project.exists { vm.openOrFocus(account: suggested) }
        }
    }
}

/// Split button: the click focuses the suggested account in Claude Desktop; the menu lists every account
/// with its remaining quota, with Terminal Claude Code continuation tucked into a secondary submenu.
struct ContinueButton<More: View>: View {
    @ObservedObject var vm: DockViewModel
    let title: String
    let suggested: AccountProfile?
    /// The account that last ran this work; when the suggestion differs, the label says it's a hand-over.
    var lastAccountID: String? = nil
    var disabled: Bool = false
    var compact: Bool = false
    var terminalAction: ((AccountProfile) -> Void)? = nil
    let action: (AccountProfile) -> Void
    @ViewBuilder var more: () -> More

    private var isRelay: Bool {
        guard let last = lastAccountID, let s = suggested else { return false }
        return s.id != last
    }

    private func headroomScore(for acc: AccountProfile) -> Double {
        if vm.runningStates[acc.id]?.isFrozen == true { return -3 }
        if vm.egressHealth(for: acc).needsAttention { return -2 }
        guard let quota = acc.quota else { return -1 }
        let windows = [quota.fiveHour, quota.sevenDay].compactMap { $0 }
        guard !windows.isEmpty else { return -1 }
        if windows.allSatisfy({ $0.isExpired(at: vm.clock) }) {
            return 0.5
        }
        return quota.effectiveHeadroom(at: vm.clock) ?? 0.5
    }

    /// Accounts ordered by remaining quota, most first, so the menu reads as a ranking.
    private var rankedAccounts: [AccountProfile] {
        vm.accounts.sorted { headroomScore(for: $0) > headroomScore(for: $1) }
    }

    private var rankedCodeAccounts: [AccountProfile] {
        let candidates: [AccountProfile]
        if !vm.settings.shareClaudeCodeSessions, let ownerID = lastAccountID {
            candidates = vm.codeAccounts.filter { $0.id == ownerID }
        } else {
            candidates = vm.codeAccounts
        }
        return candidates.sorted { headroomScore(for: $0) > headroomScore(for: $1) }
    }

    @ViewBuilder
    private var menuItems: some View {
        Section("用哪个账号继续") {
            ForEach(rankedAccounts) { acc in
                Button {
                    action(acc)
                } label: {
                    Text(label(for: acc))
                }
                .disabled(disabled || vm.runningStates[acc.id]?.isFrozen == true)
            }
        }
        if let terminalAction, !rankedCodeAccounts.isEmpty {
            Divider()
            Menu("在终端用 Claude Code 继续") {
                ForEach(rankedCodeAccounts) { acc in
                    Button {
                        terminalAction(acc)
                    } label: {
                        Text(label(for: acc))
                    }
                    .disabled(disabled || vm.runningStates[acc.id]?.isFrozen == true)
                }
            }
            .disabled(disabled)
        }
        more()
    }

    var body: some View {
        Group {
            if let suggested, !disabled {
                Menu {
                    menuItems
                } label: {
                    Text(primaryLabel)
                        .monospacedDigit()
                } primaryAction: {
                    action(suggested)
                }
            } else {
                Menu {
                    menuItems
                } label: {
                    Text(primaryLabel)
                        .monospacedDigit()
                }
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .controlSize(compact ? .small : .regular)
        .help(helpText)
    }

    /// Account names are capped so the button never squeezes the thing it acts on.
    private var primaryLabel: String {
        guard let s = suggested else { return title }
        let name = s.name.count > 12 ? String(s.name.prefix(11)) + "…" : s.name
        let quota = vm.headroomText(s).map { " · \($0)" } ?? ""
        return isRelay ? String(localized: "换 \(name)\(quota)") : "\(title) · \(name)\(quota)"
    }

    private var helpText: String {
        if disabled { return String(localized: "项目文件夹不存在，点击展开更多操作") }
        guard let s = suggested else { return String(localized: "暂无可直接继续的账号，点击查看状态或更多操作") }
        return String(localized: "回到 \(s.name) 的 Claude Desktop 窗口")
    }

    private func label(for acc: AccountProfile) -> String {
        var parts = [acc.name, vm.headroomText(acc) ?? String(localized: "额度未知")]
        if vm.runningStates[acc.id]?.isFrozen == true { parts.append(String(localized: "已暂停")) }
        else if vm.egressHealth(for: acc).needsAttention { parts.append(String(localized: "出口异常")) }
        if acc.id == lastAccountID { parts.append(String(localized: "上次使用")) }
        return parts.joined(separator: "  ·  ")
    }
}

/// Native search field.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.delegate = context.coordinator
        f.controlSize = .regular
        return f
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSSearchField { text.wrappedValue = f.stringValue }
        }
    }
}

// MARK: - Claude Desktop handoff

/// Desktop chats live on Anthropic's servers per account and can't be moved; this writes a brief to paste instead.
private struct DesktopHandoffSection: View {
    @ObservedObject var vm: DockViewModel
    @State private var isOpen = false
    @State private var fromID = ""
    @State private var toID = ""
    @State private var summary = ""
    @State private var copied = false

    var body: some View {
        if vm.accounts.count > 1 {
            DisclosureGroup(isExpanded: $isOpen) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text("Claude Desktop 里的聊天保存在各自账号的云端，没法直接搬到另一个账号。可以写几句交接说明，粘贴到新账号的对话里继续。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.m) {
                        Picker("从", selection: $fromID) {
                            ForEach(vm.accounts) { Text($0.name).tag($0.id) }
                        }
                        .frame(maxWidth: 220)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Picker("到", selection: $toID) {
                            ForEach(vm.accounts) { acc in
                                Text(vm.headroomText(acc).map { "\(acc.name) · \($0)" } ?? acc.name).tag(acc.id)
                            }
                        }
                        .frame(maxWidth: 260)
                        Spacer()
                    }
                    TextField("正在做什么、做到哪一步、下一步要做什么", text: $summary, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        if trimmedSummary.isEmpty {
                            Text("先填写交接说明")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(copied ? String(localized: "已复制") : String(localized: "复制交接说明")) { copy(open: false) }
                            .disabled(!canCopy)
                        Button(vm.accounts.first { $0.id == toID }.map { String(localized: "复制并打开 \($0.name)") } ?? String(localized: "复制并打开目标账号")) { copy(open: true) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canCopy)
                    }
                }
                .padding(.top, DS.Space.s)
            } label: {
                Text("Claude Desktop 的聊天怎么换账号继续？")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(DS.Space.l)
            .surface()
            .onAppear(perform: reconcilePair)
            // An account removed (or added) elsewhere must not leave a picker pointing at nothing.
            .onChange(of: vm.accounts.map(\.id)) { _, _ in reconcilePair() }
            .onChange(of: fromID) { old, new in
                if new == toID {
                    toID = vm.accounts.contains(where: { $0.id == old && $0.id != new })
                        ? old : (vm.accounts.first { $0.id != new }?.id ?? "")
                }
            }
            .onChange(of: toID) { old, new in
                if new == fromID {
                    fromID = vm.accounts.contains(where: { $0.id == old && $0.id != new })
                        ? old : (vm.accounts.first { $0.id != new }?.id ?? "")
                }
            }
        }
    }

    private var trimmedSummary: String {
        summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pairIsValid: Bool {
        fromID != toID && vm.accounts.contains { $0.id == fromID } && vm.accounts.contains { $0.id == toID }
    }

    private var canCopy: Bool {
        pairIsValid && !trimmedSummary.isEmpty
    }

    private func reconcilePair() {
        let ids = vm.accounts.map(\.id)
        if !ids.contains(fromID) { fromID = ids.first ?? "" }
        if !ids.contains(toID) || toID == fromID { toID = ids.first { $0 != fromID } ?? "" }
    }

    private func copy(open: Bool) {
        guard canCopy else { return }
        let from = vm.accounts.first { $0.id == fromID }?.name ?? "A"
        let to = vm.accounts.first { $0.id == toID }
        let brief = SessionRadar.buildHandoffBrief(
            fromAccount: from,
            toAccount: to?.name ?? "B",
            taskSummary: trimmedSummary
        )
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(brief, forType: .string) else {
            vm.showToast(String(localized: "复制到剪贴板失败，请重试"), .error)
            return
        }
        withAnimation(DS.Motion.quick) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
        if open, let to { vm.openOrFocus(account: to) }
    }
}

// MARK: - Recent projects on the workbench

/// The three most recent projects, each one click away from continuing with any account.
struct RecentProjectsSection: View {
    @ObservedObject var vm: DockViewModel

    var body: some View {
        let recent = Array(vm.projects.filter(\.exists).prefix(3))
        if !recent.isEmpty && !vm.codeAccounts.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack {
                    SectionLabel(String(localized: "最近的项目"), detail: String(localized: "用任意账号接着上次的会话继续"))
                    Button("全部项目") { vm.navigate(to: .projects) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, project in
                        if idx > 0 { Divider().padding(.leading, 50) } // 16 inset + 22 icon + 12 gap
                        HStack(spacing: DS.Space.m) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.accentColor.opacity(0.85))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                if let title = project.sessions.first?.title, !title.isEmpty {
                                    Text(title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: DS.Space.m)
                            Text(RelativeTime.string(from: project.lastActivity, now: vm.clock))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            ContinueButton(
                                vm: vm,
                                title: String(localized: "继续"),
                                suggested: vm.suggestedAccount(for: project),
                                lastAccountID: project.lastAccountID ?? project.sessions.first?.lastAccountID,
                                disabled: !project.exists,
                                compact: true,
                                terminalAction: { acc in
                                    if !vm.settings.shareClaudeCodeSessions, let latestID = project.sessions.first?.id {
                                        vm.launchClaudeCode(account: acc, in: project.path, resume: latestID)
                                    } else {
                                        vm.launchClaudeCode(account: acc, in: project.path, continueLatest: true)
                                    }
                                }
                            ) { acc in
                                vm.openOrFocus(account: acc)
                            } more: {
                                if !vm.settings.shareClaudeCodeSessions && !vm.codeAccounts.isEmpty {
                                    Menu("新会话") {
                                        ForEach(vm.codeAccounts) { acc in
                                            Button(acc.name) { vm.launchClaudeCode(account: acc, in: project.path) }
                                                .disabled(!project.exists || vm.runningStates[acc.id]?.isFrozen == true)
                                        }
                                    }
                                    .disabled(!project.exists)
                                }
                            }
                        }
                        .padding(.horizontal, DS.Space.l)
                        .padding(.vertical, DS.Space.m)
                        .appearAnimation(index: idx)
                    }
                }
                .surface()
            }
        }
    }
}
