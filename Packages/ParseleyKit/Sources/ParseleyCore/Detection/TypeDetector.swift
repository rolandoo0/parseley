import Foundation

/// Classifies clip text into a `ClipKind`.
///
/// M1 detects url / email / json / table / text. Number kinds are added in M3, once the
/// number parser exists. Detection is deliberately conservative: when unsure, `.text`.
public struct TypeDetector: Sendable {
    public init() {}

    public func detect(_ content: String) -> ClipKind {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text }

        if isJSONContainer(trimmed) { return .json }
        if isTable(trimmed) { return .table }

        // url / email only for a single token (no internal whitespace).
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            if isURL(trimmed) { return .url }
            if isEmail(trimmed) { return .email }
        }
        return .text
    }

    // MARK: - Rules

    /// A JSON object or array (bare strings/numbers don't count as "JSON" to a user).
    func isJSONContainer(_ s: String) -> Bool {
        guard let first = s.first, let last = s.last,
              (first == "{" && last == "}") || (first == "[" && last == "]"),
              let data = s.data(using: .utf8)
        else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// 2+ rows, each containing a tab, all with the same number of columns.
    func isTable(_ s: String) -> Bool {
        let rows = s.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        guard rows.count >= 2 else { return false }
        let columnCounts = rows.map { $0.split(separator: "\t", omittingEmptySubsequences: false).count }
        guard let firstCount = columnCounts.first, firstCount >= 2 else { return false }
        return columnCounts.allSatisfy { $0 == firstCount }
    }

    func isURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.hasPrefix("www."), lower.dropFirst(4).contains(".") { return true }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "ftp": return url.host?.isEmpty == false
        case "file", "mailto": return true
        default: return false
        }
    }

    func isEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        guard !local.isEmpty, domain.contains("."),
              !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..")
        else { return false }
        return true
    }
}
