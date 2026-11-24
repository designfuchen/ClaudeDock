// FILE: Views/StatusComponents.swift
import AppKit
import ClaudeDockCore
import SwiftUI

// MARK: - Semantic Tone

/// Unified semantic color language: green is reserved exclusively for freshly verified states.
enum StatusTone {
    case verified, neutral, caution, critical

    var color: Color {
        switch self {
        case .verified: return DS.Semantic.verified
        case .neutral: return .secondary
        case .caution: return DS.Semantic.caution
        case .critical: return DS.Semantic.critical
        }
    }
}

// MARK: - Egress Health Presentation

extension EgressHealth {
    var tone: StatusTone {
        switch self {
        case .verified: return .verified
        case .off, .unverified, .stale: return .neutral
        case .misconfigured, .probeFailed: return .caution
        case .mismatch: return .critical
        }
    }

    var symbol: String {
        switch self {
        case .off: return "shield.slash"
        case .misconfigured: return "exclamationmark.shield"
        case .unverified: return "shield"
        case .verified: return "checkmark.shield.fill"
        case .stale: return "clock.badge.checkmark"
        case .mismatch: return "xmark.shield.fill"
        case .probeFailed: return "wifi.exclamationmark"
        }
    }

    /// Concise state label always paired with the status symbol.
    var title: String {
        switch self {
        case .off: return String(localized: "未开启守护")
        case .misconfigured: return String(localized: "配置不完整")
        case .unverified: return String(localized: "尚未验证")
        case .verified: return String(localized: "出口已验证")
        case .stale: return String(localized: "待重新检测")
        case .mismatch: return String(localized: "出口不符")
        case .probeFailed: return String(localized: "无法检测")
        }
    }

    /// Evidence line: measured location, masked IP, and relative timestamp.
    func detail(now: Date) -> String {
        switch self {
        case .off:
            return String(localized: "使用默认网络，启动时不检查出口")
        case .misconfigured(let reason):
            return reason
        case .unverified:
            return String(localized: "打开时会先检测出口")
        case .verified(let o):
            return "\(o.locationLabel) · \(o.maskedIP) · \(RelativeTime.string(from: o.checkedAt, now: now))"
        case .stale(let o):
            return String(localized: "上次 \(o.locationLabel) · \(RelativeTime.string(from: o.checkedAt, now: now))")
        case .mismatch(_, let o):
            if let o { return String(localized: "当前出口：\(o.locationLabel) · \(o.maskedIP)") }
            return String(localized: "当前出口不符合规则")
        case .probeFailed:
            return String(localized: "连不上代理，或检测服务没有响应")
        }
    }
}

enum RelativeTime {
    static func string(from date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 45 { return String(localized: "刚刚") }
        if s < 3600 { return String(localized: "\(max(1, s / 60))\u{00A0}分钟前") }
        if s < 86400 { return String(localized: "\(s / 3600)\u{00A0}小时前") }
        return String(localized: "\(s / 86400)\u{00A0}天前")
    }
}

/// Human-readable statement of what an egress policy requires.
enum PolicyText {
    static func expectation(_ policy: EgressPolicy) -> String {
        var parts: [String] = []
        if let ip = policy.pinnedIP, !ip.isEmpty { parts.append("IP \(ip)") }
        if let p = policy.pinnedIPPrefix, !p.isEmpty { parts.append("IP \(p)*") }
        if !policy.allowedCities.isEmpty { parts.append(policy.allowedCities.joined(separator: "/")) }
        if !policy.allowedRegions.isEmpty { parts.append(policy.allowedRegions.joined(separator: "/")) }
        if !policy.allowedCountries.isEmpty { parts.append(policy.allowedCountries.joined(separator: "/")) }
        if !policy.allowedTimezones.isEmpty { parts.append(String(localized: "时区 \(policy.allowedTimezones.joined(separator: "/"))")) }
        if parts.isEmpty { return String(localized: "代理可用即可") }
        return parts.joined(separator: " · ")
    }

    /// Short rule summary for compact spaces; full policy goes in a tooltip.
    static func compact(_ policy: EgressPolicy) -> String {
        if let ip = policy.pinnedIP, !ip.isEmpty { return "IP \(ip)" }
        if let prefix = policy.pinnedIPPrefix, !prefix.isEmpty { return "IP \(prefix)*" }
        let place = [policy.allowedCities.first, policy.allowedRegions.first, policy.allowedCountries.first]
            .compactMap { $0 }.filter { !$0.isEmpty }
        if !place.isEmpty { return place.joined(separator: ", ") }
        if let tz = policy.allowedTimezones.first(where: { !$0.isEmpty }) { return tz }
        return String(localized: "代理可用即可")
    }
}

// MARK: - Egress Health Chip

struct EgressHealthChip: View {
    let health: EgressHealth
    let now: Date
    var showsDetail: Bool = true

    @Environment(\.displayScale) private var displayScale

    init(health: EgressHealth, now: Date, showsDetail: Bool = true) {
        self.health = health
        self.now = now
        self.showsDetail = showsDetail
    }

    var body: some View {
        let toneColor = health.tone.color
        let isNeutral = health.tone == .neutral

        HStack(spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: health.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(health.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(toneColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(toneColor.opacity(isNeutral ? 0.08 : 0.12), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(toneColor.opacity(isNeutral ? 0.16 : 0.26), lineWidth: 1 / max(1, displayScale))
            )
            .fixedSize()

            if showsDetail {
                Text(health.detail(now: now))
                    .font(DS.Typo.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(health.detail(now: now))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("出口状态：\(health.title)，\(health.detail(now: now))")
        .animation(DS.Motion.quick, value: health.title)
    }
}

// MARK: - Persistent Incident Card

/// Security incident card pinned until resolved: expected rule vs actual egress, action taken, and safe recovery.
struct IncidentCard: View {
    let alert: EgressAlert
    let account: AccountProfile?
    let state: RunningState
    let operation: AccountOperation?
    let now: Date
    var compact: Bool = false
    let onRecheck: () -> Void
    let onBypass: () -> Void
    var onDismiss: (() -> Void)?

    @State private var confirmBypass = false
    @Environment(\.displayScale) private var displayScale

    init(
        alert: EgressAlert,
        account: AccountProfile?,
        state: RunningState,
        operation: AccountOperation?,
        now: Date,
        compact: Bool = false,
        onRecheck: @escaping () -> Void,
        onBypass: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.alert = alert
        self.account = account
        self.state = state
        self.operation = operation
        self.now = now
        self.compact = compact
        self.onRecheck = onRecheck
        self.onBypass = onBypass
        self.onDismiss = onDismiss
    }

    private var headline: String {
        switch alert.actionTaken {
        case .freeze:
            return state.isFrozen ? String(localized: "\(alert.accountName) 已暂停运行") : String(localized: "\(alert.accountName) 出口异常")
        case .quit:
            if state.isActive {
                return String(localized: "\(alert.accountName) 出口异常（窗口仍在运行）")
            }
            return alert.affectedProcessCount > 0 ? String(localized: "\(alert.accountName) 已被关闭") : String(localized: "\(alert.accountName) 出口异常")
        case .notify:
            return String(localized: "\(alert.accountName) 出口异常")
        }
    }

    private var actionTakenText: String {
        switch alert.actionTaken {
        case .freeze:
            return alert.affectedProcessCount > 0 ? String(localized: "已暂停这个账号，暂停期间不会再发出请求") : String(localized: "无法暂停，没有找到运行中的窗口")
        case .quit:
            if alert.affectedProcessCount > 0 {
                return state.isActive ? String(localized: "曾关闭窗口，但账号目前仍在运行") : String(localized: "已关闭窗口")
            }
            return String(localized: "尝试关闭，但窗口可能仍在运行")
        case .notify:
            return String(localized: "仅发送提醒，窗口仍在运行")
        }
    }

    private var actionFailedOrStillActive: Bool {
        switch alert.actionTaken {
        case .freeze:
            return alert.affectedProcessCount == 0 || !state.isFrozen
        case .quit:
            return alert.affectedProcessCount == 0 || state.isActive
        case .notify:
            return false
        }
    }

    private var measuredText: String {
        if let o = alert.observation { return "\(o.locationLabel) · \(o.maskedIP)" }
        return String(localized: "未能获取出口信息")
    }

    private var primaryTitle: String {
        if state.isFrozen { return String(localized: "重新检测并恢复") }
        return state.isActive ? String(localized: "重新检测") : String(localized: "重新检测并打开")
    }

    private var dismissTitle: String {
        if account == nil { return String(localized: "移除提醒") }
        return alert.actionTaken == .notify ? String(localized: "知道了") : String(localized: "稍后处理")
    }

    private var canBypass: Bool {
        account != nil && alert.actionTaken != .notify && (state.isFrozen || !state.isActive)
    }

    private var guidanceHint: String {
        alert.observation != nil
            ? String(localized: "切回正确的代理节点后再重新检测")
            : String(localized: "请确认代理与网络连接正常后再重新检测")
    }

    var body: some View {
        let wellShape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)

        VStack(alignment: .leading, spacing: compact ? DS.Space.s : DS.Space.m) {
            HStack(alignment: .center, spacing: DS.Space.s) {
                ZStack {
                    Circle()
                        .fill(DS.Semantic.critical.opacity(0.15))
                        .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
                    Image(systemName: alert.observation == nil ? "wifi.exclamationmark" : "xmark.shield.fill")
                        .font(.system(size: compact ? 11 : 13, weight: .semibold))
                        .foregroundStyle(DS.Semantic.critical)
                }
                .accessibilityHidden(true)
                Text(headline)
                    .font(.system(size: compact ? 13 : 14, weight: .semibold))
                Spacer(minLength: DS.Space.s)
                Text(RelativeTime.string(from: alert.timestamp, now: now))
                    .font(DS.Typo.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                if let account {
                    row(String(localized: "当前规则"), PolicyText.expectation(account.egressPolicy))
                } else {
                    row(String(localized: "账号状态"), String(localized: "此账号已删除"))
                }
                row(String(localized: "触发时检测"), measuredText, emphasize: true)
                if !compact || actionFailedOrStillActive {
                    row(String(localized: "已执行"), actionTakenText)
                }
            }
            .padding(compact ? DS.Space.s : DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(wellShape.fill(DS.subtleFill))
            .overlay(wellShape.strokeBorder(DS.Semantic.critical.opacity(0.18), lineWidth: 1 / max(1, displayScale)))

            if compact {
                actionButtons
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.s) {
                        actionButtons
                        Spacer(minLength: DS.Space.s)
                        Text(guidanceHint)
                            .font(DS.Typo.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        actionButtons
                        Text(guidanceHint)
                            .font(DS.Typo.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(compact ? DS.Space.m : DS.Space.l)
        .surface(accent: DS.Semantic.critical, tint: DS.Semantic.critical)
        .confirmationDialog("跳过出口检测，继续运行 \(alert.accountName)？", isPresented: $confirmBypass) {
            Button("仍然继续", role: .destructive, action: onBypass)
            Button("取消", role: .cancel) {}
        } message: {
            if let o = alert.observation {
                Text("仅本次生效，不改规则。上次检测到的出口：\(o.locationLabel) · \(o.maskedIP)（\(RelativeTime.string(from: o.checkedAt, now: now))）。跳过检测后，本次连接的实际出口未知。")
            } else {
                Text("仅本次生效，不改规则。未能获取上次出口信息，跳过检测后本次连接的实际出口未知。")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var actionButtons: some View {
        HStack(spacing: DS.Space.s) {
            if account != nil {
                Button(action: onRecheck) {
                    HStack(spacing: 6) {
                        if let operation {
                            ProgressView()
                                .controlSize(.mini)
                                .colorScheme(.dark)
                            Text(operation.label)
                                .lineLimit(1)
                        } else {
                            Text(primaryTitle)
                                .lineLimit(1)
                        }
                    }
                    .frame(minWidth: compact ? 0 : 88)
                }
                .buttonStyle(.dsPrimary)
                .controlSize(compact ? .small : .regular)
                .disabled(operation != nil)
                .fixedSize()
            }

            if let onDismiss {
                Button(dismissTitle, action: onDismiss)
                    .buttonStyle(.dsSecondary)
                    .controlSize(compact ? .small : .regular)
                    .lineLimit(1)
                    .fixedSize()
                    .help("关闭这条提醒。出口状态仍会继续显示，直到恢复正常。")
            }

            if canBypass && !compact {
                Button("忽略规则继续…") { confirmBypass = true }
                    .buttonStyle(.dsSecondary(tint: DS.Semantic.critical))
                    .controlSize(.regular)
                    .lineLimit(1)
                    .fixedSize()
                    .disabled(operation != nil)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, emphasize: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(DS.Typo.secondary)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: emphasize ? .semibold : .regular))
                .foregroundStyle(emphasize ? DS.Semantic.critical : Color.primary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Floating Toast HUD

struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    init(toast: Toast, onDismiss: @escaping () -> Void) {
        self.toast = toast
        self.onDismiss = onDismiss
    }

    private var symbol: String {
        switch toast.tone {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch toast.tone {
        case .success: return DS.Semantic.verified
        case .info: return .accentColor
        case .warning: return DS.Semantic.caution
        case .error: return DS.Semantic.critical
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)

        HStack(alignment: .center, spacing: DS.Space.m) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 24, height: 24)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
            }
            .accessibilityHidden(true)

            if toast.isPersistent {
                Text(toast.text)
                    .font(DS.Typo.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(toast.text)
                    .font(DS.Typo.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if toast.isPersistent {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.dsGhostIcon(size: 22))
                .accessibilityLabel("关闭提示")
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .background(.regularMaterial, in: shape)
        .hairlineBorder(shape, color.opacity(0.32))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.14), radius: 16, y: 7)
        .contentShape(shape)
        .onTapGesture {
            if !toast.isPersistent {
                onDismiss()
            }
        }
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
    }
}

private struct ToastOverlayModifier: ViewModifier {
    @ObservedObject var vm: DockViewModel
    let edge: VerticalEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                ZStack {
                    if let toast = vm.toast {
                        ToastView(toast: toast, onDismiss: { vm.dismissToast() })
                            .padding(edge == .bottom ? 20 : 10)
                            .padding(.top, edge == .top ? 48 : 0)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .move(edge: edge == .bottom ? .bottom : .top).combined(with: .opacity)
                            )
                            .id(toast.id)
                    }
                }
                .animation(DS.Motion.standard, value: vm.toast?.id)
            }
            .onAppear { announceToast(vm.toast) }
            .onChange(of: vm.toast?.id) { _, _ in
                announceToast(vm.toast)
            }
    }

    private func announceToast(_ toast: Toast?) {
        guard let toast, let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: toast.text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

extension View {
    /// Floats the current toast over the view (bottom in windows, top in the menu bar so it never hides the footer).
    func toastOverlay(_ vm: DockViewModel, edge: VerticalEdge = .bottom) -> some View {
        modifier(ToastOverlayModifier(vm: vm, edge: edge))
    }
}

// MARK: - Incident Stack

/// Open security incidents sorted newest-first above the active page.
struct IncidentStack: View {
    @ObservedObject var vm: DockViewModel
    var compact: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(vm: DockViewModel, compact: Bool = false) {
        self.vm = vm
        self.compact = compact
    }

    var body: some View {
        let alerts = vm.activeAlerts.values.sorted { $0.timestamp > $1.timestamp }
        let threshold = compact ? 1 : 2
        if !alerts.isEmpty {
            if alerts.count <= threshold {
                cards(alerts)
            } else {
                ScrollView {
                    cards(alerts)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: (compact ? 220 : 300) + 24)
                .padding(.horizontal, -14)
                .padding(.vertical, -12)
            }
        }
    }

    @ViewBuilder
    private func cards(_ alerts: [EgressAlert]) -> some View {
        VStack(spacing: DS.Space.s) {
            ForEach(alerts) { alert in
                let account = vm.accounts.first { $0.id == alert.accountID }
                IncidentCard(
                    alert: alert,
                    account: account,
                    state: vm.runningStates[alert.accountID] ?? .stopped,
                    operation: vm.operation(for: alert.accountID),
                    now: vm.clock,
                    compact: compact,
                    onRecheck: { recheck(alert: alert, account: account, bypass: false) },
                    onBypass: { recheck(alert: alert, account: account, bypass: true) },
                    onDismiss: { vm.dismissIncident(for: alert.accountID) }
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity)
                )
            }
        }
        .animation(DS.Motion.standard, value: alerts.map(\.id))
    }

    private func recheck(alert: EgressAlert, account: AccountProfile?, bypass: Bool) {
        guard let account else {
            vm.dismissIncident(for: alert.accountID)
            return
        }
        let state = vm.runningStates[account.id] ?? .stopped
        if state.isFrozen {
            vm.resume(account: account, forceBypass: bypass)
        } else if !state.isActive {
            vm.openOrFocus(account: account, forceBypass: bypass)
        } else {
            vm.recheckEgress(account: account)
        }
    }
}
