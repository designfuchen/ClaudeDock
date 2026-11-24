// FILE: Views/AddAccountSheet.swift
import ClaudeDockCore
import SwiftUI

/// Shared parsing and validation for egress rule text fields across AddAccountSheet and AccountDetailEditor.
enum EgressInput {
    /// Accepts ASCII and Chinese separators (，、；;) so a Chinese input method can't silently break the rule.
    static func splitCSV(_ raw: String) -> [String] {
        raw.split(whereSeparator: { ",，、;；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Validates that every country/region entry is a 2-letter ASCII ISO code.
    static func countryCodeProblem(_ raw: String) -> String? {
        let codes = splitCSV(raw).map { $0.uppercased() }
        let invalid = codes.filter { !($0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isLetter }) }
        guard !invalid.isEmpty else { return nil }
        return String(localized: "国家/地区代码需为两位英文字母（如 SG、JP、US），请检查：\(invalid.joined(separator: "、"))")
    }
}

/// Common exit regions offered as a starting point. Auto-detecting the current proxy is always the first choice;
/// no single region is preferred.
enum RegionPreset: String, CaseIterable, Identifiable {
    case detected
    case usEast, usWest, japan, singapore, uk, germany
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .detected: return String(localized: "使用检测到的出口")
        case .usEast: return String(localized: "美国 · 纽约")
        case .usWest: return String(localized: "美国 · 加州")
        case .japan: return String(localized: "日本 · 东京")
        case .singapore: return String(localized: "新加坡")
        case .uk: return String(localized: "英国 · 伦敦")
        case .germany: return String(localized: "德国 · 法兰克福")
        case .custom: return String(localized: "自定义")
        }
    }

    var values: (country: String, region: String, tz: String)? {
        switch self {
        case .detected, .custom: return nil
        case .usEast: return ("US", "New York", "America/New_York")
        case .usWest: return ("US", "California", "America/Los_Angeles")
        case .japan: return ("JP", "Tokyo", "Asia/Tokyo")
        case .singapore: return ("SG", "Singapore", "Asia/Singapore")
        case .uk: return ("GB", "England", "Europe/London")
        case .germany: return ("DE", "Hesse", "Europe/Berlin")
        }
    }
}

/// Add an account in one short form: name and color, network, done. Everything else is optional and folded away.
struct AddAccountSheet: View {
    @ObservedObject var vm: DockViewModel
    @Environment(\.dismiss) private var dismiss

    // Account
    @State private var name = ""
    @State private var useExistingLogin = false
    @State private var colorHex = AccountProfile.palette[0]

    // Network
    @State private var useProxy = true
    @State private var proxyScheme: ProxyScheme = .http
    @State private var proxyPort = "7897"
    @State private var guardMode: EgressGuardMode = .failClosed
    @State private var preset: RegionPreset = .detected
    @State private var countryCode = ""
    @State private var regionName = ""
    @State private var timezone = ""

    // Probe — only runs when asked, and only fills fields while "use detected" is chosen
    @State private var probeResult: EgressObservation?
    @State private var probeError: String?
    @State private var probeStale = false
    @State private var isProbing = false
    @State private var probeTask: Task<Void, Never>?
    /// Bumped on every new probe or invalidation; only the current generation may publish results.
    @State private var probeGeneration = 0
    @State private var lastProbedScheme: ProxyScheme?
    @State private var lastProbedPort: Int?

    // Advanced
    @State private var showAdvanced = false
    @State private var iconStyle: IconStyle = .claudeBadge
    @State private var watchdogAction: WatchdogAction = .freeze
    @State private var handoffGroup = "default"
    @State private var cliLinked = true

    @State private var errorMessage: String?
    @State private var isCreating = false

    private var defaultAlreadyBound: Bool { vm.accounts.contains(where: \.isDefault) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var portValue: Int? {
        guard let p = Int(proxyPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else { return nil }
        return p
    }
    /// Live name check, so the user learns the rule while typing instead of after pressing Add.
    private var nameProblem: String? {
        guard !trimmedName.isEmpty else { return nil }
        if trimmedName.contains("--") {
            return String(localized: "名称不能包含连续的“--”")
        }
        if (try? Validation.validateAccountName(trimmedName)) == nil {
            return String(localized: "名称仅支持文字、数字、空格、“-”和“_”，最多 30 个字符")
        }
        if vm.accounts.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return String(localized: "已存在同名账号")
        }
        let slug = AccountProfile(name: trimmedName).slug
        if let clash = vm.accounts.first(where: { $0.slug == slug }) {
            return String(localized: "和“\(clash.name)”的终端命令重名（claude-\(slug)），请换个名称")
        }
        return nil
    }

    private var hasRuleValues: Bool {
        !EgressInput.splitCSV(countryCode).isEmpty
            || !EgressInput.splitCSV(regionName).isEmpty
            || !EgressInput.splitCSV(timezone).isEmpty
    }

    private var countryCodeProblem: String? {
        guard useProxy && guardMode != .disabled else { return nil }
        return EgressInput.countryCodeProblem(countryCode)
    }

    /// Under "use detected exit", disallow creating an empty-allowlist guard while probing or after a failed probe.
    private var needsDetectedRule: Bool {
        useProxy && guardMode != .disabled && preset == .detected && (isProbing || !hasRuleValues)
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty
            && nameProblem == nil
            && (!useProxy || portValue != nil)
            && countryCodeProblem == nil
            && !needsDetectedRule
            && !isCreating
    }

    /// Flips preset to `.custom` on user edits so an in-flight or repeated probe never overwrites manual input.
    private func editableRuleBinding(_ storage: Binding<String>) -> Binding<String> {
        Binding(
            get: { storage.wrappedValue },
            set: { newValue in
                storage.wrappedValue = newValue
                if preset == .detected { preset = .custom }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                accountSection
                networkSection
                if useProxy && guardMode != .disabled {
                    ruleSection
                }
                advancedSection
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 520, height: 640)
        .onAppear(perform: prefill)
        .onDisappear { probeTask?.cancel() }
        // A detection describes one specific proxy; changing the proxy makes it meaningless.
        .onChange(of: proxyPort) { _, _ in
            guard portValue != lastProbedPort else { return }
            invalidateProbe()
        }
        .onChange(of: proxyScheme) { _, _ in
            guard proxyScheme != lastProbedScheme else { return }
            invalidateProbe()
        }
        .onChange(of: useProxy) { _, enabled in
            if !enabled {
                probeTask?.cancel()
                probeGeneration += 1
                isProbing = false
            } else if portValue != nil && preset == .detected && probeResult == nil {
                probe()
            }
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(Color(nsColor: IconRenderer.nsColor(fromHex: colorHex) ?? .systemBlue).gradient)
                    .frame(width: 40, height: 40)
                Text(trimmedName.isEmpty ? "?" : String(trimmedName.prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .animation(DS.Motion.quick, value: colorHex)
            VStack(alignment: .leading, spacing: 2) {
                Text("添加账号")
                    .font(.system(size: 17, weight: .semibold))
                Text("每个账号使用独立的 Claude 窗口，登录状态互不影响。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.top, DS.Space.xl)
        .padding(.bottom, DS.Space.s)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: DS.Space.s) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("仅添加") { create(openAfter: false) }
                    .disabled(!canCreate)
                Button("添加并打开") { create(openAfter: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.l)
    }

    // MARK: Sections

    private var accountSection: some View {
        Section {
            TextField("名称", text: $name, prompt: Text("如工作、个人、Pro-2"))
            if let nameProblem {
                Text(nameProblem)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            LabeledContent("颜色") {
                HStack(spacing: 7) {
                    ForEach(AccountProfile.palette, id: \.self) { hex in
                        let selected = colorHex == hex
                        Button {
                            colorHex = hex
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
            if !defaultAlreadyBound {
                Toggle(isOn: $useExistingLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("使用这台 Mac 上已经登录的 Claude")
                        Text("无需重新登录。若不勾选，将新建独立账号，打开后需单独登录。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("账号")
        }
    }

    private var networkSection: some View {
        Section {
            Toggle("使用独立代理", isOn: $useProxy)
            if useProxy {
                Picker("协议", selection: $proxyScheme) {
                    Text("HTTP").tag(ProxyScheme.http)
                    Text("SOCKS5").tag(ProxyScheme.socks5)
                }
                TextField("端口", text: $proxyPort, prompt: Text("7897"))
                if portValue == nil {
                    Text("端口需在 1–65535 之间")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                Picker("出口检查", selection: $guardMode) {
                    Text("不符合时阻止（推荐）").tag(EgressGuardMode.failClosed)
                    Text("不符合时提醒").tag(EgressGuardMode.warnOnly)
                    Text("不检查").tag(EgressGuardMode.disabled)
                }
            }
        } header: {
            Text("网络")
        } footer: {
            if let shared = accountsSharingPort {
                FooterText(String(localized: "和\(shared)共用同一个代理端口：在代理软件里切换节点，会同时改变它们的出口。想让账号固定走不同节点，可以在“连接与守护”里生成多端口配置。"))
            } else if useProxy {
                FooterText(vm.clashInfo.map { String(localized: "已找到 Clash Verge，端口 \($0.mixedPort) 已填好。") } ?? String(localized: "填写本机代理软件的端口，例如 Clash 默认是 7897。"))
            } else {
                FooterText(String(localized: "不使用代理时，这个账号走系统网络，不做出口检查。"))
            }
        }
    }

    private var ruleSection: some View {
        Section {
            HStack {
                Button {
                    probe()
                } label: {
                    if isProbing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("检测中…") }
                    } else {
                        Label("检测当前出口", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(isProbing || portValue == nil)
                Spacer()
                if let probeError {
                    Label(probeError, systemImage: probeStale ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let probeResult {
                    Label("\(probeResult.locationLabel) · \(probeResult.maskedIP)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            }
            Picker("允许的出口", selection: $preset) {
                ForEach(RegionPreset.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .onChange(of: preset) { _, newValue in applyPreset(newValue) }
            TextField("国家/地区代码", text: editableRuleBinding($countryCode), prompt: Text("两位代码，如 SG、JP、DE"))
                .disabled(preset != .custom && preset != .detected)
            if let countryCodeProblem {
                Text(countryCodeProblem)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            TextField("州/省", text: editableRuleBinding($regionName), prompt: Text("选填"))
                .disabled(preset != .custom && preset != .detected)
            TextField("时区", text: editableRuleBinding($timezone), prompt: Text("IANA 时区，如 Asia/Tokyo、Europe/London"))
                .disabled(preset != .custom && preset != .detected)
        } header: {
            Text("出口规则")
        } footer: {
            FooterText(ruleFooter)
        }
    }

    /// Names of existing accounts that use the same local proxy port as this form.
    private var accountsSharingPort: String? {
        guard useProxy, let p = portValue else { return nil }
        let names = vm.accounts.filter { $0.proxy.enabled && $0.proxy.port == p }.map { "“\($0.name)”" }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private var ruleFooter: String {
        if !hasRuleValues {
            if preset == .detected {
                if isProbing {
                    return String(localized: "正在检测当前代理出口，完成后会自动填入规则。")
                }
                return String(localized: "还没有检测到可用出口。请先确认代理已连通再重试，或切换为预设地区 / 自定义规则（自定义留空时仅检查代理连通性）。")
            }
            return String(localized: "还没有规则：打开时只确认代理能连通。")
        }
        let regions = EgressInput.splitCSV(regionName)
        let countries = EgressInput.splitCSV(countryCode).map { $0.uppercased() }
        let parts = (regions + countries).joined(separator: ", ")
        if parts.isEmpty {
            return guardMode == .warnOnly
                ? String(localized: "出口不在指定地区时会提醒你，但仍会打开这个账号。")
                : String(localized: "只有出口在指定地区时才允许打开这个账号。")
        }
        return guardMode == .warnOnly
            ? String(localized: "出口不在 \(parts) 时会提醒你，但仍会打开这个账号。")
            : String(localized: "只有出口在 \(parts) 时才允许打开这个账号。")
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("更多选项", isExpanded: $showAdvanced) {
                Picker("启动器图标", selection: $iconStyle) {
                    Text("Claude 图标 + 彩色角标").tag(IconStyle.claudeBadge)
                    Text("彩色字母").tag(IconStyle.letter)
                }
                if useProxy && guardMode != .disabled {
                    Picker("运行中出口不符合规则时", selection: $watchdogAction) {
                        Text("暂停这个账号（推荐）").tag(WatchdogAction.freeze)
                        Text("仅发送提醒").tag(WatchdogAction.notify)
                        Text("退出").tag(WatchdogAction.quit)
                    }
                }
                TextField("分组", text: $handoffGroup, prompt: Text("default"))
                Toggle("启用终端命令 claude-\(previewSlug)", isOn: $cliLinked)
            }
        }
    }

    private var previewSlug: String {
        AccountProfile(name: trimmedName.isEmpty ? "account" : trimmedName).slug
    }

    // MARK: Behaviour

    private func prefill() {
        if vm.accounts.isEmpty {
            name = String(localized: "主账号")
        } else {
            var n = vm.accounts.count + 1
            while vm.accounts.contains(where: { $0.name.caseInsensitiveCompare(String(localized: "账号 \(n)")) == .orderedSame }) {
                n += 1
            }
            name = String(localized: "账号 \(n)")
        }
        if vm.accounts.isEmpty && !defaultAlreadyBound { useExistingLogin = true }
        let usedColors = Set(vm.accounts.map(\.colorHex))
        colorHex = AccountProfile.palette.first(where: { !usedColors.contains($0) })
            ?? AccountProfile.palette[vm.accounts.count % AccountProfile.palette.count]
        useProxy = vm.clashInfo != nil || vm.accounts.contains(where: \.proxy.enabled)
        if let port = vm.clashInfo?.mixedPort { proxyPort = "\(port)" }
        // Start from the real exit right away, so "use the detected exit" is never an empty rule by accident.
        // A region the user picks by hand is never overwritten (see probe()).
        DispatchQueue.main.async { if useProxy && portValue != nil { probe() } }
    }

    private func invalidateProbe() {
        probeTask?.cancel()
        probeGeneration += 1
        isProbing = false
        probeError = nil
        probeResult = nil
        probeStale = false
        lastProbedScheme = nil
        lastProbedPort = nil
        // Detected values described the old proxy; hand-picked presets are kept.
        if preset == .detected {
            countryCode = ""
            regionName = ""
            timezone = ""
        }
    }

    private func applyPreset(_ p: RegionPreset) {
        if let v = p.values {
            countryCode = v.country
            regionName = v.region
            timezone = v.tz
        } else if p == .detected {
            // Never let a previous preset pose as a detection result.
            if let obs = probeResult {
                fill(from: obs)
            } else {
                countryCode = ""
                regionName = ""
                timezone = ""
            }
        }
    }

    private func fill(from obs: EgressObservation) {
        countryCode = obs.country ?? ""
        regionName = obs.region ?? ""
        timezone = obs.timezone ?? ""
    }

    private func probe() {
        guard let port = portValue else { return }
        let scheme = proxyScheme
        let proxy = ProxyConfig(enabled: true, scheme: scheme, host: "127.0.0.1", port: port)
        lastProbedScheme = scheme
        lastProbedPort = port
        isProbing = true
        probeError = nil
        probeTask?.cancel()
        probeGeneration += 1
        let generation = probeGeneration
        probeTask = Task {
            // A cancelled, superseded probe must not flip the newer probe's spinner off.
            defer { if generation == probeGeneration { isProbing = false } }
            do {
                let obs = try await vm.controller.egressProber.probe(proxy: proxy, timeoutSeconds: 4.5)
                guard !Task.isCancelled, generation == probeGeneration else { return }
                probeResult = obs
                probeStale = false
                // Never overwrite a region the user picked by hand.
                if preset == .detected { fill(from: obs) }
            } catch {
                guard !Task.isCancelled, generation == probeGeneration else { return }
                if let previous = probeResult {
                    probeStale = true
                    probeError = String(localized: "重新检测失败，仍保留上次检测到的 \(previous.locationLabel)")
                } else {
                    probeStale = false
                    if preset == .detected {
                        countryCode = ""
                        regionName = ""
                        timezone = ""
                    }
                    probeError = String(localized: "通过端口 \(port) 检测出口失败：确认代理软件已打开，且当前节点能连通")
                }
            }
        }
    }

    private func create(openAfter: Bool) {
        guard canCreate else { return }
        isCreating = true
        defer { isCreating = false }
        let countries = EgressInput.splitCSV(countryCode).map { $0.uppercased() }
        let regions = EgressInput.splitCSV(regionName)
        let timezones = EgressInput.splitCSV(timezone)
        let port = portValue ?? 7897

        let proxy = ProxyConfig(
            enabled: useProxy,
            scheme: proxyScheme,
            host: "127.0.0.1",
            port: port,
            timezone: timezones.first,
            language: "en-US"
        )
        let mode: EgressGuardMode = useProxy ? guardMode : .disabled
        let policy = mode == .disabled ? EgressPolicy(mode: .disabled) : EgressPolicy(
            mode: mode,
            allowedCountries: countries,
            allowedRegions: regions,
            allowedTimezones: timezones,
            watchdogEnabled: true,
            watchdogAction: watchdogAction
        )
        let group = handoffGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try vm.addAccount(
                name: trimmedName,
                isDefault: useExistingLogin && !defaultAlreadyBound,
                iconStyle: iconStyle,
                colorHex: colorHex,
                proxy: proxy,
                egressPolicy: policy,
                handoffGroup: group.isEmpty ? nil : group,
                cliLinked: cliLinked
            )
            dismiss()
            if openAfter, let created = vm.accounts.first(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
                // A new, separate account must sign in; with other Claude windows open, use the sign-in assistant
                // so the browser's callback can't land in the wrong window.
                if !created.isDefault && !vm.otherRunningAccounts(than: created).isEmpty {
                    // Present after the sheet has finished closing; same-frame presentation can be dropped.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { vm.pendingConfirmation = .guidedSignIn(created) }
                } else {
                    vm.openOrFocus(account: created)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
