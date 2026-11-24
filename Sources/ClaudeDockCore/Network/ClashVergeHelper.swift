import Foundation

public struct ClashVergeDetection: Equatable, Sendable {
    public let configDirectory: URL
    public let mixedPort: Int
    public let tunEnabled: Bool
    public let systemProxyEnabled: Bool
    public let profileNames: [String]
    public let activeProfileUID: String?
    public let activeProfileName: String?

    public init(
        configDirectory: URL,
        mixedPort: Int,
        tunEnabled: Bool,
        systemProxyEnabled: Bool,
        profileNames: [String],
        activeProfileUID: String?,
        activeProfileName: String? = nil
    ) {
        self.configDirectory = configDirectory
        self.mixedPort = mixedPort
        self.tunEnabled = tunEnabled
        self.systemProxyEnabled = systemProxyEnabled
        self.profileNames = profileNames
        self.activeProfileUID = activeProfileUID
        self.activeProfileName = activeProfileName
    }
}

public struct ClashListenerMapping: Equatable, Sendable {
    public let accountName: String
    public let listenPort: Int
    public let proxyName: String

    public init(accountName: String, listenPort: Int, proxyName: String) {
        self.accountName = accountName
        self.listenPort = listenPort
        self.proxyName = proxyName
    }
}

/// Read-only Clash Verge Rev / Mihomo inspector + Multi-Listener Merge YAML generator.
/// Never reads or exports proxy credentials, UUIDs, or subscription URLs.
public enum ClashVergeHelper {
    public static func detect(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClashVergeDetection? {
        let fm = FileManager.default
        let candidates = [
            homeDirectory.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Application Support/clash-verge", isDirectory: true),
            homeDirectory.appendingPathComponent(".config/clash-verge", isDirectory: true),
        ]
        guard let dir = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return nil
        }

        var mixedPort = 7897
        var tunEnabled = false
        var systemProxyEnabled = false

        if let vergeText = try? String(contentsOf: dir.appendingPathComponent("verge.yaml"), encoding: .utf8) {
            if let port = extractInt(key: "verge_mixed_port", from: vergeText) {
                mixedPort = port
            }
            tunEnabled = extractBool(key: "enable_tun_mode", from: vergeText) ?? false
            systemProxyEnabled = extractBool(key: "enable_system_proxy", from: vergeText) ?? false
        }
        if let clashText = try? String(contentsOf: dir.appendingPathComponent("clash-verge.yaml"), encoding: .utf8) {
            if let port = extractInt(key: "mixed-port", from: clashText) {
                mixedPort = port
            }
        }

        var profileNames: [String] = []
        var activeUID: String?
        var activeName: String?
        if let profilesText = try? String(contentsOf: dir.appendingPathComponent("profiles.yaml"), encoding: .utf8) {
            activeUID = extractString(key: "current", from: profilesText)
            var currentItemUID: String?
            var currentItemType: String?
            var currentItemName: String?

            func flushItem() {
                defer {
                    currentItemUID = nil
                    currentItemType = nil
                    currentItemName = nil
                }
                guard let t = currentItemType, t == "remote" || t == "local",
                      let n = currentItemName, !n.isEmpty, n.lowercased() != "null", n != "~" else {
                    return
                }
                profileNames.append(n)
                if let uid = currentItemUID, uid == activeUID {
                    activeName = n
                }
            }

            for line in profilesText.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- uid:") {
                    flushItem()
                    currentItemUID = trimmed.dropFirst("- uid:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } else if trimmed.hasPrefix("type:") {
                    currentItemType = trimmed.dropFirst("type:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } else if trimmed.hasPrefix("name:") {
                    currentItemName = trimmed.dropFirst("name:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
            flushItem()
        }

        return ClashVergeDetection(
            configDirectory: dir,
            mixedPort: mixedPort,
            tunEnabled: tunEnabled,
            systemProxyEnabled: systemProxyEnabled,
            profileNames: profileNames,
            activeProfileUID: activeUID,
            activeProfileName: activeName
        )
    }

    /// Generates a ready-to-paste Clash Verge 「全局扩展覆写配置 (Merge)」 YAML snippet
    /// that binds dedicated loopback ports (e.g., 17901..17905) directly to specified proxies/groups.
    /// Because loopback `127.0.0.1` bypasses TUN, each account stays on its dedicated node even when normal traffic uses another profile or rule.
    public static func generateMergeYAML(mappings: [ClashListenerMapping]) -> String {
        var lines: [String] = [
            "# =============================================================================",
            "# ClaudeDock — Clash Verge「全局扩展覆写配置 (Merge)」多端口分流模板",
            "# 使用方法：",
            "# 1. 打开 Clash Verge -> 订阅 -> 右键「全局扩展覆写配置 (Merge)」-> 编辑文件",
            "# 2. 将下面 listeners 段粘贴进去（若已有 listeners 请合并条目），保存并重载配置",
            "# 3. 将 proxy 字段替换为你当前订阅里实际存在的节点名或策略组名（例如 US-Dedicated / JP-Direct）",
            "# 4. 回到 ClaudeDock 为各账号填入对应本地端口（127.0.0.1:PORT）并点击「锁定当前出口」",
            "# =============================================================================",
            "listeners:",
        ]
        var usedNames = Set<String>()
        for (idx, item) in mappings.enumerated() {
            var baseName = item.accountName
                .lowercased()
                .replacingOccurrences(of: #"[^a-z0-9_-]"#, with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if baseName.isEmpty { baseName = "slot-\(idx + 1)" }
            var safeListenerName = "claudedock-\(baseName)"
            // Loop: the suffixed name can itself collide with another account's name ("a" ×2 vs "a-2").
            var suffix = idx + 1
            while usedNames.contains(safeListenerName) {
                safeListenerName = "claudedock-\(baseName)-\(suffix)"
                suffix += 1
            }
            usedNames.insert(safeListenerName)

            let escapedProxy = yamlEscapeDoubleQuoted(item.proxyName)
            lines.append("  - name: \(safeListenerName)")
            lines.append("    type: mixed")
            lines.append("    port: \(item.listenPort)")
            lines.append("    listen: 127.0.0.1")
            lines.append("    proxy: \"\(escapedProxy)\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func yamlEscapeDoubleQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    public static func generateMergeYAML(for accounts: [AccountProfile], defaultProxyName: String = "Your-Dedicated-Node", mixedPort: Int = 7897) -> String {
        var nextPort = 17901
        var mappings: [ClashListenerMapping] = []
        // The shared mixed port can't double as a dedicated listener.
        func ownsPort(_ acc: AccountProfile) -> Bool { acc.proxy.enabled && acc.proxy.port != 7897 && acc.proxy.port != mixedPort }
        // Reserve every explicitly configured port first, so an automatic pick never takes a later account's port.
        var reserved = Set<Int>()
        var explicitOwner: [String: Int] = [:]
        for acc in accounts where ownsPort(acc) && !reserved.contains(acc.proxy.port) {
            reserved.insert(acc.proxy.port)
            explicitOwner[acc.id] = acc.proxy.port
        }
        var usedPorts = reserved.union([7897, mixedPort])

        for acc in accounts {
            let port: Int
            if let own = explicitOwner[acc.id] {
                port = own
            } else {
                while usedPorts.contains(nextPort) { nextPort += 1 }
                port = nextPort
                nextPort += 1
            }
            usedPorts.insert(port)
            let node = (acc.proxy.clashNodeName?.isEmpty == false) ? acc.proxy.clashNodeName! : defaultProxyName
            mappings.append(ClashListenerMapping(accountName: acc.name, listenPort: port, proxyName: node))
        }
        if mappings.isEmpty {
            mappings = [
                ClashListenerMapping(accountName: "Account-1", listenPort: 17901, proxyName: defaultProxyName),
                ClashListenerMapping(accountName: "Account-2", listenPort: 17902, proxyName: defaultProxyName),
            ]
        }
        return generateMergeYAML(mappings: mappings)
    }

    private static func extractInt(key: String, from text: String) -> Int? {
        guard let raw = extractString(key: key, from: text) else { return nil }
        return Int(raw)
    }

    private static func extractBool(key: String, from text: String) -> Bool? {
        guard let raw = extractString(key: key, from: text)?.lowercased() else { return nil }
        if raw == "true" { return true }
        if raw == "false" { return false }
        return nil
    }

    private static func extractString(key: String, from text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                let value = trimmed.dropFirst(key.count + 1)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
