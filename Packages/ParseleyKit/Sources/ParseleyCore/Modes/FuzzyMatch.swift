/// Small fuzzy matcher for the `>` command bar: "sqin" finds "SQL IN", "cs" finds
/// "Copy sum". Case-insensitive; characters must appear in order.
public enum FuzzyMatch {
    /// Higher is better; nil means no match. Tiers: prefix > substring at a word start >
    /// other substring > scattered characters (rewarding word starts and runs).
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = query.lowercased().filter { !$0.isWhitespace }
        let c = candidate.lowercased()
        guard !q.isEmpty else { return 0 }

        let compact = c.filter { !$0.isWhitespace }
        if compact.hasPrefix(q) { return 1_000 - (compact.count - q.count) }
        if let range = c.range(of: q) {
            let atWordStart = range.lowerBound == c.startIndex || c[c.index(before: range.lowerBound)] == " "
            return (atWordStart ? 800 : 600) - (c.count - q.count)
        }

        // Subsequence: walk the candidate picking up query characters in order.
        let chars = Array(c)
        var score = 100
        var qi = q.startIndex
        var previousMatch = -2
        for (i, ch) in chars.enumerated() where qi < q.endIndex {
            guard ch == q[qi] else { continue }
            if i == 0 || chars[i - 1] == " " { score += 15 }     // word start
            if i == previousMatch + 1 { score += 10 }              // consecutive
            score -= min(i - previousMatch - 1, 5)                 // small gap penalty
            previousMatch = i
            qi = q.index(after: qi)
        }
        return qi == q.endIndex ? score : nil
    }

    /// Items matching `query`, best first. Ties keep their original order. An empty query
    /// returns everything unchanged.
    public static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.enumerated()
            .compactMap { offset, item in score(trimmed, key(item)).map { (offset, item, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }
}
