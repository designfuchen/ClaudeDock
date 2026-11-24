import Foundation

/// One Claude Code conversation stored on this Mac.
public struct ClaudeSessionSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let lastActivity: Date
    /// The ClaudeDock account that last ran this session, when known from the launch ledger.
    public let lastAccountID: String?
}

/// A folder Claude Code has worked in, with its conversations across every account.
public struct ClaudeProject: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let sessions: [ClaudeSessionSummary]

    public var name: String { (path as NSString).lastPathComponent }
    /// For a git worktree created by Claude Code (`<repo>/.claude/worktrees/<name>`), the repo it belongs to.
    public var worktreeParent: String? {
        guard let r = path.range(of: "/.claude/worktrees/") else { return nil }
        return String(path[..<r.lowerBound])
    }
    public var lastActivity: Date { sessions.first?.lastActivity ?? .distantPast }
    public var lastAccountID: String? { sessions.first(where: { $0.lastAccountID != nil })?.lastAccountID }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Records which account launched Claude Code where, so sessions can be attributed to accounts.
/// Written by `claudedock cli-run` just before it hands over to `claude`. Local, append-only, 0600.
public struct SessionLedger: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let accountID: String
        public let cwd: String
        public let startedAt: Date
        /// Set when the launch resumed a specific session (`--resume <id>`).
        public let resumedSessionID: String?

        public init(accountID: String, cwd: String, startedAt: Date = Date(), resumedSessionID: String? = nil) {
            self.accountID = accountID
            self.cwd = cwd
            self.startedAt = startedAt
            self.resumedSessionID = resumedSessionID
        }
    }

    public let fileURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        fileURL = homeDirectory.appendingPathComponent(".claudedock/session-ledger.jsonl")
    }

    /// Appends one line with a single `write(2)` on an `O_APPEND` descriptor, so concurrent launches never
    /// overwrite each other. Refuses to follow a symlink at the ledger path.
    public func append(_ entry: Entry) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(entry) else { return }
        line.append(0x0A)
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // Hold an exclusive lock for the whole write loop, so even a short write can't interleave with another launch.
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        line.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { if errno == EINTR { continue }; return }
                offset += n
            }
        }
    }

    /// Most recent entries last. Reads at most the last ~2 MB.
    public func load() -> [Entry] {
        guard let h = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 2_000_000 ? size - 2_000_000 : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // Split on raw newline bytes: a window that starts mid-character only spoils its first, partial line.
        return data.split(separator: 0x0A).compactMap { try? dec.decode(Entry.self, from: Data($0)) }
    }
}

/// Scans Claude Code's local transcripts (`<config>/projects/<folder>/<session>.jsonl`) into projects and sessions.
/// Reads only the head and tail of each transcript, so large histories stay fast.
public enum ProjectCatalog {
    public static func scan(projectRoots: [URL], ledger: [SessionLedger.Entry], sessionsPerProject: Int = 40) -> [ClaudeProject] {
        let fm = FileManager.default
        var byPath: [String: [ClaudeSessionSummary]] = [:]
        var seenSessions = Set<String>()

        for root in projectRoots {
            guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for folder in folders {
                guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for file in files where file.pathExtension == "jsonl" {
                    let id = file.deletingPathExtension().lastPathComponent
                    guard isUUID(id), !seenSessions.contains(id) else { continue }
                    guard let info = readSession(file) else { continue }
                    seenSessions.insert(id)
                    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                    let modified = values?.contentModificationDate ?? .distantPast
                    let created = values?.creationDate ?? modified
                    let account = attribute(sessionID: id, cwd: info.cwd, created: created, ledger: ledger)
                    byPath[info.cwd, default: []].append(
                        ClaudeSessionSummary(id: id, title: info.title, lastActivity: modified, lastAccountID: account)
                    )
                }
            }
        }

        return byPath.filter { !isInternal($0.key) }.map { path, sessions in
            let sorted = sessions.sorted { $0.lastActivity > $1.lastActivity }
            return ClaudeProject(id: path, path: path, sessions: Array(sorted.prefix(sessionsPerProject)))
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Latest account that resumed this exact session; otherwise the launch in the same folder closest before it was created.
    static func attribute(sessionID: String, cwd: String, created: Date, ledger: [SessionLedger.Entry]) -> String? {
        if let resumed = ledger.last(where: { $0.resumedSessionID == sessionID }) {
            return resumed.accountID
        }
        // A session file is created after its launch; only launches shortly before it qualify.
        let candidates = ledger.filter {
            $0.cwd == cwd && $0.resumedSessionID == nil && $0.startedAt <= created
                && created.timeIntervalSince($0.startedAt) < 10 * 60
        }
        // If different accounts launched in this folder in that window, we can't tell which one it was.
        let accounts = Set(candidates.map(\.accountID))
        return accounts.count == 1 ? accounts.first : nil
    }

    public struct SessionInfo: Equatable, Sendable {
        public let cwd: String
        public let title: String
    }

    static func readSession(_ url: URL) -> SessionInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = 64 * 1024
        let head = (try? h.read(upToCount: chunk)) ?? Data()
        let size = (try? h.seekToEnd()) ?? 0
        var tail = Data()
        if size > UInt64(chunk) {
            try? h.seek(toOffset: size - UInt64(chunk))
            tail = (try? h.readToEnd()) ?? Data()
        }
        return parseSession(head: head, tail: tail)
    }

    /// Title preference: the latest custom title, then a summary, then the first real prompt.
    public static func parseSession(head: Data, tail: Data) -> SessionInfo? {
        var cwd: String?
        var customTitle: String?
        var summary: String?
        var firstPrompt: String?

        func scan(_ data: Data, lookForPrompt: Bool) {
            // Split on raw newline bytes: a chunk cut mid-character only loses its partial first/last line,
            // never the whole session (CJK text makes such cuts common).
            for line in data.split(separator: 0x0A) {
                guard line.first == 0x7B, // "{"
                      let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
                switch obj["type"] as? String {
                case "custom-title":
                    if let t = obj["customTitle"] as? String, !t.isEmpty { customTitle = t }
                case "summary":
                    if let t = obj["summary"] as? String, !t.isEmpty { summary = t }
                case "user" where lookForPrompt && firstPrompt == nil:
                    if (obj["isSidechain"] as? Bool) == true || (obj["isMeta"] as? Bool) == true { continue }
                    if let p = promptText(obj["message"]) { firstPrompt = p }
                default:
                    break
                }
            }
        }
        scan(head, lookForPrompt: true)
        scan(tail, lookForPrompt: false)

        guard let cwd else { return nil }
        let raw = customTitle ?? summary ?? firstPrompt ?? "未命名会话"
        return SessionInfo(cwd: cwd, title: oneLine(raw))
    }

    private static func promptText(_ message: Any?) -> String? {
        guard let msg = message as? [String: Any] else { return nil }
        var text: String?
        if let s = msg["content"] as? String {
            text = s
        } else if let parts = msg["content"] as? [[String: Any]] {
            text = parts.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        // Skip injected scaffolding (command echoes, caveats, system reminders).
        if t.hasPrefix("<") || t.hasPrefix("Caveat:") { return nil }
        return t
    }

    private static func oneLine(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count > 90 ? String(collapsed.prefix(88)) + "…" : collapsed
    }

    /// Claude Code's folder name for a working directory: every character other than ASCII letters and digits becomes "-".
    public static func projectFolderName(for cwd: String) -> String {
        String(cwd.unicodeScalars.map { s -> Character in
            (s.isASCII && (CharacterSet.alphanumerics.contains(s))) ? Character(s) : "-"
        })
    }

    /// The most recently written session in `cwd` (what `claude --continue` resumes), if any.
    public static func latestSessionID(cwd: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let folder = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(projectFolderName(for: cwd), isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" && isUUID($0.deletingPathExtension().lastPathComponent) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }?
            .deletingPathExtension().lastPathComponent
    }

    /// Scratch folders Claude Desktop creates for itself — not projects anyone would want to reopen.
    static func isInternal(_ path: String) -> Bool {
        path.contains("/Library/Application Support/Claude") || path.hasPrefix(NSTemporaryDirectory()) || path.hasPrefix("/private/var/folders/")
    }

    static func isUUID(_ s: String) -> Bool {
        s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }
}
