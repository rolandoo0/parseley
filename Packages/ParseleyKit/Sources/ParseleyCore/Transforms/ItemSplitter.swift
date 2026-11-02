import Foundation

/// Splits clip text into list items, so every transform agrees on what an "item" is.
///
/// Rules, in order:
/// 1. Several non-blank lines → one item per line (e.g. a spreadsheet column).
/// 2. One line → split on the first separator that occurs: tab, comma, semicolon, pipe,
///    then runs of spaces. Commas inside numbers don't split: thousands in US format
///    ("1,204"), decimals in European format ("1,5").
/// Items are trimmed; empty items are dropped.
public enum ItemSplitter {
    public enum Separator: Equatable, Sendable {
        case newline, tab, comma, semicolon, pipe, space

        /// How to join items back together in the same style.
        public var joiner: String {
            switch self {
            case .newline: "\n"
            case .tab: "\t"
            case .comma: ", "
            case .semicolon: "; "
            case .pipe: " | "
            case .space: " "
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public var items: [String]
        public var separator: Separator
    }

    public static func split(_ text: String, format: NumberFormat = .us) -> Result {
        let lines = text.components(separatedBy: .newlines).map(trim).filter { !$0.isEmpty }
        if lines.count > 1 { return Result(items: lines, separator: .newline) }
        guard let line = lines.first else { return Result(items: [], separator: .newline) }

        if line.contains("\t") {
            return Result(items: clean(line.components(separatedBy: "\t")), separator: .tab)
        }
        let commaItems = splitOnListCommas(line, format: format)
        if commaItems.count > 1 { return Result(items: clean(commaItems), separator: .comma) }
        if line.contains(";") {
            return Result(items: clean(line.components(separatedBy: ";")), separator: .semicolon)
        }
        if line.contains("|") {
            return Result(items: clean(line.components(separatedBy: "|")), separator: .pipe)
        }
        return Result(items: clean(line.components(separatedBy: " ")), separator: .space)
    }

    /// Removes one pair of matching surrounding quotes: 'a' → a, "a" → a.
    public static func unquote(_ item: String) -> String {
        guard item.count >= 2, let first = item.first, let last = item.last,
              first == last, first == "'" || first == "\""
        else { return item }
        return String(item.dropFirst().dropLast())
    }

    // MARK: - Helpers

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ parts: [String]) -> [String] {
        parts.map(trim).filter { !$0.isEmpty }
    }

    /// Splits on commas, except commas that belong to a number: US thousands ("1,204")
    /// or European decimals ("1,5", a comma between two digits).
    private static func splitOnListCommas(_ line: String, format: NumberFormat) -> [String] {
        let chars = Array(line)
        var parts: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            let partOfNumber = format == .us
                ? isThousandsComma(at: i, in: chars)
                : isDecimalComma(at: i, in: chars)
            if ch == ",", !partOfNumber {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func isDecimalComma(at i: Int, in chars: [Character]) -> Bool {
        i > 0 && i + 1 < chars.count && chars[i - 1].isASCIIDigit && chars[i + 1].isASCIIDigit
    }

    private static func isThousandsComma(at i: Int, in chars: [Character]) -> Bool {
        guard i > 0, chars[i - 1].isASCIIDigit, i + 3 < chars.count,
              chars[i + 1].isASCIIDigit, chars[i + 2].isASCIIDigit, chars[i + 3].isASCIIDigit
        else { return false }
        let after = i + 4
        return after >= chars.count || !chars[after].isASCIIDigit
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
