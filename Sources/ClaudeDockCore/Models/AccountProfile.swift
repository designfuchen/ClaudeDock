import Foundation

public enum IconStyle: Codable, Equatable, Hashable, Sendable {
    case claudeBadge
    case letter
    case image(path: String)

    private enum CodingKeys: String, CodingKey {
        case type, path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "claudeBadge": self = .claudeBadge
        case "letter": self = .letter
        case "image":
            let path = try container.decode(String.self, forKey: .path)
            self = .image(path: path)
        default:
            self = .claudeBadge
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claudeBadge:
            try container.encode("claudeBadge", forKey: .type)
        case .letter:
            try container.encode("letter", forKey: .type)
        case .image(let path):
            try container.encode("image", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }

    public var cliLabel: String {
        switch self {
        case .claudeBadge: return "claude"
        case .letter: return "letter"
        case .image(let path): return path
        }
    }
}

public enum ProxyScheme: String, Codable, CaseIterable, Sendable {
    case http
    case socks5
}

public struct ProxyConfig: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var scheme: ProxyScheme
    public var host: String
    public var port: Int
    public var bypassList: String
    public var timezone: String?
    public var language: String?
    public var clashNodeName: String?

    public init(
        enabled: Bool = true,
        scheme: ProxyScheme = .http,
        host: String = "127.0.0.1",
        port: Int = 7897,
        bypassList: String = "localhost,127.0.0.1,::1",
        timezone: String? = nil,
        language: String? = nil,
        clashNodeName: String? = nil
    ) {
        self.enabled = enabled
        self.scheme = scheme
        self.host = host
        self.port = port
        self.bypassList = bypassList
        self.timezone = timezone
        self.language = language
        self.clashNodeName = clashNodeName
    }

    public var proxyURLString: String {
        "\(scheme.rawValue)://\(host):\(port)"
    }

    /// Electron `--proxy-server` format.
    public var electronProxyArg: String {
        switch scheme {
        case .http: return "http://\(host):\(port)"
        case .socks5: return "socks5://\(host):\(port)"
        }
    }
}

public enum EgressGuardMode: String, Codable, CaseIterable, Sendable {
    /// No egress verification before launch.
    case disabled
    /// Probe egress and warn on mismatch, but allow launch.
    case warnOnly
    /// Strictly block launch if proxy is unreachable or exit IP/Region violates policy.
    case failClosed
}

public enum WatchdogAction: String, Codable, CaseIterable, Sendable {
    /// Show critical macOS notification and turn status badge red.
    case notify
    /// Send SIGSTOP to freeze the Claude process tree so zero packets leak over the wrong IP.
    case freeze
    /// Gracefully terminate the affected Claude process.
    case quit
}

public struct EgressPolicy: Codable, Equatable, Hashable, Sendable {
    public var mode: EgressGuardMode
    public var pinnedIP: String?
    public var pinnedIPPrefix: String?
    public var allowedCountries: [String]
    public var allowedRegions: [String]
    public var allowedCities: [String]
    public var allowedTimezones: [String]
    public var watchdogEnabled: Bool
    public var watchdogAction: WatchdogAction

    public init(
        mode: EgressGuardMode = .disabled,
        pinnedIP: String? = nil,
        pinnedIPPrefix: String? = nil,
        allowedCountries: [String] = [],
        allowedRegions: [String] = [],
        allowedCities: [String] = [],
        allowedTimezones: [String] = [],
        watchdogEnabled: Bool = true,
        watchdogAction: WatchdogAction = .freeze
    ) {
        self.mode = mode
        self.pinnedIP = pinnedIP
        self.pinnedIPPrefix = pinnedIPPrefix
        self.allowedCountries = allowedCountries
        self.allowedRegions = allowedRegions
        self.allowedCities = allowedCities
        self.allowedTimezones = allowedTimezones
        self.watchdogEnabled = watchdogEnabled
        self.watchdogAction = watchdogAction
    }


    public var hasRules: Bool {
        (pinnedIP?.isEmpty == false) ||
        (pinnedIPPrefix?.isEmpty == false) ||
        !allowedCountries.isEmpty ||
        !allowedRegions.isEmpty ||
        !allowedCities.isEmpty ||
        !allowedTimezones.isEmpty
    }

    public var summaryText: String {
        if mode == .disabled { return "Off" }
        var parts: [String] = []
        if let ip = pinnedIP, !ip.isEmpty { parts.append("IP:\(ip)") }
        if let pfx = pinnedIPPrefix, !pfx.isEmpty { parts.append("Prefix:\(pfx)*") }
        if !allowedRegions.isEmpty { parts.append(allowedRegions.joined(separator: "/")) }
        else if !allowedCountries.isEmpty { parts.append(allowedCountries.joined(separator: "/")) }
        if !allowedCities.isEmpty { parts.append(allowedCities.joined(separator: "/")) }
        if parts.isEmpty { return "Proxy Alive Only" }
        return parts.joined(separator: " · ")
    }
}

public struct EgressObservation: Codable, Equatable, Hashable, Sendable {
    public var ip: String
    public var city: String?
    public var region: String?
    public var country: String?
    public var timezone: String?
    public var org: String?
    public var provider: String
    public var checkedAt: Date
    /// The proxy (`scheme://host:port`) this observation was measured through. Nil for legacy records.
    public var proxyKey: String?

    public init(
        ip: String,
        city: String? = nil,
        region: String? = nil,
        country: String? = nil,
        timezone: String? = nil,
        org: String? = nil,
        provider: String = "unknown",
        checkedAt: Date = Date(),
        proxyKey: String? = nil
    ) {
        self.proxyKey = proxyKey
        self.ip = ip
        self.city = city
        self.region = region
        self.country = country
        self.timezone = timezone
        self.org = org
        self.provider = provider
        self.checkedAt = checkedAt
    }

    public var locationLabel: String {
        let items = [city, region, country].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return items.isEmpty ? ip : items.joined(separator: ", ")
    }

    public var maskedIP: String {
        let octets = ip.split(separator: ".")
        if octets.count == 4 {
            return "\(octets[0]).\(octets[1]).*.*"
        }
        return ip
    }
}

public enum EgressVerdict: Equatable, Sendable {
    case allowed(EgressObservation)
    case skipped
    case blocked(reason: String, observation: EgressObservation?)

    public var isAllowed: Bool {
        switch self {
        case .allowed, .skipped: return true
        case .blocked: return false
        }
    }
}

public struct ObservedIdentity: Codable, Equatable, Hashable, Sendable {
    public var email: String?
    /// The person's name as shown in Claude (display name, falling back to full name). Nil if unknown.
    public var displayName: String?
    public var organizationID: String?
    public var accountUUID: String?
    public var planType: String?
    public var loggedIn: Bool
    public var source: String
    public var observedAt: Date

    public init(
        email: String? = nil,
        displayName: String? = nil,
        organizationID: String? = nil,
        accountUUID: String? = nil,
        planType: String? = nil,
        loggedIn: Bool = false,
        source: String = "unknown",
        observedAt: Date = Date()
    ) {
        self.email = email
        self.displayName = displayName
        self.organizationID = organizationID
        self.accountUUID = accountUUID
        self.planType = planType
        self.loggedIn = loggedIn
        self.source = source
        self.observedAt = observedAt
    }

    public var subjectHash: String? {
        guard loggedIn, let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty else {
            return nil
        }
        let org = (organizationID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256Helper.hex("\(email)\n\(org)")
    }
}

public struct QuotaWindow: Codable, Equatable, Hashable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Int64 // Unix timestamp; 0 if unknown
    public var observedAt: Int64

    public init(usedPercentage: Double, resetsAt: Int64, observedAt: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.usedPercentage = max(0, min(100, usedPercentage))
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    public var remainingPercentage: Double {
        max(0, 100.0 - usedPercentage)
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        resetsAt > 0 && Int64(now.timeIntervalSince1970) >= resetsAt
    }

    public func resetCountdownString(at now: Date = Date()) -> String {
        guard resetsAt > 0 else { return "—" }
        let delta = Int(resetsAt - Int64(now.timeIntervalSince1970))
        if delta <= 0 { return "Resetting" }
        let days = delta / 86400
        let hours = (delta % 86400) / 3600
        let minutes = (delta % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }
}

public enum QuotaStatus: String, Codable, Equatable, Hashable, Sendable {
    case unknown
    case reported
    case partial
    case cached
    case unavailable
    case notApplicable
    case loggedOut
    case error
}

public struct QuotaSnapshot: Codable, Equatable, Hashable, Sendable {
    public var fiveHour: QuotaWindow?
    public var sevenDay: QuotaWindow?
    public var status: QuotaStatus
    public var identityHash: String?
    public var checkedAt: Date
    public var errorMessage: String?

    public init(
        fiveHour: QuotaWindow? = nil,
        sevenDay: QuotaWindow? = nil,
        status: QuotaStatus = .unknown,
        identityHash: String? = nil,
        checkedAt: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.status = status
        self.identityHash = identityHash
        self.checkedAt = checkedAt
        self.errorMessage = errorMessage
    }

    /// Bottleneck remaining percentage across active non-expired windows.
    public func effectiveHeadroom(at now: Date = Date()) -> Double? {
        var values: [Double] = []
        if let fh = fiveHour, !fh.isExpired(at: now) { values.append(fh.remainingPercentage) }
        if let sd = sevenDay, !sd.isExpired(at: now) { values.append(sd.remainingPercentage) }
        return values.min()
    }
}

public struct AccountProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isDefault: Bool
    /// Folder name under ~/Library/Application Support (e.g. "Claude" or "Claude-NY1").
    /// Never renamed when launcher display name changes so sign-in and cookies stay intact.
    public var dataDirName: String
    /// Folder name under ~/.claudedock/cli-profiles holding this account's Claude Code login (CLAUDE_CONFIG_DIR).
    /// Fixed for the account's lifetime and normally its `id`, so renames never move or split the login.
    /// nil only for profiles saved by older versions, which still use the name-derived slug until migrated.
    public var cliDirName: String?
    public var iconStyle: IconStyle
    public var colorHex: String
    public var sortOrder: Int
    public var enabled: Bool
    public var handoffGroup: String?
    public var proxy: ProxyConfig
    public var egressPolicy: EgressPolicy
    public var cliLinked: Bool
    public var identity: ObservedIdentity?
    public var quota: QuotaSnapshot?
    public var lastEgress: EgressObservation?
    public var notes: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        isDefault: Bool = false,
        dataDirName: String? = nil,
        cliDirName: String? = nil,
        iconStyle: IconStyle = .claudeBadge,
        colorHex: String? = nil,
        sortOrder: Int = 0,
        enabled: Bool = true,
        handoffGroup: String? = "default",
        proxy: ProxyConfig = ProxyConfig(enabled: false),
        egressPolicy: EgressPolicy = EgressPolicy(),
        cliLinked: Bool = true,
        identity: ObservedIdentity? = nil,
        quota: QuotaSnapshot? = nil,
        lastEgress: EgressObservation? = nil,
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.dataDirName = dataDirName ?? (isDefault ? "Claude" : "Claude-\(name)")
        self.cliDirName = cliDirName
        self.iconStyle = iconStyle
        self.colorHex = colorHex ?? AccountProfile.defaultColorHex(for: name)
        self.sortOrder = sortOrder
        self.enabled = enabled
        self.handoffGroup = handoffGroup
        self.proxy = proxy
        self.egressPolicy = egressPolicy
        self.cliLinked = cliLinked
        self.identity = identity
        self.quota = quota
        self.lastEgress = lastEgress
        self.notes = notes
        self.createdAt = createdAt
    }

    public static let palette: [String] = [
        "3B6FD8", "2E9D6A", "7A5AE0", "1F9AA8",
        "D2504B", "C98A12", "C8508A", "5C6470"
    ]

    public static func defaultColorHex(for name: String) -> String {
        let sum = name.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return palette[abs(sum) % palette.count]
    }

    /// ASCII identifier for command names and bundle IDs. Non-Latin names are transliterated first
    /// ("工作" → "gong-zuo"), so Chinese names get readable, distinct commands. ASCII names are unchanged.
    public var slug: String {
        var latin = name
        if !name.allSatisfy(\.isASCII) {
            let m = NSMutableString(string: name)
            CFStringTransform(m, nil, kCFStringTransformToLatin, false)
            CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
            latin = m as String
        }
        let lowered = latin.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "account" : collapsed
    }

    public func userDataDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(dataDirName, isDirectory: true)
    }

    public func cliConfigDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if isDefault {
            return homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".claudedock", isDirectory: true)
            .appendingPathComponent("cli-profiles", isDirectory: true)
            .appendingPathComponent(resolvedCLIDirName, isDirectory: true)
    }

    /// The folder name actually in use: the stored one, or the legacy slug for profiles not yet migrated.
    public var resolvedCLIDirName: String { cliDirName ?? slug }

    /// Where a non-default account's Claude Code folder belongs once migrated.
    public var stableCLIDirName: String { id }

    public func launcherAppURL(appsDirectory: URL) -> URL {
        appsDirectory.appendingPathComponent("Claude \(name).app", isDirectory: true)
    }
}

public enum SchedulingMode: String, Codable, CaseIterable, Sendable {
    case mostHeadroom
    case orderPriority
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var schedulingMode: SchedulingMode
    public var quotaAlertThreshold: Double
    public var watchdogIntervalSeconds: Int
    public var shareDesktopMCP: Bool
    public var shareClaudeCodeResources: Bool
    /// Share Claude Code conversations (transcripts, checkpoints, plans, todos) across accounts,
    /// so any account can resume any session. Credentials always stay per account.
    public var shareClaudeCodeSessions: Bool
    public var claudeAppPath: String?
    public var claudeCLIPath: String?
    public var appsDirectoryPath: String?
    public var launchAtLogin: Bool
    public var globalHotkeysEnabled: Bool
    public var uiLanguage: String
    /// Menu bar–only mode: hide the Dock icon whenever the main window is closed.
    public var hideDockIconWhenClosed: Bool
    /// Show the main window when ClaudeDock starts (off = start quietly in the menu bar).
    public var openMainWindowAtLaunch: Bool

    public init(
        schedulingMode: SchedulingMode = .mostHeadroom,
        quotaAlertThreshold: Double = 85,
        watchdogIntervalSeconds: Int = 15,
        shareDesktopMCP: Bool = false,
        shareClaudeCodeResources: Bool = true,
        shareClaudeCodeSessions: Bool = true,
        claudeAppPath: String? = nil,
        claudeCLIPath: String? = nil,
        appsDirectoryPath: String? = nil,
        launchAtLogin: Bool = false,
        globalHotkeysEnabled: Bool = true,
        uiLanguage: String = "zh",
        hideDockIconWhenClosed: Bool = true,
        openMainWindowAtLaunch: Bool = true
    ) {
        self.hideDockIconWhenClosed = hideDockIconWhenClosed
        self.openMainWindowAtLaunch = openMainWindowAtLaunch
        self.schedulingMode = schedulingMode
        self.quotaAlertThreshold = quotaAlertThreshold
        self.watchdogIntervalSeconds = watchdogIntervalSeconds
        self.shareDesktopMCP = shareDesktopMCP
        self.shareClaudeCodeResources = shareClaudeCodeResources
        self.shareClaudeCodeSessions = shareClaudeCodeSessions
        self.claudeAppPath = claudeAppPath
        self.claudeCLIPath = claudeCLIPath
        self.appsDirectoryPath = appsDirectoryPath
        self.launchAtLogin = launchAtLogin
        self.globalHotkeysEnabled = globalHotkeysEnabled
        self.uiLanguage = uiLanguage
    }

    /// Tolerates settings files written by older versions: every missing key falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        schedulingMode = try c.decodeIfPresent(SchedulingMode.self, forKey: .schedulingMode) ?? d.schedulingMode
        quotaAlertThreshold = try c.decodeIfPresent(Double.self, forKey: .quotaAlertThreshold) ?? d.quotaAlertThreshold
        watchdogIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .watchdogIntervalSeconds) ?? d.watchdogIntervalSeconds
        shareDesktopMCP = try c.decodeIfPresent(Bool.self, forKey: .shareDesktopMCP) ?? d.shareDesktopMCP
        shareClaudeCodeResources = try c.decodeIfPresent(Bool.self, forKey: .shareClaudeCodeResources) ?? d.shareClaudeCodeResources
        shareClaudeCodeSessions = try c.decodeIfPresent(Bool.self, forKey: .shareClaudeCodeSessions) ?? d.shareClaudeCodeSessions
        claudeAppPath = try c.decodeIfPresent(String.self, forKey: .claudeAppPath)
        claudeCLIPath = try c.decodeIfPresent(String.self, forKey: .claudeCLIPath)
        appsDirectoryPath = try c.decodeIfPresent(String.self, forKey: .appsDirectoryPath)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        globalHotkeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalHotkeysEnabled) ?? d.globalHotkeysEnabled
        uiLanguage = try c.decodeIfPresent(String.self, forKey: .uiLanguage) ?? d.uiLanguage
        hideDockIconWhenClosed = try c.decodeIfPresent(Bool.self, forKey: .hideDockIconWhenClosed) ?? d.hideDockIconWhenClosed
        openMainWindowAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .openMainWindowAtLaunch) ?? d.openMainWindowAtLaunch
    }
}

public struct DockStoreData: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var accounts: [AccountProfile]
    public var settings: AppSettings
    public var updateGuardSavedAccounts: [String]

    public init(
        schemaVersion: Int = DockStoreData.currentSchemaVersion,
        accounts: [AccountProfile] = [],
        settings: AppSettings = AppSettings(),
        updateGuardSavedAccounts: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.settings = settings
        self.updateGuardSavedAccounts = updateGuardSavedAccounts
    }
}

public enum RunningState: Equatable, Sendable {
    case stopped
    case running(pids: [Int32])
    case frozen(pids: [Int32])

    public var isActive: Bool {
        switch self {
        case .stopped: return false
        case .running, .frozen: return true
        }
    }

    public var isFrozen: Bool {
        if case .frozen = self { return true }
        return false
    }

    public var pids: [Int32] {
        switch self {
        case .stopped: return []
        case .running(let p), .frozen(let p): return p
        }
    }
}
