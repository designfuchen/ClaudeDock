import Foundation

/// Fuzzy matching for search fields, including Chinese by pinyin and pinyin initials.
public enum FuzzyMatch {
    /// Score > 0 when every query character appears in order. Rewards prefix and word-start hits.
    /// Chinese text also matches by full pinyin and pinyin initials (e.g. "cg" → 词光).
    public static func score(_ query: String, in candidates: [String]) -> Int {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return 1 }
        var best = 0
        for c in candidates where !c.isEmpty {
            for form in forms(of: c) {
                best = max(best, subsequenceScore(q, form))
            }
        }
        return best
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [String]] = [:]

    private static func forms(of s: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let f = cache[s] { return f }
        var out = [s.lowercased()]
        if s.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
            let m = NSMutableString(string: s)
            CFStringTransform(m, nil, kCFStringTransformToLatin, false)
            CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
            let latin = (m as String).lowercased()
            out.append(latin.replacingOccurrences(of: " ", with: ""))
            out.append(String(latin.split(separator: " ").compactMap(\.first)))
        }
        cache[s] = out
        return out
    }

    private static func subsequenceScore(_ q: String, _ text: String) -> Int {
        if text.hasPrefix(q) { return 1000 - text.count }
        if text.contains(q) { return 600 - text.count }
        var score = 0
        var ti = text.startIndex
        var prev: Character = " "
        for qc in q {
            var found = false
            while ti < text.endIndex {
                let tc = text[ti]
                ti = text.index(after: ti)
                if tc == qc {
                    score += (prev == " " || prev == "-" || prev == "_" || prev == "/") ? 12 : 4
                    prev = tc
                    found = true
                    break
                }
                prev = tc
            }
            if !found { return 0 }
        }
        return score
    }
}

