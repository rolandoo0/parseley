import Foundation

// The built-in transforms. Each one is a tiny struct; shared logic lives in
// `ItemSplitter` (what counts as an item) and `NumericItems` (when a list is numeric).

/// `a, b, c`
public struct CommaListTransform: Transform {
    public let id = "list.comma"
    public let title = "Comma list"
    public var format: NumberFormat
    public init(format: NumberFormat = .us) { self.format = format }

    public func apply(_ input: String) throws -> String {
        let items = ItemSplitter.split(input, format: format).items
        guard !items.isEmpty else { throw TransformError.noItems }
        return items.joined(separator: ", ")
    }
}

/// `IN ('a', 'b')` for strings, `IN (1, 2)` when every item is a number.
public struct SQLInTransform: Transform {
    public let id = "sql.in"
    public let title = "SQL IN"
    public var format: NumberFormat
    public init(format: NumberFormat = .us) { self.format = format }

    public func apply(_ input: String) throws -> String {
        let items = ItemSplitter.split(input, format: format).items.map(ItemSplitter.unquote)
        guard !items.isEmpty else { throw TransformError.noItems }
        let values: [String]
        if let numbers = NumericItems.values(items, format: format) {
            // SQL always uses "." for decimals, whatever the input format.
            values = numbers.map { NumberFormatting.machinePlain($0, maxFractionDigits: 20) }
        } else {
            // SQL escapes a single quote by doubling it: O'Brien → 'O''Brien'
            values = items.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
        }
        return "IN (" + values.joined(separator: ", ") + ")"
    }
}

/// `["a", "b"]` for strings, `[1, 2]` when every item is a number.
public struct JSONArrayTransform: Transform {
    public let id = "json.array"
    public let title = "JSON array"
    public var format: NumberFormat
    public init(format: NumberFormat = .us) { self.format = format }

    public func apply(_ input: String) throws -> String {
        let items = ItemSplitter.split(input, format: format).items.map(ItemSplitter.unquote)
        guard !items.isEmpty else { throw TransformError.noItems }
        let values: [String]
        if let numbers = NumericItems.values(items, format: format) {
            // JSON always uses "." for decimals.
            values = numbers.map { NumberFormatting.machinePlain($0, maxFractionDigits: 20) }
        } else {
            values = items.map(Self.jsonString)
        }
        return "[" + values.joined(separator: ", ") + "]"
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                // Other control characters must be \u-escaped in JSON.
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// Sorts items: by value when all are numbers (keeping their formatting), otherwise
/// alphabetically (case-insensitive, "file2" before "file10"). Keeps the separator style.
public struct SortTransform: Transform {
    public let ascending: Bool
    public var format: NumberFormat
    public var id: String { ascending ? "sort.asc" : "sort.desc" }
    public var title: String { ascending ? "Sort ↑" : "Sort ↓" }
    public init(ascending: Bool, format: NumberFormat = .us) {
        self.ascending = ascending
        self.format = format
    }

    public func apply(_ input: String) throws -> String {
        let split = ItemSplitter.split(input, format: format)
        guard !split.items.isEmpty else { throw TransformError.noItems }

        // Pair each item with its position so equal items keep their original order
        // (a "stable" sort), whichever direction we sort in.
        let indexed = Array(split.items.enumerated())
        let sorted: [(offset: Int, element: String)]
        if let numbers = NumericItems.values(split.items, allowLeadingZeros: true, format: format) {
            sorted = indexed.sorted { a, b in
                let (x, y) = (numbers[a.offset], numbers[b.offset])
                if x != y { return ascending ? x < y : x > y }
                return a.offset < b.offset
            }
        } else {
            sorted = indexed.sorted { a, b in
                let order = a.element.compare(b.element, options: [.caseInsensitive, .numeric])
                if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
                return a.offset < b.offset
            }
        }
        return sorted.map(\.element).joined(separator: split.separator.joiner)
    }
}

/// Removes repeated items, keeping the first occurrence and the original order.
public struct DedupeTransform: Transform {
    public let id = "list.dedupe"
    public let title = "Dedupe"
    public var format: NumberFormat
    public init(format: NumberFormat = .us) { self.format = format }

    public func apply(_ input: String) throws -> String {
        let split = ItemSplitter.split(input, format: format)
        guard !split.items.isEmpty else { throw TransformError.noItems }
        var seen = Set<String>()
        let unique = split.items.filter { seen.insert($0).inserted }   // insert returns false if already present
        return unique.joined(separator: split.separator.joiner)
    }
}

/// Trims each line, collapses runs of spaces, trims around tabs (keeping columns),
/// drops blank lines, and normalises odd whitespace (non-breaking, zero-width, \r\n).
public struct CleanWhitespaceTransform: Transform {
    public let id = "text.clean"
    public let title = "Clean whitespace"
    public init() {}

    private static let oddSpaces: [Character] = ["\u{00A0}", "\u{2007}", "\u{202F}", "\u{2009}", "\u{2002}", "\u{2003}"]
    private static let zeroWidth: [String] = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]

    public func apply(_ input: String) throws -> String {
        var text = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for z in Self.zeroWidth { text = text.replacingOccurrences(of: z, with: "") }
        text = String(text.map { Self.oddSpaces.contains($0) ? " " : $0 })

        let lines = text.components(separatedBy: "\n").compactMap { line -> String? in
            let cells = line.components(separatedBy: "\t").map(Self.collapseSpaces)
            let cleaned = cells.joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? nil : cleaned
        }
        guard !lines.isEmpty else { throw TransformError.noItems }
        return lines.joined(separator: "\n")
    }

    private static func collapseSpaces(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

/// Rewrites every number as plain digits: "$1,204.50" → "1204.50", "(300)" → "-300",
/// "1.2k" → "1200". Percent signs are kept; all other text is left untouched.
public struct RemoveNumberFormattingTransform: Transform {
    public let id = "number.plain"
    public let title = "Plain numbers"
    public var format: NumberFormat
    public init(format: NumberFormat = .us) { self.format = format }

    public func apply(_ input: String) throws -> String {
        let numbers = NumberParser(format: format).parse(input)
        guard !numbers.isEmpty else { throw TransformError.noNumbers }
        var output = input
        // Replace from the end so earlier ranges stay valid.
        for n in numbers.reversed() {
            var plain: String
            if n.multiplier != 1 {
                plain = NumberFormatting.plain(n.value, maxFractionDigits: 20, format: format)
            } else {
                // Keep the digits exactly as typed ("5.00" stays "5.00"; "5,00" in European).
                let digits = format == .us ? n.digits : n.digits.replacingOccurrences(of: ".", with: ",")
                plain = (n.value < 0 ? "-" : "") + digits
            }
            if n.isPercent { plain += "%" }
            output.replaceSubrange(n.range, with: plain)
        }
        return output
    }
}

/// Decides whether a list is "all numbers".
enum NumericItems {
    /// Values of all items if every item is a single number, else nil.
    /// - Parameter allowLeadingZeros: false treats "00123" as text (ids, zip codes),
    ///   which matters for SQL/JSON output where 00123 would lose its zeros.
    static func values(_ items: [String], allowLeadingZeros: Bool = false, format: NumberFormat = .us) -> [Decimal]? {
        let parser = NumberParser(format: format)
        var result: [Decimal] = []
        for item in items {
            guard let n = parser.parseWhole(item) else { return nil }
            if !allowLeadingZeros, n.digits.count > 1, n.digits.hasPrefix("0"), !n.digits.hasPrefix("0.") {
                return nil
            }
            result.append(n.value)
        }
        return result
    }
}
