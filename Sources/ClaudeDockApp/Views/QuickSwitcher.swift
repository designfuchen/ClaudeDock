// FILE: Views/QuickSwitcher.swift
import AppKit
import Carbon
import ClaudeDockCore
import SwiftUI

// MARK: - Panel

/// A floating, non-activating panel (like Spotlight): it takes keyboard focus without pulling the user's
/// current app to the background, and disappears when it loses focus.
final class QuickSwitcherPanel: NSPanel {
    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow
        let host = NSHostingView(rootView: rootView)
        // The panel is sized explicitly by fitToContent() (top edge pinned); no automatic resizing fighting it.
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var isComposingIME: Bool {
        (firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    override func resignKey() {
        super.resignKey()
        QuickSwitcher.shared.hide()
    }

    override func cancelOperation(_ sender: Any?) {
        guard !isComposingIME else { return }
        QuickSwitcher.shared.handleCancel()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isComposingIME else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == [.command] {
            if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                QuickSwitcher.shared.handleActivate(alternate: true)
                return true
            }
            if let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...9).contains(digit) {
                if QuickSwitcher.shared.handleSelectAndActivate(index: digit - 1) {
                    return true
                }
            }
        } else if mods == [.option],
                  event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            QuickSwitcher.shared.handleReveal()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !isComposingIME else {
            super.keyDown(with: event)
            return
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            QuickSwitcher.shared.handleMove(1)
        case kVK_UpArrow:
            QuickSwitcher.shared.handleMove(-1)
        case kVK_Escape:
            QuickSwitcher.shared.handleCancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods.contains(.option) {
                QuickSwitcher.shared.handleReveal()
            } else if mods.contains(.command) {
                QuickSwitcher.shared.handleActivate(alternate: true)
            } else {
                QuickSwitcher.shared.handleActivate(alternate: false)
            }
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class QuickSwitcher {
    static let shared = QuickSwitcher()

    /// Default shortcut ⌃⌥Space: ⌘Space (Spotlight), ⌥Space and ⌘⌥Space (Finder search) are commonly taken.
    static let defaultKeyCode = UInt32(kVK_Space)
    static let defaultModifiers = UInt32(controlKey | optionKey)
    static let shortcutLabel = "⌃⌥Space"

    private var panel: QuickSwitcherPanel?
    private weak var vm: DockViewModel?
    private(set) var isRegistered = false
    private var visibilityGeneration = 0
    private var isShown = false
    private let session = QuickSwitcherSession()

    func install(vm: DockViewModel) {
        self.vm = vm
        isRegistered = GlobalHotkeyManager.shared.registerSwitcher(keyCode: Self.defaultKeyCode,
                                                                   modifiers: Self.defaultModifiers) { [weak self] in
            self?.toggle()
        }
    }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    func show() {
        guard let vm else { return }
        if panel == nil {
            panel = QuickSwitcherPanel(rootView: QuickSwitcherView(vm: vm, session: session))
        }
        guard let panel else { return }
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        isShown = true
        session.reset()
        vm.refreshProjects()
        // Upper third of the screen with the pointer, like Spotlight.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let anchorTopY: CGFloat?
        if let frame = screen?.visibleFrame {
            let topY = frame.maxY - frame.height * 0.22
            anchorTopY = topY
            let size = panel.frame.size
            let clampedX = max(frame.minX + 12, min(frame.midX - size.width / 2, frame.maxX - size.width - 12))
            let clampedY = max(frame.minY + 12, min(topY - size.height, frame.maxY - size.height - 12))
            panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            anchorTopY = nil
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // Wait for SwiftUI to commit the reset state and measured list height before revealing.
        DispatchQueue.main.async {
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation, self.isShown, let panel = self.panel else { return }
                self.fitToContent(anchorTopY: anchorTopY)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = DS.Motion.reduceMotion ? 0 : 0.12
                    panel.animator().alphaValue = 1
                }
            }
        }
    }

    /// Sizes the panel to its SwiftUI content, keeping the top edge fixed and clamped to the screen's visible frame.
    func fitToContent(anchorTopY: CGFloat? = nil) {
        guard let panel, let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.height > 0 else { return }
        let top = anchorTopY ?? panel.frame.maxY
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
        let rawY = top - size.height
        let clampedY: CGFloat
        let clampedX: CGFloat
        if let visible {
            clampedY = max(visible.minY + 12, min(rawY, visible.maxY - size.height - 12))
            clampedX = max(visible.minX + 12, min(panel.frame.minX, visible.maxX - size.width - 12))
        } else {
            clampedY = rawY
            clampedX = panel.frame.minX
        }
        let target = NSRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
        guard abs(target.height - panel.frame.height) > 0.5
            || abs(target.minY - panel.frame.minY) > 0.5
            || abs(target.minX - panel.frame.minX) > 0.5 else { return }
        panel.setFrame(target, display: true)
    }

    func hide() {
        guard let panel, isShown else { return }
        isShown = false
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DS.Motion.reduceMotion ? 0 : 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // Only order out if nothing re-opened the panel during the fade.
            Task { @MainActor in
                if self.visibilityGeneration == generation { panel.orderOut(nil) }
            }
        })
    }

    func handleCancel() {
        if !session.query.isEmpty {
            session.query = ""
            session.notice = nil
        } else {
            hide()
        }
    }

    func handleMove(_ delta: Int) {
        guard let vm else { return }
        session.move(delta, in: vm)
    }

    func handleActivate(alternate: Bool) {
        guard let vm else { return }
        session.activate(alternate: alternate, in: vm)
    }

    func handleReveal() {
        guard let vm else { return }
        session.reveal(in: vm)
    }

    @discardableResult
    func handleSelectAndActivate(index: Int) -> Bool {
        guard let vm else { return false }
        return session.selectAndActivate(index: index, in: vm)
    }
}

/// Per-presentation state, reset every time the panel opens.
@MainActor
final class QuickSwitcherSession: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
    @Published var focusToken = UUID()
    @Published var notice: String? = nil

    func reset() {
        query = ""
        selection = 0
        notice = nil
        focusToken = UUID()
    }

    fileprivate func accounts(in vm: DockViewModel) -> [SwitcherItem] {
        let ranked = vm.accounts.enumerated().map { (i, a) in
            (SwitcherItem.account(a, index: i), FuzzyMatch.score(query, in: [a.name, a.identity?.email ?? "", a.identity?.displayName ?? ""]))
        }
        return ranked.filter { $0.1 > 0 }.sorted { query.isEmpty ? false : $0.1 > $1.1 }.map(\.0)
    }

    fileprivate func projects(in vm: DockViewModel) -> [SwitcherItem] {
        guard !vm.codeAccounts.isEmpty else { return [] }
        let pool = vm.projects.filter(\.exists)
        if query.isEmpty { return pool.prefix(5).map { .project($0) } }
        return pool
            .map { p in
                let fields = [p.name, (p.path as NSString).abbreviatingWithTildeInPath] + p.sessions.map(\.title)
                return (p, FuzzyMatch.score(query, in: fields))
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(6)
            .map { .project($0.0) }
    }

    fileprivate func items(in vm: DockViewModel) -> [SwitcherItem] {
        accounts(in: vm) + projects(in: vm)
    }

    func move(_ delta: Int, in vm: DockViewModel) {
        let all = items(in: vm)
        guard !all.isEmpty else { return }
        notice = nil
        selection = (selection + delta + all.count) % all.count
    }

    func reveal(in vm: DockViewModel) {
        let all = items(in: vm)
        guard case .project(let p) = all[safe: selection] else { return }
        notice = nil
        QuickSwitcher.shared.hide()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)])
    }

    @discardableResult
    func selectAndActivate(index: Int, in vm: DockViewModel) -> Bool {
        let all = items(in: vm)
        guard index >= 0, index < all.count else { return false }
        selection = index
        activate(alternate: false, in: vm)
        return true
    }

    func activate(alternate: Bool, in vm: DockViewModel) {
        let all = items(in: vm)
        guard let item = all[safe: selection] else { return }
        switch item {
        case .account(let a, _):
            // Busy: keep the panel open so the selection doesn't silently vanish.
            guard vm.operation(for: a.id) == nil else {
                NSSound.beep()
                notice = String(localized: "\(a.name) 正在执行操作，请稍候")
                return
            }
            notice = nil
            QuickSwitcher.shared.hide()
            vm.openOrFocus(account: a) // routes a paused account to re-check & resume
        case .project(let p):
            if alternate {
                let acc: AccountProfile?
                if !vm.settings.shareClaudeCodeSessions,
                   let ownerID = p.sessions.first?.lastAccountID ?? p.lastAccountID {
                    acc = vm.codeAccounts.first { $0.id == ownerID && vm.runningStates[$0.id]?.isFrozen != true }
                    if acc == nil {
                        NSSound.beep()
                        let msg = String(localized: "未开启会话共享，该项目上次使用的账号当前不可在终端继续")
                        notice = msg
                        vm.showToast(msg, .warning)
                        return
                    }
                } else {
                    acc = vm.suggestedAccount(for: p)
                }
                guard let acc else {
                    NSSound.beep()
                    let msg = String(localized: "可用账号当前均已暂停，请先恢复出口守护后再继续项目")
                    notice = msg
                    vm.showToast(msg, .warning)
                    return
                }
                guard vm.operation(for: acc.id) == nil else {
                    NSSound.beep()
                    notice = String(localized: "\(acc.name) 正在执行操作，请稍候")
                    return
                }
                notice = nil
                QuickSwitcher.shared.hide()
                if !vm.settings.shareClaudeCodeSessions, let latestID = p.sessions.first?.id {
                    vm.launchClaudeCode(account: acc, in: p.path, resume: latestID)
                } else {
                    vm.launchClaudeCode(account: acc, in: p.path, continueLatest: true)
                }
            } else {
                guard let acc = vm.suggestedAccount(for: p) else {
                    NSSound.beep()
                    let msg = String(localized: "可用账号当前均已暂停，请先恢复出口守护后再继续项目")
                    notice = msg
                    vm.showToast(msg, .warning)
                    return
                }
                guard vm.operation(for: acc.id) == nil else {
                    NSSound.beep()
                    notice = String(localized: "\(acc.name) 正在执行操作，请稍候")
                    return
                }
                notice = nil
                QuickSwitcher.shared.hide()
                // Default: back to that account's Claude Desktop window; ⌘↩ continues in Terminal with Claude Code.
                vm.openOrFocus(account: acc)
            }
        }
    }
}

// MARK: - Matching

fileprivate enum SwitcherItem: Identifiable {
    case account(AccountProfile, index: Int)
    case project(ClaudeProject)

    var id: String {
        switch self {
        case .account(let a, _): return "a-\(a.id)"
        case .project(let p): return "p-\(p.id)"
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Native AppKit search input so `↑`/`↓`/`⌥↩`/`Esc` work reliably without breaking Simplified Chinese IME.
private struct SwitcherSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusToken: UUID
    var onMove: (Int) -> Void
    var onActivate: (Bool) -> Void
    var onReveal: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setAccessibilityLabel(String(localized: "搜索账号或项目"))
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        let isComposing = (nsView.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !isComposing && nsView.stringValue != text {
            nsView.stringValue = text
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            Task { @MainActor in
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SwitcherSearchField
        var lastFocusToken: UUID?

        init(parent: SwitcherSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
                return
            }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let mods = NSApp.currentEvent?.modifierFlags.intersection([.command, .option]) ?? []
                if mods.contains(.option) {
                    parent.onReveal()
                } else if mods.contains(.command) {
                    parent.onActivate(true)
                } else {
                    parent.onActivate(false)
                }
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onReveal()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - View

struct QuickSwitcherView: View {
    @ObservedObject var vm: DockViewModel
    @ObservedObject var session: QuickSwitcherSession
    @State private var listHeight: CGFloat = 0
    @State private var hoveredID: String?

    var body: some View {
        let acc = session.accounts(in: vm)
        let prj = session.projects(in: vm)
        let all = acc + prj
        let projectItems = prj.compactMap { item -> ClaudeProject? in
            if case .project(let p) = item { return p }
            return nil
        }
        let duplicateNames = Set(
            Dictionary(grouping: projectItems, by: \.name)
                .filter { $0.value.count > 1 }
                .keys
        )

        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                SwitcherSearchField(
                    text: $session.query,
                    placeholder: String(localized: "切换账号，或继续一个项目"),
                    focusToken: session.focusToken,
                    onMove: { session.move($0, in: vm) },
                    onActivate: { session.activate(alternate: $0, in: vm) },
                    onReveal: { session.reveal(in: vm) },
                    onCancel: { QuickSwitcher.shared.handleCancel() }
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.l + 2)
            .frame(height: 56)

            if let notice = session.notice {
                Divider()
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.s)
                .background(Color.orange.opacity(0.08))
            }

            if !all.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if !acc.isEmpty { groupLabel(String(localized: "账号")) }
                            ForEach(Array(acc.enumerated()), id: \.element.id) { i, item in
                                row(item, rowIndex: i, selected: session.selection == i, duplicateNames: duplicateNames)
                                    .id(i)
                                    .onHover { h in
                                        hoveredID = h ? item.id : (hoveredID == item.id ? nil : hoveredID)
                                    }
                                    .onTapGesture {
                                        session.selection = i
                                        session.activate(alternate: false, in: vm)
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction {
                                        session.selection = i
                                        session.activate(alternate: false, in: vm)
                                    }
                            }
                            if !prj.isEmpty { groupLabel(session.query.isEmpty ? String(localized: "最近的项目") : String(localized: "项目")) }
                            ForEach(Array(prj.enumerated()), id: \.element.id) { j, item in
                                let i = acc.count + j
                                row(item, rowIndex: i, selected: session.selection == i, duplicateNames: duplicateNames)
                                    .id(i)
                                    .onHover { h in
                                        hoveredID = h ? item.id : (hoveredID == item.id ? nil : hoveredID)
                                    }
                                    .onTapGesture {
                                        session.selection = i
                                        session.activate(alternate: false, in: vm)
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction {
                                        session.selection = i
                                        session.activate(alternate: false, in: vm)
                                    }
                            }
                        }
                        .padding(DS.Space.s)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                            }
                        )
                    }
                    .frame(height: listHeight > 0 ? min(listHeight, 352) : nil)
                    .frame(maxHeight: 352)
                    .onPreferenceChange(ListHeightKey.self) { h in
                        guard abs(listHeight - h) > 0.5 else { return }
                        listHeight = h
                        DispatchQueue.main.async {
                            Task { @MainActor in QuickSwitcher.shared.fitToContent() }
                        }
                    }
                    .onChange(of: session.selection) { _, i in
                        withAnimation(DS.Motion.quick) { proxy.scrollTo(i, anchor: .center) }
                    }
                }
                Divider()
                footer(all)
            } else if vm.accounts.isEmpty {
                Divider()
                VStack(spacing: DS.Space.s) {
                    Text("还没有账号")
                        .font(DS.Typo.headline)
                    Button("添加第一个账号") {
                        QuickSwitcher.shared.hide()
                        // Works even in menu bar–only mode: the URL handler reopens the main window.
                        if let url = URL(string: "claudedock://add") { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.xl)
            } else if !session.query.isEmpty {
                Divider()
                Text("没有匹配的账号或项目")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.xl)
            }
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .onChange(of: session.query) { _, _ in
            session.selection = 0
            session.notice = nil
        }
        .onChange(of: session.notice) { _, _ in
            DispatchQueue.main.async {
                Task { @MainActor in QuickSwitcher.shared.fitToContent() }
            }
        }
        .onChange(of: all.map(\.id) + [session.query.isEmpty ? "" : "q"]) { _, _ in
            if all.isEmpty { listHeight = 0 }
            if session.selection >= all.count { session.selection = max(0, all.count - 1) }
            DispatchQueue.main.async {
                Task { @MainActor in QuickSwitcher.shared.fitToContent() }
            }
        }
        .onChange(of: session.focusToken) { _, _ in
            hoveredID = nil
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.s)
            .padding(.top, DS.Space.s)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func row(_ item: SwitcherItem, rowIndex: Int, selected: Bool, duplicateNames: Set<String>) -> some View {
        let isHovered = hoveredID == item.id
        HStack(spacing: DS.Space.m) {
            switch item {
            case .account(let a, _):
                AccountAvatar(account: a, state: vm.runningStates[a.id] ?? .stopped, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(a.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        let health = vm.egressHealth(for: a)
                        if health.needsAttention {
                            Image(systemName: health.symbol).foregroundStyle(health.tone.color).font(.system(size: 11))
                                .help(health.title)
                        }
                    }
                    QuotaInline(quota: a.quota, now: vm.clock)
                }
                Spacer(minLength: DS.Space.m)
                Text(actionTitle(for: a))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if rowIndex < 9 {
                    KeyCap(text: "⌘\(rowIndex + 1)")
                }
            case .project(let p):
                Image(systemName: "folder.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let subtitle = projectSubtitle(for: p, duplicateNames: duplicateNames), !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: DS.Space.m)
                if let s = vm.suggestedAccount(for: p) {
                    Text(vm.headroomText(s).map { String(localized: "用 \(s.name) 继续 · \($0)") } ?? String(localized: "用 \(s.name) 继续"))
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if rowIndex < 9 {
                    KeyCap(text: "⌘\(rowIndex + 1)")
                }
            }
        }
        .padding(.horizontal, DS.Space.s + 2)
        .padding(.vertical, DS.Space.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func projectSubtitle(for p: ClaudeProject, duplicateNames: Set<String>) -> String? {
        let abbrev = (p.path as NSString).abbreviatingWithTildeInPath
        let isDup = duplicateNames.contains(p.name)
        if !session.query.isEmpty {
            let bestSession = p.sessions
                .map { ($0.title, FuzzyMatch.score(session.query, in: [$0.title])) }
                .filter { $0.1 > 0 }
                .max { $0.1 < $1.1 }
            let pathScore = FuzzyMatch.score(session.query, in: [abbrev])
            if let best = bestSession, !best.0.isEmpty, best.1 >= pathScore {
                return isDup ? "\(abbrev) · \(best.0)" : best.0
            }
            if pathScore > 0 || isDup {
                return abbrev
            }
        }
        if let title = p.sessions.first?.title, !title.isEmpty {
            return isDup ? "\(abbrev) · \(title)" : title
        }
        return isDup ? abbrev : nil
    }

    private func footer(_ all: [SwitcherItem]) -> some View {
        HStack(spacing: DS.Space.l) {
            hint("↩", footerPrimary(all))
            if case .project = all[safe: session.selection] {
                hint("⌘↩", String(localized: "在终端继续"))
                hint("⌥↩", String(localized: "在访达中显示"))
            }
            hint("↑↓", String(localized: "选择"))
            hint("esc", session.query.isEmpty ? String(localized: "关闭") : String(localized: "清除搜索"))
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.l)
        .frame(height: 32)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(text: key)
            Text(text)
        }
    }

    private func footerPrimary(_ all: [SwitcherItem]) -> String {
        switch all[safe: session.selection] {
        case .account(let a, _): return actionTitle(for: a)
        case .project: return String(localized: "回到 Claude Desktop")
        case nil: return String(localized: "打开")
        }
    }

    private func actionTitle(for a: AccountProfile) -> String {
        let state = vm.runningStates[a.id] ?? .stopped
        if state.isFrozen { return String(localized: "重新检测并恢复") }
        return state.isActive ? String(localized: "切换") : String(localized: "打开")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
