// FILE: Views/QuotaViews.swift
import ClaudeDockCore
import SwiftUI

// Quota is the number people switch accounts by, so it is always shown as what is LEFT,
// with the reset time in plain words — never as a bare "used %".

enum QuotaFormat {
    /// Color for a remaining percentage: plenty, getting low, nearly out.
    static func tone(remaining: Double) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 30 { return .orange }
        return .green
    }

    /// True only when the reading is fresh (not expired) and confirmed near-zero usage.
    static func isConfirmedRecovered(_ window: QuotaWindow, now: Date) -> Bool {
        !window.isExpired(at: now) && window.usedPercentage <= 0.5
    }

    /// "还有 29 分钟 · 本地时间 16:00" / "还有 2 小时 14 分 · 本地时间 明天 09:00" / "还有 3 天 · 本地时间 周五 16:00".
    static func resetText(_ window: QuotaWindow, now: Date) -> String {
        guard window.resetsAt > 0 else { return String(localized: "重置时间未知") }
        let delta = Int(TimeInterval(window.resetsAt) - now.timeIntervalSince1970)
        if window.isExpired(at: now) || delta <= 0 { return String(localized: "已到重置时间 · 等待刷新确认") }
        let countdown = shortReset(window, now: now)
        let clock = resetClock(window, now: now)
        return clock.isEmpty ? countdown : String(localized: "\(countdown) · 本地时间 \(clock)")
    }

    /// Compact fallback for narrow two-column layouts: "还有 29 分钟 · 16:00" / "还有 2 小时 14 分 · 明天 09:00".
    static func compactResetText(_ window: QuotaWindow, now: Date) -> String {
        guard window.resetsAt > 0 else { return String(localized: "重置时间未知") }
        let delta = Int(TimeInterval(window.resetsAt) - now.timeIntervalSince1970)
        if window.isExpired(at: now) || delta <= 0 { return String(localized: "已到重置时间 · 等待刷新确认") }
        let countdown = shortReset(window, now: now)
        let clock = resetClock(window, now: now)
        return clock.isEmpty ? countdown : "\(countdown) · \(clock)"
    }

    /// "还有 29 分钟" / "还有 2 小时 14 分" / "还有 3 天" (empty when unknown; "等待刷新" when passed).
    static func shortReset(_ window: QuotaWindow, now: Date) -> String {
        guard window.resetsAt > 0 else { return "" }
        let delta = Int(TimeInterval(window.resetsAt) - now.timeIntervalSince1970)
        if window.isExpired(at: now) || delta <= 0 { return String(localized: "等待刷新") }
        if delta < 3600 { return String(localized: "还有 \(max(1, delta / 60)) 分钟") }
        if delta < 86400 {
            let h = delta / 3600, m = (delta % 3600) / 60
            return m == 0 ? String(localized: "还有 \(h) 小时") : String(localized: "还有 \(h) 小时 \(m) 分")
        }
        return String(localized: "还有 \(delta / 86400) 天")
    }

    /// "16:00" / "明天 09:00" / "周五 16:00" (24-hour HH:mm in TimeZone.current).
    static func resetClock(_ window: QuotaWindow, now: Date) -> String {
        guard window.resetsAt > 0 else { return "" }
        let reset = Date(timeIntervalSince1970: TimeInterval(window.resetsAt))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let hm = hourMinuteString(reset, calendar: calendar)
        let dayDiff = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: reset)
        ).day ?? 0
        if dayDiff == 0 { return hm }
        if dayDiff == 1 { return String(localized: "明天 \(hm)") }
        let weekdayIndex = calendar.component(.weekday, from: reset)
        let weekday = (1...7).contains(weekdayIndex) ? zhWeekdays[weekdayIndex - 1] : ""
        return weekday.isEmpty ? hm : "\(weekday) \(hm)"
    }

    /// "额度更新于 刚刚" / "额度更新于 3 分钟前" / "额度更新于 2 小时前" / "额度更新于 11月23日 14:02".
    static func updatedText(_ checkedAt: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(checkedAt))
        if seconds < 45 { return String(localized: "额度更新于 刚刚") }
        if seconds < 3600 { return String(localized: "额度更新于 \(max(1, seconds / 60)) 分钟前") }
        if seconds < 86400 { return String(localized: "额度更新于 \(seconds / 3600) 小时前") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: checkedAt)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return String(localized: "额度更新于 \(c.month ?? 1)月\(c.day ?? 1)日 \(hm)")
    }

    private static let zhWeekdays = [
        String(localized: "周日"),
        String(localized: "周一"),
        String(localized: "周二"),
        String(localized: "周三"),
        String(localized: "周四"),
        String(localized: "周五"),
        String(localized: "周六"),
    ]

    private static func hourMinuteString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// One usage window as a labelled meter: "5 小时   剩 58%   ▓▓▓▓▓▓░░░░   还有 2 小时 14 分 · 本地时间 16:00".
struct QuotaMeter: View {
    let title: String
    let window: QuotaWindow
    let now: Date
    @State private var grown = false

    private var isExpired: Bool { window.isExpired(at: now) }
    private var isRecovered: Bool { QuotaFormat.isConfirmedRecovered(window, now: now) }
    private var remaining: Double { max(0, min(100, window.remainingPercentage)) }

    private var remainingWord: some View {
        Text("剩")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    var body: some View {
        let tone: Color = QuotaFormat.tone(remaining: remaining)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if isExpired {
                    Text("待刷新")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if isRecovered {
                    Text("已恢复")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    // "剩 52%" in Chinese, "52% left" in English: the word's position follows the UI language.
                    let wordFirst = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? true
                    HStack(alignment: .firstTextBaseline, spacing: wordFirst ? 2 : 3) {
                        if wordFirst { remainingWord }
                        Text("\(Int(remaining.rounded()))%")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(remaining <= 30 ? tone : .primary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        if !wordFirst { remainingWord }
                    }
                }
            }
            .frame(minHeight: 20, alignment: .bottom)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if !isExpired, remaining > 0 {
                        let fillWidth = grown ? min(geo.size.width, max(6, geo.size.width * remaining / 100)) : 0
                        Capsule()
                            .fill(tone.gradient)
                            .frame(width: fillWidth)
                    }
                }
            }
            .frame(height: 6)
            .onAppear {
                withAnimation(DS.Motion.reduceMotion ? nil : DS.Motion.gentle.delay(0.1)) { grown = true }
            }

            if isExpired {
                Text("已到重置时间 · 等待刷新确认")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                ViewThatFits(in: .horizontal) {
                    Text(QuotaFormat.resetText(window, now: now))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(QuotaFormat.compactResetText(window, now: now))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(QuotaFormat.resetText(window, now: now))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .animation(DS.Motion.standard, value: remaining)
        .animation(DS.Motion.standard, value: isExpired)
    }

    private var accessibilityText: String {
        if isExpired {
            return String(localized: "\(title)额度待刷新，已到重置时间 · 等待刷新确认")
        }
        if isRecovered {
            return String(localized: "\(title)额度已恢复，\(QuotaFormat.resetText(window, now: now))")
        }
        return String(localized: "\(title)额度剩余 \(Int(remaining.rounded()))%，\(QuotaFormat.resetText(window, now: now))")
    }
}

/// Compact ring showing the tightest remaining quota of an account. Used where space is short (menu bar, lists).
struct QuotaRing: View {
    let quota: QuotaSnapshot?
    let now: Date
    var size: CGFloat = 30
    @State private var grown = false

    private enum RingState: Equatable {
        case pending
        case value(Double)
        case unknown
    }

    private var ringState: RingState {
        guard let quota else { return .unknown }
        let windows = [quota.fiveHour, quota.sevenDay].compactMap { $0 }
        guard !windows.isEmpty else {
            if let remaining = quota.effectiveHeadroom(at: now) {
                return .value(max(0, min(100, remaining)))
            }
            return .unknown
        }
        let unexpiredMin = windows.filter { !$0.isExpired(at: now) }.map(\.remainingPercentage).min()
        let expiredMin = windows.filter { $0.isExpired(at: now) }.map(\.remainingPercentage).min()
        switch (unexpiredMin, expiredMin) {
        case (let u?, nil):
            return .value(max(0, min(100, u)))
        case (let u?, let e?) where u <= e:
            return .value(max(0, min(100, u)))
        default:
            return .pending
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: size * 0.11)
            switch ringState {
            case .value(let remaining):
                if remaining > 0 {
                    Circle()
                        .trim(from: 0, to: grown ? max(0.02, remaining / 100) : 0)
                        .stroke(QuotaFormat.tone(remaining: remaining).gradient,
                                style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text("\(Int(remaining.rounded()))")
                    .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            case .pending:
                Text("…")
                    .font(.system(size: size * 0.34, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            case .unknown:
                Text("—")
                    .font(.system(size: size * 0.34, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(DS.Motion.reduceMotion ? nil : DS.Motion.gentle.delay(0.05)) { grown = true }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .animation(DS.Motion.standard, value: ringState)
    }

    private var accessibilityText: String {
        switch ringState {
        case .pending: return String(localized: "额度待刷新")
        case .unknown: return String(localized: "额度未知")
        case .value(let remaining):
            if let quota {
                let windows = [quota.fiveHour, quota.sevenDay].compactMap { $0 }
                if !windows.isEmpty && windows.allSatisfy({ QuotaFormat.isConfirmedRecovered($0, now: now) }) {
                    return String(localized: "额度已恢复")
                }
            }
            return String(localized: "剩余额度 \(Int(remaining.rounded()))%")
        }
    }
}

/// One-line quota summary: "5h 剩 58% · 7d 剩 81%", or why there is none.
struct QuotaInline: View {
    let quota: QuotaSnapshot?
    let now: Date

    var body: some View {
        if let q = quota, q.fiveHour != nil || q.sevenDay != nil {
            ViewThatFits(in: .horizontal) {
                inlineRow(q, showFiveHourReset: true, showSevenDayReset: true, fixed: true)
                inlineRow(
                    q,
                    showFiveHourReset: isTighterFiveHour(q),
                    showSevenDayReset: !isTighterFiveHour(q),
                    fixed: true
                )
                inlineRow(q, showFiveHourReset: false, showSevenDayReset: false, fixed: true)
                inlineRow(q, showFiveHourReset: false, showSevenDayReset: false, fixed: false)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.system(size: 11))
            .monospacedDigit()
        } else {
            Text(QuotaCopy.missing(quota))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func isTighterFiveHour(_ q: QuotaSnapshot) -> Bool {
        guard let fh = q.fiveHour else { return false }
        guard let sd = q.sevenDay else { return true }
        if fh.isExpired(at: now) { return false }
        if sd.isExpired(at: now) { return true }
        let fhRem = max(0, min(100, fh.remainingPercentage))
        let sdRem = max(0, min(100, sd.remainingPercentage))
        return fhRem <= sdRem
    }

    @ViewBuilder
    private func inlineRow(
        _ q: QuotaSnapshot,
        showFiveHourReset: Bool,
        showSevenDayReset: Bool,
        fixed: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if let fh = q.fiveHour {
                part("5h", fh, showReset: showFiveHourReset, fixed: fixed)
            }
            if q.fiveHour != nil && q.sevenDay != nil {
                Text("·").foregroundStyle(.secondary)
            }
            if let sd = q.sevenDay {
                part("7d", sd, showReset: showSevenDayReset, fixed: fixed)
            }
        }
    }

    @ViewBuilder
    private func part(_ label: String, _ w: QuotaWindow, showReset: Bool, fixed: Bool) -> some View {
        let remaining = max(0, min(100, w.remainingPercentage))
        let expired = w.isExpired(at: now)
        let recovered = QuotaFormat.isConfirmedRecovered(w, now: now)
        let row = HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            if expired {
                Text("待刷新").foregroundStyle(.secondary)
            } else if recovered {
                Text("已恢复").foregroundStyle(.green)
            } else {
                // When it's low, say how soon it comes back — that decides "wait" vs "switch".
                let pct = Int(remaining.rounded())
                let soon = (showReset && remaining <= 30) ? QuotaFormat.shortReset(w, now: now) : ""
                Text(soon.isEmpty ? String(localized: "剩 \(pct)%") : String(localized: "剩 \(pct)%（\(soon)）"))
                    .foregroundStyle(remaining <= 30 ? QuotaFormat.tone(remaining: remaining) : .primary)
            }
        }
        if fixed {
            row.fixedSize()
        } else {
            row
        }
    }
}

enum QuotaCopy {
    static func missing(_ quota: QuotaSnapshot?) -> String {
        guard let q = quota else { return String(localized: "尚未获取额度") }
        switch q.status {
        case .loggedOut: return String(localized: "Claude Code 未登录，无法获取额度")
        case .error: return String(localized: "额度读取失败")
        case .notApplicable: return String(localized: "这个账号没有用量上限")
        case .unavailable: return String(localized: "暂无法获取额度")
        default: return String(localized: "尚未获取额度")
        }
    }
}

/// Full quota block for an account card: both meters side by side plus where the numbers came from.
struct QuotaPanel: View {
    let quota: QuotaSnapshot?
    let now: Date
    let isRefreshing: Bool
    let onRefresh: () -> Void
    var onSignIn: (() -> Void)?

    @State private var spinAngle: Double = 0

    init(
        quota: QuotaSnapshot?,
        now: Date,
        isRefreshing: Bool,
        onRefresh: @escaping () -> Void,
        onSignIn: (() -> Void)? = nil
    ) {
        self.quota = quota
        self.now = now
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.onSignIn = onSignIn
    }

    var body: some View {
        if quota?.status == .loggedOut, quota?.fiveHour == nil, quota?.sevenDay == nil, let onSignIn {
            signInPrompt(onSignIn)
        } else if let q = quota, q.fiveHour != nil || q.sevenDay != nil {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .top, spacing: DS.Space.l) {
                    if let fh = q.fiveHour { QuotaMeter(title: String(localized: "5 小时"), window: fh, now: now) }
                    if let sd = q.sevenDay { QuotaMeter(title: String(localized: "7 天"), window: sd, now: now) }
                }
                HStack(spacing: 4) {
                    if q.status == .error || q.status == .cached || q.status == .loggedOut {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    Text(provenance(q))
                    Spacer()
                    // Signed out but showing old meters: the way back in must still be one click away.
                    if q.status == .loggedOut, let onSignIn {
                        Button("登录 Claude\u{00A0}Code", action: onSignIn)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    if q.status != .loggedOut {
                        refreshButton
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        } else {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.secondary)
                Text(QuotaCopy.missing(quota))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if quota?.status != .notApplicable && quota?.status != .loggedOut {
                    Button(isRefreshing ? String(localized: "读取中…") : String(localized: "读取额度"), action: onRefresh)
                        .buttonStyle(.dsSecondary())
                        .controlSize(.small)
                        .disabled(isRefreshing)
                }
            }
            .padding(.vertical, DS.Space.xs)
        }
    }

    /// Claude Desktop being signed in is not enough: quota is read through Claude Code, which signs in separately.
    private func signInPrompt(_ action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("尚未获取额度")
                    .font(DS.Typo.headline)
                Text("需要先登录这个账号的 Claude\u{00A0}Code")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            Button("登录 Claude\u{00A0}Code", action: action)
                .buttonStyle(.dsSecondary())
                .controlSize(.small)
                .help("打开终端，用这个账号自己的设置和代理登录。登录后回到这里会自动读取额度。")
        }
        .padding(DS.Space.m)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Group {
                if isRefreshing && DS.Motion.reduceMotion {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(spinAngle))
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(isRefreshing)
        .help("刷新额度（不消耗用量）")
        .accessibilityLabel("刷新额度")
        .task(id: isRefreshing) {
            if isRefreshing && !DS.Motion.reduceMotion {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { spinAngle = 0 }
                await Task.yield()
                guard !Task.isCancelled, isRefreshing else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    spinAngle = 360
                }
            } else {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { spinAngle = 0 }
            }
        }
    }

    private func provenance(_ q: QuotaSnapshot) -> String {
        let updated = QuotaFormat.updatedText(q.checkedAt, now: now)
        switch q.status {
        case .error: return String(localized: "上次读取失败 · \(updated)")
        case .cached, .loggedOut: return String(localized: "缓存 · \(updated)")
        default: return updated
        }
    }
}
