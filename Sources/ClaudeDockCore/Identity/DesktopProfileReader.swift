import Foundation

/// Reads the signed-in person's email and name from Claude Desktop's own local cache, for display only.
///
/// Claude Desktop keeps the claude.ai account object in IndexedDB (a LevelDB directory). Records are V8-serialised,
/// so a string field appears as `<key>` followed by a type tag (`"` one-byte, `c` two-byte), a varint length and the bytes.
/// We look only at fields that follow this account's own UUID, so one data directory can never show another account's
/// email. Purely local and read-only: nothing is sent anywhere, and failure simply means "unknown".
public enum DesktopProfileReader {
    public struct Profile: Equatable, Sendable {
        public let email: String?
        public let displayName: String?
    }

    public static func read(userDataDirectory: URL, accountUUID: String) -> Profile? {
        let dir = userDataDirectory
            .appendingPathComponent("IndexedDB", isDirectory: true)
            .appendingPathComponent("https_claude.ai_0.indexeddb.leveldb", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        // Newest data first: .log holds the latest writes, then the most recently modified tables.
        let candidates = files
            .filter { ["log", "ldb"].contains($0.pathExtension) }
            .filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 64 * 1024 * 1024 }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for file in candidates {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            if let profile = parse(data, accountUUID: accountUUID) { return profile }
        }
        return nil
    }

    /// Whoever is signed in to this Desktop data folder, without knowing the account UUID in advance
    /// (a brand-new account has no other trace yet). Returns the UUID with the profile, or nil if nobody is signed in.
    public static func readSignedIn(userDataDirectory: URL) -> (accountUUID: String, profile: Profile)? {
        let dir = userDataDirectory
            .appendingPathComponent("IndexedDB", isDirectory: true)
            .appendingPathComponent("https_claude.ai_0.indexeddb.leveldb", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let ownField: [UInt8] = [0x22, 0x04] + Array("uuid".utf8) + [0x22, 0x24]
        for file in files where ["log", "ldb"].contains(file.pathExtension) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size < 64 * 1024 * 1024, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            let bytes = [UInt8](data)
            var i = 0
            while let at = indexOf(ownField, in: bytes, from: i) {
                i = at + 1
                let start = at + ownField.count
                guard start + 36 <= bytes.count,
                      let uuid = String(bytes: bytes[start..<(start + 36)], encoding: .ascii),
                      uuid.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil,
                      let profile = parse(data, accountUUID: uuid), profile.email != nil else { continue }
                return (uuid, profile)
            }
        }
        return nil
    }

    /// Finds the last record in `data` that belongs to `accountUUID` and extracts its email and name.
    public static func parse(_ data: Data, accountUUID: String) -> Profile? {
        let bytes = [UInt8](data)
        let needle = [UInt8](accountUUID.lowercased().utf8)
        guard !needle.isEmpty else { return nil }
        var best: Profile?
        var i = 0
        // V8 encodes the account object's own field as: '"' 0x04 "uuid" '"' 0x24 <36-byte uuid>.
        // Requiring exactly that prefix skips references to the UUID from other objects (accountUuid, etc.).
        let ownField: [UInt8] = [0x22, 0x04] + Array("uuid".utf8) + [0x22, 0x24]
        while let hit = indexOf(needle, in: bytes, from: i) {
            defer { i = hit + 1 }
            guard hit >= ownField.count, Array(bytes[(hit - ownField.count)..<hit]) == ownField else { continue }
            // The account's own fields sit between its UUID and the next UUID (its organisation, or another record).
            // Never look past that boundary, so a neighbouring record's email can't be attributed to this account.
            let start = hit + needle.count
            let end = nextUUID(in: bytes, from: start, limit: min(bytes.count, start + 600)) ?? min(bytes.count, start + 600)
            let window = start ..< end
            let email = stringField("email_address", in: bytes, range: window).flatMap(validEmail)
            let display = stringField("display_name", in: bytes, range: window).flatMap(cleanName)
            let full = stringField("full_name", in: bytes, range: window).flatMap(cleanName)
            if email != nil || display != nil || full != nil {
                best = Profile(email: email, displayName: display ?? full)
            }
        }
        return best
    }

    /// Start of the next lowercase/uppercase hex UUID (8-4-4-4-12) in `bytes[from..<limit]`, if any.
    private static func nextUUID(in bytes: [UInt8], from: Int, limit: Int) -> Int? {
        func hex(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46) }
        let pattern = [8, 4, 4, 4, 12]
        var i = from
        while i + 36 <= limit {
            var p = i, ok = true
            for (k, len) in pattern.enumerated() {
                for _ in 0..<len { if !hex(bytes[p]) { ok = false; break }; p += 1 }
                if !ok { break }
                if k < 4 { if bytes[p] != 0x2D { ok = false; break }; p += 1 }
            }
            if ok { return i }
            i += 1
        }
        return nil
    }

    private static func stringField(_ key: String, in bytes: [UInt8], range: Range<Int>) -> String? {
        let k = [UInt8](key.utf8)
        guard let at = indexOf(k, in: bytes, from: range.lowerBound), at < range.upperBound else { return nil }
        var p = at + k.count
        guard p < bytes.count else { return nil }
        let tag = bytes[p]
        guard tag == 0x22 || tag == 0x63 else { return nil } // '"' one-byte (Latin-1), 'c' two-byte (UTF-16LE)
        p += 1
        var length = 0, shift = 0
        while p < bytes.count {
            let b = bytes[p]; p += 1
            length |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            if shift > 28 { return nil }
        }
        guard length > 0, length <= 400, p + length <= range.upperBound else { return nil }
        let slice = Data(bytes[p ..< p + length])
        return tag == 0x22
            ? String(data: slice, encoding: .isoLatin1)
            : String(data: slice, encoding: .utf16LittleEndian)
    }

    private static func validEmail(_ s: String) -> String? {
        s.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil ? s : nil
    }

    private static func cleanName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 80, t.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return t
    }

    private static func indexOf(_ needle: [UInt8], in hay: [UInt8], from start: Int) -> Int? {
        guard needle.count <= hay.count, start <= hay.count - needle.count else { return nil }
        let first = needle[0]
        var i = start
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count && hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}
