import Darwin
import Foundation

public struct SyncReport: Equatable, Sendable {
    public var syncedAccounts: [String]
    public var mergedMCPServerCount: Int
    public var backupsCreated: [String]
    public var warnings: [String]

    public init(
        syncedAccounts: [String] = [],
        mergedMCPServerCount: Int = 0,
        backupsCreated: [String] = [],
        warnings: [String] = []
    ) {
        self.syncedAccounts = syncedAccounts
        self.mergedMCPServerCount = mergedMCPServerCount
        self.backupsCreated = backupsCreated
        self.warnings = warnings
    }
}

/// Three-way configuration synchronization engine with POSIX `flock` locking, strict JSON validation,
/// `O_CREAT|O_EXCL|O_NOFOLLOW` `0600` staging (never leaks MCP secrets during writes!), and verified rotating backups.
public final class ConfigSyncEngine: Sendable {
    public let homeDirectory: URL
    public let syncStateDirectory: URL
    private var fm: FileManager { .default }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        syncStateDirectory: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.syncStateDirectory = syncStateDirectory ?? homeDirectory
            .appendingPathComponent(".claudedock", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
    }

    /// Pure three-way dictionary merge.
    public static func threeWayMerge(
        local: [String: Any],
        base: [String: Any],
        common: [String: Any]
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        let allKeys = Set(local.keys).union(base.keys).union(common.keys)

        for key in allKeys {
            let lVal = local[key]
            let bVal = base[key]
            let cVal = common[key]

            let localEqBase = jsonEqual(lVal, bVal)
            let commonEqBase = jsonEqual(cVal, bVal)

            if localEqBase {
                if let cVal { result[key] = cVal }
            } else if commonEqBase {
                if let lVal { result[key] = lVal }
            } else {
                if let lVal {
                    result[key] = lVal
                } else if let cVal {
                    result[key] = cVal
                }
            }
        }
        return result
    }

    /// Synchronizes `mcpServers` across all initialized accounts' `claude_desktop_config.json` using three-way merge.
    /// Safety rules:
    /// - Skips uninitialized accounts BEFORE pass 1 so missing directories never propagate deletions.
    /// - Strictly distinguishes ENOENT from corrupt/unreadable JSON and aborts before any writes on schema/parse errors.
    /// - Requires backup write to succeed before replacing existing config.
    /// - Stages temp files with `0600` BEFORE writing bytes.
    /// Which MCP servers each account currently has (by account id), read-only. Accounts whose Desktop folder
    /// doesn't exist yet are absent; an unreadable config maps to an empty set.
    public func mcpInventory(accounts: [AccountProfile]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for acc in accounts {
            let dir = acc.userDataDirectory(homeDirectory: homeDirectory)
            guard fm.fileExists(atPath: dir.path) else { continue }
            let url = dir.appendingPathComponent("claude_desktop_config.json")
            let names = ((try? readJSONDictStrict(at: url))??["mcpServers"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
            out[acc.id] = names
        }
        return out
    }

    /// A cheap fingerprint of every account's Desktop config (existence + modification time), used to sync
    /// automatically only when something actually changed.
    public func configFingerprint(accounts: [AccountProfile]) -> String {
        accounts.map { acc in
            let url = acc.userDataDirectory(homeDirectory: homeDirectory).appendingPathComponent("claude_desktop_config.json")
            let m = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let dirExists = fm.fileExists(atPath: url.deletingLastPathComponent().path)
            return "\(acc.id):\(dirExists ? 1 : 0):\(m)"
        }.joined(separator: "|")
    }

    public func syncDesktopMCPConfigs(accounts: [AccountProfile]) throws -> SyncReport {
        try fm.createDirectory(at: syncStateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = syncStateDirectory.appendingPathComponent("desktop-mcp.lock")
        return try withFileLock(at: lockURL) {
            try syncDesktopMCPUnlocked(accounts: accounts)
        }
    }

    private func syncDesktopMCPUnlocked(accounts: [AccountProfile]) throws -> SyncReport {
        let commonFile = syncStateDirectory.appendingPathComponent("shared-desktop-mcp.json")
        let baselinesDir = syncStateDirectory.appendingPathComponent("baselines", isDirectory: true)
        let backupsDir = syncStateDirectory.appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: baselinesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // If the shared catalog is gone (deleted, first run after a cleanup), baselines are meaningless:
        // rebuild from what each account has, instead of reading "everything was removed" into it.
        let catalogExists = fm.fileExists(atPath: commonFile.path)
        var common = try readJSONDictStrict(at: commonFile) ?? [:]
        var report = SyncReport()

        struct Snapshot {
            let account: AccountProfile
            let configURL: URL
            let fullConfig: [String: Any]
            let localMCP: [String: Any]
            let baseMCP: [String: Any]
            let originalData: Data?
        }

        var snapshots: [Snapshot] = []

        // Pass 1: Validate & merge ONLY accounts whose Desktop data folder actually exists.
        for acc in accounts {
            let dir = acc.userDataDirectory(homeDirectory: homeDirectory)
            guard fm.fileExists(atPath: dir.path) else {
                report.warnings.append("Skipped '\(acc.name)': Desktop data folder not created yet (open once first).")
                continue
            }
            let configURL = dir.appendingPathComponent("claude_desktop_config.json")
            let originalData = fm.fileExists(atPath: configURL.path) ? try Data(contentsOf: configURL) : nil
            let full: [String: Any]
            if let originalData {
                guard let parsed = try JSONSerialization.jsonObject(with: originalData) as? [String: Any] else {
                    throw DockError.syncFailed("'\(acc.name)' claude_desktop_config.json root is not a JSON object; aborting sync to prevent data loss.")
                }
                full = parsed
            } else {
                full = [:]
            }

            let baseURL = baselinesDir.appendingPathComponent("\(acc.id).json")
            let baseMCP = catalogExists ? (try readJSONDictStrict(at: baseURL) ?? [:]) : [:]

            let localMCP: [String: Any]
            if let rawMCP = full["mcpServers"] {
                guard let dict = rawMCP as? [String: Any] else {
                    throw DockError.syncFailed("'\(acc.name)' mcpServers field is not a JSON object; aborting sync.")
                }
                localMCP = dict
            } else {
                // A missing config file or a missing "mcpServers" key says nothing about the user's intent
                // (Claude Desktop may have reset the file). Treat it as unchanged — never as "deleted everything",
                // which would propagate and wipe every other account. Only an explicit {} is a real deletion.
                localMCP = baseMCP
            }

            common = Self.threeWayMerge(local: localMCP, base: baseMCP, common: common)
            snapshots.append(Snapshot(
                account: acc,
                configURL: configURL,
                fullConfig: full,
                localMCP: localMCP,
                baseMCP: baseMCP,
                originalData: originalData
            ))
        }

        // Write updated common catalog atomically (0600)
        try writeJSONAtomically0600(common, to: commonFile)
        report.mergedMCPServerCount = common.count

        // Pass 2: Write merged mcpServers back to each account's claude_desktop_config.json
        for item in snapshots {
            let mergedMCP = Self.threeWayMerge(local: item.localMCP, base: item.baseMCP, common: common)
            // Compare with what's really on disk (a missing file/key was merged as "unchanged" but still needs writing).
            let onDisk = item.fullConfig["mcpServers"] as? [String: Any]
            if onDisk == nil ? !mergedMCP.isEmpty : !Self.jsonEqual(mergedMCP, onDisk) {
                // Re-read current file right before replacement to verify no concurrent external edit occurred
                // A config that appeared while we were syncing is new user data we never read: don't overwrite it.
                if item.originalData == nil && fm.fileExists(atPath: item.configURL.path) {
                    report.warnings.append("Skipped writing '\(item.account.name)': its config appeared during sync (will sync next time).")
                    continue
                }
                if let orig = item.originalData, fm.fileExists(atPath: item.configURL.path) {
                    let latest = try Data(contentsOf: item.configURL)
                    if latest != orig {
                        report.warnings.append("Skipped writing '\(item.account.name)': file modified externally during sync (re-run sync).")
                        continue
                    }
                    // Require backup write to SUCCEED before mutating user's config.
                    // Named by the immutable account id, so pruning one account can never touch another's backups.
                    let backupURL = backupsDir.appendingPathComponent("\(item.account.id)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
                    try writeData0600Atomically(orig, to: backupURL)
                    report.backupsCreated.append(backupURL.lastPathComponent)
                    pruneBackups(in: backupsDir, prefix: "\(item.account.id)-", keep: 10)
                }

                var updatedFull = item.fullConfig
                updatedFull["mcpServers"] = mergedMCP
                try writeJSONAtomically0600(updatedFull, to: item.configURL)
                report.syncedAccounts.append(item.account.name)
            }

            let baseURL = baselinesDir.appendingPathComponent("\(item.account.id).json")
            try writeJSONAtomically0600(mergedMCP, to: baseURL)
        }

        return report
    }

    public static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let l?, let r?):
            guard let ld = try? JSONSerialization.data(withJSONObject: ["v": l], options: [.sortedKeys]),
                  let rd = try? JSONSerialization.data(withJSONObject: ["v": r], options: [.sortedKeys]) else {
                return false
            }
            return ld == rd
        }
    }

    /// Distinguishes ENOENT (returns nil) from permission / malformed JSON errors (throws!).
    private func readJSONDictStrict(at url: URL) throws -> [String: Any]? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockError.syncFailed("Expected JSON object at \(url.path)")
        }
        return dict
    }

    private func writeJSONAtomically0600(_ dict: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try writeData0600Atomically(data, to: url)
    }

    /// creates private 0600 staging file via `open(..., O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW, 0600)`
    /// BEFORE writing bytes, fsyncs, and atomically renames so MCP secrets are never world-readable.
    private func writeData0600Atomically(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let tmpURL = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmpURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw DockError.syncFailed("Failed creating 0600 temp file at \(tmpURL.path) (errno \(errno))")
        }
        var succeeded = false
        defer {
            close(fd)
            if !succeeded {
                try? fm.removeItem(at: tmpURL)
            }
        }

        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var remaining = rawBuf.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written < 0 {
                    throw DockError.syncFailed("Write error to \(tmpURL.path) (errno \(errno))")
                }
                remaining -= written
                offset += written
            }
        }
        _ = fsync(fd)

        if Darwin.rename(tmpURL.path, url.path) != 0 {
            throw DockError.syncFailed("Atomic rename failed for \(url.path) (errno \(errno))")
        }
        succeeded = true
    }

    private func pruneBackups(in dir: URL, prefix: String, keep: Int) {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let matching = items
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }
        if matching.count > keep {
            for old in matching.dropFirst(keep) {
                try? fm.removeItem(at: old)
            }
        }
    }

    private func withFileLock<T>(at lockURL: URL, _ body: () throws -> T) throws -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw DockError.syncFailed("Unable to open lock file \(lockURL.path)")
        }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        guard flock(fd, LOCK_EX) == 0 else {
            throw DockError.syncFailed("Unable to acquire lock \(lockURL.path)")
        }
        return try body()
    }
}
