import CryptoKit
import Foundation

public enum DockError: Error, LocalizedError, Equatable, Sendable {
    case invalidAccountName(String)
    case invalidColorHex(String)
    case invalidProxyConfig(String)
    case invalidTimezone(String)
    case invalidLanguage(String)
    case accountAlreadyExists(String)
    case accountNotFound(String)
    case defaultAccountAlreadyExists(String)
    case claudeAppNotFound
    case claudeCLINotFound
    case accountStillRunning(String)
    case cannotDeleteDefaultData
    case egressBlocked(account: String, reason: String)
    case proxyUnreachable(proxy: String, detail: String)
    case launcherOperationFailed(String)
    case syncFailed(String)
    case quotaProbeFailed(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAccountName(let msg):
            return "Invalid account name: \(msg)"
        case .invalidColorHex(let hex):
            return "Invalid hex color '\(hex)' (expected 6 hex digits, e.g. 3B6FD8)"
        case .invalidProxyConfig(let msg):
            return "Invalid proxy configuration: \(msg)"
        case .invalidTimezone(let tz):
            return "Invalid timezone '\(tz)' (e.g. Europe/London)"
        case .invalidLanguage(let lang):
            return "Invalid language tag '\(lang)' (e.g. en-US)"
        case .accountAlreadyExists(let name):
            return "Account '\(name)' already exists."
        case .accountNotFound(let name):
            return "Account '\(name)' not found."
        case .defaultAccountAlreadyExists(let existing):
            return "Default Claude account is already managed by '\(existing)'."
        case .claudeAppNotFound:
            return "Claude.app not found in /Applications or ~/Applications. Install Claude Desktop first."
        case .claudeCLINotFound:
            return "Claude Code CLI (`claude`) not found in PATH or ~/.local/bin."
        case .accountStillRunning(let name):
            return "Account '\(name)' is currently running. Quit its window first."
        case .cannotDeleteDefaultData:
            return "Refusing to delete the default ~/Library/Application Support/Claude folder."
        case .egressBlocked(let account, let reason):
            return "Egress Guard BLOCKED '\(account)': \(reason)"
        case .proxyUnreachable(let proxy, let detail):
            return "Proxy '\(proxy)' is unreachable: \(detail)"
        case .launcherOperationFailed(let msg):
            return "Launcher error: \(msg)"
        case .syncFailed(let msg):
            return "Configuration sync failed: \(msg)"
        case .quotaProbeFailed(let msg):
            return "Quota probe failed: \(msg)"
        case .ioError(let msg):
            return "I/O error: \(msg)"
        }
    }
}

public enum Validation {
    public static func validateAccountName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 30 else {
            throw DockError.invalidAccountName("Must be 1–30 characters: '\(name)'")
        }
        guard !name.hasSuffix(" ") else {
            throw DockError.invalidAccountName("Must not end with a space")
        }
        // "--" would read as a command-line flag inside the --user-data-dir path and break process matching.
        guard !name.contains("--") else {
            throw DockError.invalidAccountName("Must not contain '--'")
        }
        // Letters and digits in any script (so Chinese names work), plus space, '-' and '_'.
        let pattern = #"^[\p{L}\p{N}][\p{L}\p{N} _-]{0,29}$"#
        guard name.range(of: pattern, options: .regularExpression) != nil else {
            throw DockError.invalidAccountName("Use letters, digits, spaces, '-' or '_', starting with a letter or digit: '\(name)'")
        }
        // Prevent collision with Claude Desktop's own 3P folders (e.g. Claude-3p)
        if name.range(of: #"[-\s]?3[pP]$"#, options: .regularExpression) != nil {
            throw DockError.invalidAccountName("Names ending with '3p' clash with Claude Desktop's internal folders")
        }
        // Prevent path traversal sequences
        if name.contains("..") || name.contains("/") || name.contains("\\") {
            throw DockError.invalidAccountName("Invalid path characters in '\(name)'")
        }
    }

    public static func normalizeColorHex(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard trimmed.range(of: #"^[0-9A-F]{6}$"#, options: .regularExpression) != nil else {
            throw DockError.invalidColorHex(raw)
        }
        return trimmed
    }

    public static func validateProxy(_ proxy: ProxyConfig) throws {
        guard !proxy.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DockError.invalidProxyConfig("Host cannot be empty")
        }
        guard proxy.host.range(of: #"^[A-Za-z0-9.\-:]+$"#, options: .regularExpression) != nil else {
            throw DockError.invalidProxyConfig("Host contains invalid characters: '\(proxy.host)'")
        }
        guard (1...65535).contains(proxy.port) else {
            throw DockError.invalidProxyConfig("Port must be 1–65535, got \(proxy.port)")
        }
        if let tz = proxy.timezone, !tz.isEmpty {
            try validateTimezone(tz)
        }
        if let lang = proxy.language, !lang.isEmpty {
            try validateLanguage(lang)
        }
    }

    public static func validateTimezone(_ tz: String) throws {
        guard tz.count <= 64,
              !tz.contains(".."),
              tz.range(of: #"^[A-Za-z0-9_/+.-]+$"#, options: .regularExpression) != nil else {
            throw DockError.invalidTimezone(tz)
        }
    }

    public static func validateLanguage(_ lang: String) throws {
        guard lang.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else {
            throw DockError.invalidLanguage(lang)
        }
    }
}

public enum SHA256Helper {
    public static func hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum DockConstants {
    public static let version = "0.2.0"
    public static let launcherMarker = "# claudedock-launcher-v1"
    public static let bundleIDPrefix = "io.claudedock.launcher."
}
