import Darwin
import Foundation

/// Thread-safe AND multi-process-safe (flock) atomic JSON persistence for ClaudeDock state
/// with strict POSIX 0700/0600 permissions so CLI and MenuBarApp never race on `profiles.json`.
public final class ProfileStore: @unchecked Sendable {
    public let rootDirectory: URL
    public let storeFileURL: URL
    private let lockFileURL: URL
    private let lock = NSLock()
    private var fileManager: FileManager { .default }

    public init(rootDirectory: URL? = nil) {
        let base = rootDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudedock", isDirectory: true)
        self.rootDirectory = base
        self.storeFileURL = base.appendingPathComponent("profiles.json")
        self.lockFileURL = base.appendingPathComponent(".profiles.lock")
    }

    public func ensureDirectories() throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
    }

    public func load() throws -> DockStoreData {
        lock.lock()
        defer { lock.unlock() }
        return try withCrossProcessLock(shared: true) {
            try loadUnlocked()
        }
    }

    public func save(_ data: DockStoreData) throws {
        lock.lock()
        defer { lock.unlock() }
        try withCrossProcessLock(shared: false) {
            try saveUnlocked(data)
        }
    }

    @discardableResult
    public func mutate<T>(_ body: (inout DockStoreData) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try withCrossProcessLock(shared: false) {
            var data = try loadUnlocked()
            let result = try body(&data)
            try saveUnlocked(data)
            return result
        }
    }

    private func withCrossProcessLock<T>(shared: Bool, _ body: () throws -> T) throws -> T {
        try ensureDirectories()
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw DockError.ioError("Unable to open store lock \(lockFileURL.path)")
        }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        guard flock(fd, shared ? LOCK_SH : LOCK_EX) == 0 else {
            throw DockError.ioError("Unable to acquire store lock \(lockFileURL.path)")
        }
        return try body()
    }

    private func loadUnlocked() throws -> DockStoreData {
        guard fileManager.fileExists(atPath: storeFileURL.path) else {
            return DockStoreData()
        }
        let raw = try Data(contentsOf: storeFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            var decoded = try decoder.decode(DockStoreData.self, from: raw)
            if decoded.schemaVersion < DockStoreData.currentSchemaVersion {
                decoded.schemaVersion = DockStoreData.currentSchemaVersion
            }
            decoded.accounts.sort { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
            return decoded
        } catch {
            // Preserve corrupt file as backup instead of silently destroying user data
            let backupName = "profiles.corrupt.\(Int(Date().timeIntervalSince1970)).json"
            let backupURL = rootDirectory.appendingPathComponent(backupName)
            try? raw.write(to: backupURL, options: .atomic)
            throw DockError.ioError("Failed to parse \(storeFileURL.path) (backed up to \(backupName)): \(error.localizedDescription)")
        }
    }

    private func saveUnlocked(_ data: DockStoreData) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(data)

        // Write to private temp file then atomically rename into place
        let tmpURL = rootDirectory.appendingPathComponent(".profiles.\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: tmpURL.path, contents: encoded, attributes: [.posixPermissions: 0o600]) else {
            throw DockError.ioError("Unable to create temporary file at \(tmpURL.path)")
        }
        do {
            if fileManager.fileExists(atPath: storeFileURL.path) {
                _ = try fileManager.replaceItemAt(storeFileURL, withItemAt: tmpURL)
            } else {
                try fileManager.moveItem(at: tmpURL, to: storeFileURL)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeFileURL.path)
        } catch {
            try? fileManager.removeItem(at: tmpURL)
            throw DockError.ioError("Failed saving store: \(error.localizedDescription)")
        }
    }
}
