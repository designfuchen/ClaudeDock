// FILE: Views/AccountCardView.swift
import AppKit
import ClaudeDockCore
import SwiftUI

/// One account on the workbench: full non-truncated identity, quota meters (with prominent Desktop / Claude Code sign-in CTAs),
/// two-line egress readout, and custom tactile actions.
struct AccountCardView: View {
    let account: AccountProfile
    let index: Int
    let state: RunningState
    let alert: EgressAlert?
    let health: EgressHealth
    let isRecommended: Bool
    let operation: AccountOperation?
    let hotkeyLabel: String?
    let isRefreshingQuota: Bool
    let now: Date

    let onOpenOrFocus: () -> Void
    let onFreeze: () -> Void
    let onResume: () -> Void
    let onQuit: () -> Void
    let onPinEgress: () -> Void
    let onRefreshQuota: () -> Void
    var onEdit: (() -> Void)?
    var onSignIn: (() -> Void)?
    /// Guided Claude Desktop sign-in (closes other Claude windows while signing in).
    var onDesktopSignIn: (() -> Void)?

    @State private var isHovered = false
    @State private var pulseCount = 0
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    init(
        account: AccountProfile,
        index: Int,
        state: RunningState,
        alert: EgressAlert?,
        health: EgressHealth,
        isRecommended: Bool,
        operation: AccountOperation?,
        hotkeyLabel: String?,
        isRefreshingQuota: Bool,
        now: Date,
        onOpenOrFocus: @escaping () -> Void,
        onFreeze: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onPinEgress: @escaping () -> Void,
        onRefreshQuota: @escaping () -> Void,
        onEdit: (() -> Void)? = nil,
        onSignIn: (() -> Void)? = nil,
        onDesktopSignIn: (() -> Void)? = nil
    ) {
        self.account = account
        self.index = index
        self.state = state
        self.alert = alert
        self.health = health
        self.isRecommended = isRecommended
        self.operation = operation
        self.hotkeyLabel = hotkeyLabel
        self.isRefreshingQuota = isRefreshingQuota
        self.now = now
        self.onOpenOrFocus = onOpenOrFocus
        self.onFreeze = onFreeze
        self.onResume = onResume
        self.onQuit = onQuit
        self.onPinEgress = onPinEgress
        self.onRefreshQuota = onRefreshQuota
        self.onEdit = onEdit
        self.onSignIn = onSignIn
        self.onDesktopSignIn = onDesktopSignIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header
            quotaBlock
            egressBlock
            Spacer(minLength: 0)
            Rectangle()
                .fill(DS.hairline)
                .frame(height: 1 / max(1, displayScale))
            footer
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .fill(.clear)
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .onTapGesture(count: 2) {
                    pulseCount += 1
                    primaryAction()
                }
        }
        .surface(accent: borderAccent, tint: cardTint, hovered: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .onHover { hovering in
            withAnimation(DS.Motion.quick) { isHovered = hovering }
        }
        .pulse(on: pulseCount)
        .contextMenu { actionMenuItems }
        .animation(DS.Motion.quick, value: operation)
        .animation(DS.Motion.quick, value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityAction(named: primaryTitle) { primaryAction() }
    }

    private var cardAccessibilityLabel: String {
        var parts = [account.name]
        if account.isDefault { parts.append(String(localized: "主账号")) }
        if isRecommended { parts.append(String(localized: "推荐")) }
        parts.append(state.label)
        if alert != nil {
            parts.append(String(localized: "出口异常，\(health.title)"))
        }
        return parts.joined(separator: String(localized: "，"))
    }

    /// Scheme-adjusted foreground tint derived from `account.accentColor` so icons, pills, and secondary buttons
    /// stay crisp and WCAG-AA legible over subtle fills in both Light and Dark modes.
    private var readableAccent: Color {
        guard let srgb = NSColor(account.accentColor).usingColorSpace(.sRGB) else {
            return account.accentColor
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let relLum = 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent

        if colorScheme == .dark {
            let lifted = NSColor(hue: h, saturation: min(s, 0.70), brightness: max(b, 0.90), alpha: 1)
            let frac: CGFloat = relLum < 0.35 ? 0.28 : 0.12
            if let c = lifted.usingColorSpace(.sRGB) {
                return Color(
                    red: Double(c.redComponent + (1 - c.redComponent) * frac),
                    green: Double(c.greenComponent + (1 - c.greenComponent) * frac),
                    blue: Double(c.blueComponent + (1 - c.blueComponent) * frac)
                )
            }
            return Color(nsColor: lifted)
        } else {
            if relLum > 0.40 {
                let darkened = NSColor(hue: h, saturation: min(1.0, s * 1.05), brightness: min(b, 0.54), alpha: 1)
                return Color(nsColor: darkened)
            }
            return account.accentColor
        }
    }

    // MARK: Header — Multi-line Uncut Identity

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            AccountAvatar(account: account, state: state, size: AccountAvatar.Size.card.rawValue)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                // Line 1: Account name + status tags + shortcut keycap
                HStack(alignment: .center, spacing: 6) {
                    Text(account.name)
                        .font(DS.Typo.cardTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    if account.isDefault {
                        Pill(text: String(localized: "主账号"), color: .secondary)
                    }
                    if isRecommended {
                        Pill(text: String(localized: "推荐"), symbol: "sparkles", color: DS.Semantic.verified)
                    }
                    if state.isFrozen {
                        Pill(text: String(localized: "已暂停"), symbol: "pause.fill", color: DS.Semantic.caution)
                    }
                    Spacer(minLength: 4)
                    if let hotkeyLabel {
                        KeyCap(text: hotkeyLabel)
                            .help("在任何应用里按 \(hotkeyLabel) 直接切到这个账号")
                    }
                }

                // Line 2: Display name + plan badge (or login status when email is absent / expired)
                if let identityLine = displayAndPlanLine {
                    HStack(alignment: .center, spacing: 6) {
                        if let name = identityLine.displayName {
                            Text(name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.82))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let plan = identityLine.plan {
                            Pill(text: plan, color: readableAccent)
                        }
                        if let fallback = identityLine.fallbackStatus {
                            Text(fallback)
                                .font(DS.Typo.secondary)
                                .foregroundStyle(identityLine.isExpired ? DS.Semantic.caution : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Line 3: Full email on its own dedicated line (wrapping allowed, selectable)
                if let email = normalizedEmail {
                    Text(email)
                        .font(DS.Typo.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var normalizedEmail: String? {
        guard let raw = account.identity?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    private var isDesktopSignedIn: Bool {
        normalizedEmail != nil || account.identity?.loggedIn == true || account.identity?.accountUUID != nil
    }

    private var formattedPlan: String? {
        guard let raw = account.identity?.planType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        let parts = raw
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        return parts.map { part in
            let lower = part.lowercased()
            if lower == "api" { return "API" }
            if lower.hasSuffix("x"), lower.count > 1, lower.dropLast().allSatisfy(\.isNumber) {
                return lower
            }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private var displayAndPlanLine: (displayName: String?, plan: String?, fallbackStatus: String?, isExpired: Bool)? {
        let plan = formattedPlan
        let trimmedAccountName = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDisplay = account.identity?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let distinctDisplay: String? = {
            guard let rawDisplay, !rawDisplay.isEmpty else { return nil }
            if let email = normalizedEmail, rawDisplay.caseInsensitiveCompare(email) == .orderedSame {
                return nil
            }
            if rawDisplay.caseInsensitiveCompare(trimmedAccountName) == .orderedSame {
                return nil
            }
            return rawDisplay
        }()

        if normalizedEmail != nil {
            let expired = account.identity?.loggedIn == false
            let status = expired ? String(localized: "登录已失效") : nil
            if distinctDisplay == nil && plan == nil && status == nil { return nil }
            return (distinctDisplay, plan, status, expired)
        }
        if account.identity?.loggedIn == true {
            return (distinctDisplay, plan, distinctDisplay == nil ? String(localized: "已登录") : nil, false)
        }
        if account.identity?.accountUUID != nil {
            return (distinctDisplay, plan, String(localized: "已登录 Claude\u{00A0}Desktop"), false)
        }
        return (nil, plan, String(localized: "打开后登录"), false)
    }

    // MARK: Quota Block & Guided Sign-In CTAs

    private var isLoggedOut: Bool {
        account.quota?.status == .loggedOut
    }

    private var hasQuotaMeters: Bool {
        account.quota?.fiveHour != nil || account.quota?.sevenDay != nil
    }

    @ViewBuilder
    private var quotaBlock: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)

        if !isDesktopSignedIn, !hasQuotaMeters, let onDesktopSignIn {
            desktopSignInPrompt(action: onDesktopSignIn)
        } else if isLoggedOut, !hasQuotaMeters, let onSignIn {
            loggedOutCardPrompt(action: onSignIn)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                QuotaPanel(
                    quota: account.quota,
                    now: now,
                    isRefreshing: isRefreshingQuota,
                    onRefresh: onRefreshQuota,
                    onSignIn: isLoggedOut ? nil : onSignIn
                )

                if isLoggedOut, let onSignIn {
                    HStack(spacing: DS.Space.s) {
                        Text("登录已过期，重新登录后更新额度")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DS.Space.xs)
                        Button("登录 Claude\u{00A0}Code", action: onSignIn)
                            .buttonStyle(.dsSecondary(tint: readableAccent))
                            .controlSize(.small)
                            .help("打开终端，用这个账号自己的设置和代理登录。登录后回到这里会自动读取额度。")
                    }
                    .padding(.top, 2)
                }
            }
            .padding(DS.Space.m)
            .background(shape.fill(DS.subtleFill))
            .hairlineBorder(shape)
        }
    }

    /// Guided Claude Desktop sign-in callout for accounts that have never established a Desktop session.
    private func desktopSignInPrompt(action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                desktopSignInCopy
                    .fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: DS.Space.s)
                signInDesktopButton(action: action, fullWidth: false)
            }

            VStack(alignment: .leading, spacing: DS.Space.s) {
                desktopSignInCopy
                signInDesktopButton(action: action, fullWidth: true)
            }
        }
        .padding(DS.Space.m)
        .background(shape.fill(DS.subtleFill))
        .hairlineBorder(shape, readableAccent.opacity(0.24))
    }

    private var desktopSignInCopy: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(account.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: "person.badge.key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(readableAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("尚未登录 Claude\u{00A0}Desktop")
                    .font(DS.Typo.headline)
                Text("使用登录助手隔离窗口，安全完成首次登录（会暂时关闭其他 Claude 窗口）")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func signInDesktopButton(action: @escaping () -> Void, fullWidth: Bool) -> some View {
        Button(action: action) {
            Label("登录 Claude\u{00A0}Desktop…", systemImage: "person.badge.key")
        }
        .buttonStyle(.dsSecondary(tint: readableAccent, fullWidth: fullWidth))
        .controlSize(.small)
        .help("使用登录助手登录 Claude Desktop。登录期间会暂时关闭其他已打开的 Claude 窗口，避免 OAuth 回调串号。")
    }

    /// Adaptive signed-out callout: keeps phrases intact with zero orphan words at 340pt+ and features a visible button.
    private func loggedOutCardPrompt(action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                loggedOutCopy
                    .fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: DS.Space.s)
                signInClaudeCodeButton(action: action, fullWidth: false)
            }

            VStack(alignment: .leading, spacing: DS.Space.s) {
                loggedOutCopy
                signInClaudeCodeButton(action: action, fullWidth: true)
            }
        }
        .padding(DS.Space.m)
        .background(shape.fill(DS.subtleFill))
        .hairlineBorder(shape, readableAccent.opacity(0.24))
    }

    private var loggedOutCopy: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(account.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(readableAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("尚未获取额度")
                    .font(DS.Typo.headline)
                Text("登录 Claude\u{00A0}Code 后自动读取额度")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func signInClaudeCodeButton(action: @escaping () -> Void, fullWidth: Bool) -> some View {
        Button(action: action) {
            Label("登录 Claude\u{00A0}Code", systemImage: "arrow.up.forward.app")
        }
        .buttonStyle(.dsSecondary(tint: readableAccent, fullWidth: fullWidth))
        .controlSize(.small)
        .help("打开终端，用这个账号自己的设置和代理登录。登录后回到这里会自动读取额度。")
    }

    // MARK: Egress Block — Chip on Line 1, Full Location/IP/Time on Line 2

    @ViewBuilder
    private var egressBlock: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)

        if account.egressPolicy.mode == .disabled {
            let borderTone: Color = alert != nil ? DS.Semantic.critical.opacity(0.35) : DS.hairline

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: DS.Space.s) {
                    Pill(text: String(localized: "未开启出口守护"), symbol: "network", color: .secondary)
                    Spacer(minLength: 4)
                    if account.proxy.enabled {
                        Text("127.0.0.1:\(String(account.proxy.port))")
                            .font(DS.Typo.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(account.proxy.enabled
                    ? String(localized: "使用账号独立代理端口 · 不启用出口守护")
                    : String(localized: "使用系统默认网络 · 不启用出口守护"))
                    .font(DS.Typo.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if alert != nil {
                    egressAlertStrip
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 10)
            .background(shape.fill(DS.subtleFill))
            .hairlineBorder(shape, borderTone)
        } else {
            let borderTone: Color = {
                if alert != nil || health.tone == .critical { return DS.Semantic.critical.opacity(0.35) }
                if health.tone == .caution { return DS.Semantic.caution.opacity(0.28) }
                return DS.hairline
            }()

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: DS.Space.s) {
                    EgressHealthChip(health: health, now: now, showsDetail: false)
                    Spacer(minLength: 4)
                    Text("规则 · \(PolicyText.compact(account.egressPolicy))")
                        .font(DS.Typo.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("出口规则：\(PolicyText.expectation(account.egressPolicy))")
                }
                Text(health.detail(now: now))
                    .font(DS.Typo.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if alert != nil {
                    egressAlertStrip
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 10)
            .background(shape.fill(DS.subtleFill))
            .hairlineBorder(shape, borderTone)
            .accessibilityElement(children: .contain)
        }
    }

    private var egressAlertStrip: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Semantic.critical)
                .padding(.top, 1)
            Text(state.isFrozen
                ? String(localized: "出口异常已触发暂停 · 请检查代理节点后点击下方重新检测并恢复")
                : String(localized: "检测到出口异常 · 请检查代理节点后点击下方重新检测"))
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Semantic.critical)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Semantic.critical.opacity(0.10))
        )
    }

    // MARK: Footer — Status & Custom Actions

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: 5) {
                StatusDot(state: state, size: 7)
                Text(state.label)
                    .font(.system(size: 12, weight: state.isActive ? .medium : .regular))
                    .foregroundStyle(state.isFrozen ? DS.Semantic.caution : (state.isActive ? .primary : .secondary))
                    .lineLimit(1)
            }

            Spacer(minLength: DS.Space.xs)

            GhostMenuButton(symbol: "ellipsis", size: 28) {
                actionMenuItems
            }
            .disabled(operation != nil)
            .help("更多操作")
            .accessibilityLabel("\(account.name) 的更多操作")

            primaryButton
        }
    }

    private var isEgressIncident: Bool {
        alert != nil || health.tone == .critical || health.tone == .caution
    }

    @ViewBuilder
    private var primaryButton: some View {
        if let operation {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(operation.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .transition(.opacity)
        } else if alert != nil {
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .frame(minWidth: 44)
            }
            .buttonStyle(.dsPrimary(tint: DS.Semantic.critical))
            .help(primaryHelp)
        } else if state.isFrozen {
            let tint = (account.egressPolicy.mode != .disabled && isEgressIncident)
                ? DS.Semantic.caution
                : account.accentColor
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .frame(minWidth: 44)
            }
            .buttonStyle(.dsPrimary(tint: tint))
            .help(primaryHelp)
        } else if state.isActive || isRecommended {
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .frame(minWidth: 44)
            }
            .buttonStyle(.dsPrimary(tint: account.accentColor))
            .help(primaryHelp)
        } else {
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .frame(minWidth: 44)
            }
            .buttonStyle(.dsSecondary(tint: readableAccent))
            .help(primaryHelp)
        }
    }

    private var primaryTitle: String {
        if state.isFrozen {
            return (account.egressPolicy.mode != .disabled && isEgressIncident)
                ? String(localized: "重新检测并恢复")
                : String(localized: "继续运行")
        }
        if alert != nil {
            return state.isActive ? String(localized: "检测并切换") : String(localized: "检测并打开")
        }
        return state.isActive ? String(localized: "切换") : String(localized: "打开")
    }

    private var primaryHelp: String {
        if state.isFrozen {
            if account.egressPolicy.mode == .disabled { return String(localized: "恢复运行 \(account.name)") }
            return isEgressIncident
                ? String(localized: "先检测出口是否恢复正常，通过后再继续运行")
                : String(localized: "检测出口后继续运行 \(account.name)")
        }
        if alert != nil {
            return state.isActive
                ? String(localized: "检测到出口异常，先重新检测出口再切换 \(account.name)")
                : String(localized: "检测到出口异常，先重新检测出口再打开 \(account.name)")
        }
        if state.isActive { return String(localized: "把 \(account.name) 的窗口切到最前面") }
        return account.egressPolicy.mode == .disabled
            ? String(localized: "打开 \(account.name)")
            : String(localized: "先检测出口，通过后打开 \(account.name)")
    }

    private func primaryAction() {
        guard operation == nil else { return }
        if state.isFrozen { onResume() } else { onOpenOrFocus() }
    }

    private var borderAccent: Color? {
        if alert != nil { return DS.Semantic.critical }
        if state.isFrozen {
            return (account.egressPolicy.mode != .disabled && isEgressIncident)
                ? DS.Semantic.caution
                : account.accentColor
        }
        if state.isActive { return account.accentColor }
        return nil
    }

    private var cardTint: Color? {
        if alert != nil { return DS.Semantic.critical }
        if state.isFrozen && account.egressPolicy.mode != .disabled && isEgressIncident {
            return DS.Semantic.caution
        }
        return nil
    }

    // MARK: Context & Overflow Menu Actions

    @ViewBuilder
    private var actionMenuItems: some View {
        Button { primaryAction() } label: {
            Label(primaryTitle, systemImage: state.isFrozen ? "play.fill" : "macwindow")
        }
        .disabled(operation != nil)

        Button { onRefreshQuota() } label: {
            Label("刷新额度", systemImage: "arrow.clockwise")
        }
        .disabled(isRefreshingQuota)

        if let onSignIn, isLoggedOut {
            Button { onSignIn() } label: {
                Label("登录 Claude\u{00A0}Code", systemImage: "terminal")
            }
            .disabled(operation != nil)
        }

        if let onDesktopSignIn {
            Button { onDesktopSignIn() } label: {
                Label("登录 Claude\u{00A0}Desktop…", systemImage: "person.badge.key")
            }
            .disabled(operation != nil)
        }

        if account.egressPolicy.mode != .disabled {
            Button { onPinEgress() } label: {
                Label("把当前出口设为规则", systemImage: "scope")
            }
            .disabled(operation != nil)
        }

        if let onEdit {
            Button { onEdit() } label: {
                Label("编辑账号设置…", systemImage: "slider.horizontal.3")
            }
        }

        if state.isActive {
            Divider()
            if !state.isFrozen {
                Button { onFreeze() } label: {
                    Label("暂停", systemImage: "pause")
                }
                .disabled(operation != nil)
            }
            Button(role: .destructive) { onQuit() } label: {
                Label("退出", systemImage: "xmark")
            }
            .disabled(operation != nil)
        }
    }
}
