/// Turns clip content into short display strings for lists and menus.
public enum ClipPreview {
    /// The first non-blank line, with runs of whitespace collapsed to single spaces and
    /// truncated to `maxLength` characters (with "…").
    public static func title(_ content: String, maxLength: Int = 80) -> String {
        let firstLine = content
            .split(whereSeparator: \.isNewline)
            .first { !$0.allSatisfy(\.isWhitespace) }
            .map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(max(0, maxLength - 1))) + "…"
    }

    /// Number of non-blank lines.
    public static func lineCount(_ content: String) -> Int {
        content.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
    }
}
