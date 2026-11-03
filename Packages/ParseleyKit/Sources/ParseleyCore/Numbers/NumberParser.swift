import Foundation

/// One number found in text.
public struct ParsedNumber: Equatable, Sendable {
    /// Exact value. `Decimal`, not `Double`, so money adds up exactly (0.1 + 0.2 == 0.3).
    /// Percentages keep their face value: "12%" → 12.
    public var value: Decimal
    /// The text that was recognised, e.g. "($1,204.50)".
    public var text: String
    /// Where `text` sits in the original string.
    public var range: Range<String.Index>
    public var isPercent: Bool
    /// "$", "€", "£" or "¥" if present.
    public var currencySymbol: String?
    /// Digits after the decimal point as written ("1.50" → 2).
    public var fractionDigits: Int
    /// The digits without thousands separators, decimal point normalised to ".":
    /// "1,204.50" (or "1.204,50" in European format) → "1204.50".
    public var digits: String
    /// Value of a k / M / B suffix (1 if none).
    public var multiplier: Decimal
    /// What the number measures, normalized: a currency code ("USD", "EUR"; symbols map
    /// to codes), "%", or a unit ("kg", "km", "MB", "min", "h"…). Nil for a bare number.
    public var unit: String? = nil
    /// Where just the digits sit in the source text (the "1,204.50" in "($1,204.50 USD)").
    public var digitsRange: Range<String.Index>? = nil
    /// The same, as UTF-16 offsets within `text`, for rewriting the number in place.
    public var digitsOffsets: Range<Int>? = nil

    /// True if the unit is a currency.
    public var isCurrency: Bool { unit.map(NumberUnits.currencyCodes.contains) ?? false }
}

/// Units the parser recognises and how they're normalized.
public enum NumberUnits {
    public static let currencyCodes: Set<String> = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF", "CNY", "MXN", "BRL", "INR"]
    static let symbolCodes: [String: String] = ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY"]
    static let aliases: [String: String] = [
        "lbs": "lb", "hrs": "h", "hr": "h", "sec": "s", "L": "l", "kB": "KB",
    ]
    /// Regex alternatives, longest first so "min" wins over "mi" and "m".
    static let glued = "kWh|Mbps|Gbps|mph|kg|mg|g|lbs|lb|oz|km|cm|mm|mi|ft|in|min|ms|ml|m|l|L|s|hrs|hr|h|GB|MB|KB|kB|TB"
    /// After a space only unambiguous units (no "in", "m", "s"…: "3 in the box").
    static let spaced = "kWh|Mbps|Gbps|mph|kg|mg|lbs|lb|oz|km|cm|mm|mi|ft|min|ms|ml|hrs|hr|sec|GB|MB|KB|TB|USD|EUR|GBP|JPY|CAD|AUD|CHF|CNY|MXN|BRL|INR"
    static let codes = "USD|EUR|GBP|JPY|CAD|AUD|CHF|CNY|MXN|BRL|INR"

    static func normalize(_ unit: String) -> String { aliases[unit] ?? unit }
}

/// Extracts numbers from messy text: "$1,204.50", "(300)" (negative), "12%", "-4.5",
/// "1.2k", "3M", lists separated by newlines/tabs/commas/spaces, spreadsheet columns.
///
/// `format` decides the separators: `.us` reads "1,204.50", `.european` reads "1.204,50".
/// Deliberately skips things that look numeric but aren't quantities: dates, times,
/// version numbers, IP addresses, phone numbers, and digits glued to letters ("A1",
/// "SKU-1234"). Units and currencies are recognised: "5kg", "12 kg", "USD 1,204", "€380".
public struct NumberParser: Sendable {
    public let format: NumberFormat

    public init(format: NumberFormat = .us) {
        self.format = format
    }

    private var patterns: Patterns {
        format == .us ? Self.usPatterns : Self.europeanPatterns
    }

    public func parse(_ text: String) -> [ParsedNumber] {
        guard !text.isEmpty else { return [] }
        // Work on a copy where excluded spans (dates, times, …) are blanked out with
        // spaces. Spaces have the same UTF-16 length, so match ranges still line up
        // with the original text.
        let masked = NSMutableString(string: text)
        for pattern in patterns.exclusions {
            for match in pattern.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)).reversed() {
                masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
            }
        }
        let searchable = masked as String
        return patterns.number
            .matches(in: searchable, range: NSRange(location: 0, length: masked.length))
            .compactMap { makeNumber(from: $0, in: text) }
    }

    /// The single number that makes up all of `text` (ignoring surrounding whitespace),
    /// or nil if `text` is anything else. Used to decide if a list item is numeric.
    public func parseWhole(_ text: String) -> ParsedNumber? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = parse(trimmed)
        guard found.count == 1, let number = found.first,
              number.range == trimmed.startIndex..<trimmed.endIndex
        else { return nil }
        return number
    }

    /// The numbers in `text` if it's *nothing but* numbers and list separators (a single
    /// value, a list, a spreadsheet column or numeric range); nil if it also has words,
    /// dates or anything else. "1,204.50\n300" → 2 numbers; "Total: 5" → nil.
    public func numbersOnly(_ text: String) -> [ParsedNumber]? {
        let numbers = parse(text)
        guard !numbers.isEmpty else { return nil }
        // Everything between the numbers must be separators.
        var rest = ""
        var cursor = text.startIndex
        for n in numbers {
            rest += text[cursor..<n.range.lowerBound]
            cursor = n.range.upperBound
        }
        rest += text[cursor...]
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|"))
        return rest.unicodeScalars.allSatisfy(separators.contains) ? numbers : nil
    }

    // MARK: - Building a ParsedNumber from a regex match

    private func makeNumber(from match: NSTextCheckingResult, in text: String) -> ParsedNumber? {
        let ns = text as NSString
        func group(_ name: String) -> String? {
            let r = match.range(withName: name)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let rawDigits = group("num") else { return nil }

        // Normalise to "1204.50": drop grouping, use "." for decimals.
        var digits = rawDigits
            .replacingOccurrences(of: format.groupingSeparator, with: "")
            .replacingOccurrences(of: format.decimalSeparator, with: ".")
        if digits.hasPrefix(".") { digits = "0" + digits }
        guard var value = Decimal(string: digits, locale: Self.posix) else { return nil }

        let multiplier: Decimal
        switch group("suffix") {
        case "k", "K": multiplier = 1_000
        case "M": multiplier = 1_000_000
        case "B", "bn": multiplier = 1_000_000_000
        default: multiplier = 1
        }
        value *= multiplier

        let minus: Set<String> = ["-", "−"]
        let hasMinus = minus.contains(group("sign1") ?? "") || minus.contains(group("sign2") ?? "")
        let open = group("open") != nil
        let close = group("close") != nil
        // Accounting style "(300)" is negative; "(-300)" is still just negative.
        if hasMinus || (open && close) { value = -value }

        // A lone "(" or ")" isn't part of the number: trim it from the reported range.
        var range = match.range
        if open && !close { range = NSRange(location: range.location + 1, length: range.length - 1) }
        if close && !open { range = NSRange(location: range.location, length: range.length - 1) }
        guard let swiftRange = Range(range, in: text) else { return nil }

        let fraction = digits.split(separator: ".", maxSplits: 1).dropFirst().first?.count ?? 0
        let symbol = group("cur1") ?? group("cur2")
        let isPercent = group("pct") != nil
        let unit: String? =
            if let code = group("code1") ?? group("unit2").flatMap({ NumberUnits.currencyCodes.contains($0) ? $0 : nil }) { code }
            else if let symbol { NumberUnits.symbolCodes[symbol] }
            else if isPercent { "%" }
            else if let u = group("unit") ?? group("unit2") { NumberUnits.normalize(u) }
            else { nil }
        let numRange = match.range(withName: "num")
        let digitsRange = Range(numRange, in: text)
        let start = numRange.location - range.location
        return ParsedNumber(
            value: value,
            text: String(text[swiftRange]),
            range: swiftRange,
            isPercent: isPercent,
            currencySymbol: symbol,
            fractionDigits: fraction,
            digits: digits,
            multiplier: multiplier,
            unit: unit,
            digitsRange: digitsRange,
            digitsOffsets: start >= 0 ? start..<(start + numRange.length) : nil
        )
    }

    // MARK: - Patterns
    //
    // ICU regular expressions (NSRegularExpression). Written as raw strings #"…"# so
    // backslashes don't need doubling. (?<!…) / (?!…) are look-behind / look-ahead:
    // they check neighbouring characters without consuming them.

    private static let posix = Locale(identifier: "en_US_POSIX")

    private struct Patterns: Sendable {
        let number: NSRegularExpression
        let exclusions: [NSRegularExpression]
    }

    private static let glued = NumberUnits.glued
    private static let spaced = NumberUnits.spaced
    private static let codes = NumberUnits.codes

    // NSRegularExpression is immutable and thread-safe; compile each set once.
    private static let usPatterns = Patterns(
        number: try! NSRegularExpression(pattern: #"""
            (?<![\p{L}\p{N}_.])            # not glued to a word, digit or dot on the left
            (?<![\p{L}\p{N}][-−])          # not the "-19" in "COVID-19" / "SKU-1234"
            (?<open>\()?
            (?:(?<code1>\#(codes))\x20?)?     # "USD 1,204.50"
            (?<sign1>[-−+])?
            (?:(?<cur1>[$€£¥])\x20?)?        # \x20 = one plain space (never a newline)
            (?<sign2>[-−+])?
            (?<num>
                \d{1,3}(?:,\d{3})+(?:\.\d+)?   # 1,204 / 1,204.50
              | \d+(?:\.\d+)?                  # 1204 / 1204.5
              | \.\d+                          # .5
            )
            (?:
                (?<unit>\#(glued))(?![\p{L}\p{N}_])    # a unit glued on: "5kg", "250MB"
              | (?<suffix>bn|[kKMB])?
                (?![\p{L}\p{N}_])          # otherwise not glued to a word ("A1", "abc123")
            )
            (?!\.\d)                       # not the start of "1.2.3"
            (?<pct>\x20?%)?
            (?:\x20?(?<cur2>[$€£¥]))?
            (?:\x20(?<unit2>\#(spaced))(?![\p{L}\p{N}_]))?   # "12 kg", "380 EUR"
            (?<close>\))?
            """#, options: [.allowCommentsAndWhitespace]),
        exclusions: commonExclusions + [
            // US dates: 01/05/2024, 1/5/24
            #"(?<![\d/])\d{1,2}/\d{1,2}/\d{2,4}(?![\d/])"#,
            // Versions and IP addresses: 1.2.3, 192.168.0.1
            #"(?<![\d.])\d+(?:\.\d+){2,}(?!\.?\d)"#,
        ].map { try! NSRegularExpression(pattern: $0) }
    )

    private static let europeanPatterns = Patterns(
        number: try! NSRegularExpression(pattern: #"""
            (?<![\p{L}\p{N}_.,])
            (?<![\p{L}\p{N}][-−])
            (?<open>\()?
            (?:(?<code1>\#(codes))\x20?)?
            (?<sign1>[-−+])?
            (?:(?<cur1>[$€£¥])\x20?)?
            (?<sign2>[-−+])?
            (?<num>
                \d{1,3}(?:\.\d{3})+(?:,\d+)?   # 1.204 / 1.204,50
              | \d+(?:,\d+)?                  # 1204 / 1204,5
            )
            (?:
                (?<unit>\#(glued))(?![\p{L}\p{N}_])
              | (?<suffix>bn|[kKMB])?
                (?![\p{L}\p{N}_])
            )
            (?![.,]\d)                      # not part of "1.2.3" or "1,2,3"
            (?<pct>\x20?%)?
            (?:\x20?(?<cur2>[$€£¥]))?
            (?:\x20(?<unit2>\#(spaced))(?![\p{L}\p{N}_]))?
            (?<close>\))?
            """#, options: [.allowCommentsAndWhitespace]),
        exclusions: commonExclusions + [
            // European dates: 05.01.2024, 5/1/24
            #"(?<![\d.])\d{1,2}\.\d{1,2}\.\d{2,4}(?![\d.])"#,
            #"(?<![\d/])\d{1,2}/\d{1,2}/\d{2,4}(?![\d/])"#,
            // (Versions/IPs need no rule: "1.2.3" isn't a valid European number anyway.)
        ].map { try! NSRegularExpression(pattern: $0) }
    )

    /// Spans that look numeric but aren't quantities, in any format. Blanked out
    /// before matching.
    private static let commonExclusions: [NSRegularExpression] = [
        // ISO dates, optionally with time: 2024-01-05, 2024/01/05, 2024-01-05T10:30:00
        #"(?<!\d)\d{4}[-/]\d{1,2}[-/]\d{1,2}(?!\d)"#,
        // Times: 10:30, 10:30:15, 10:30:15.123
        #"(?<![\d:])\d{1,2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?(?![\d:])"#,
        // Phone numbers: (555) 123-4567, 555-123-4567, 555.123.4567, 555 123-4567
        #"(?<!\d)(?:\(\d{3}\)\s?|\d{3}[-.\s])\d{3}[-.]\d{4}(?!\d)"#,
    ].map { try! NSRegularExpression(pattern: $0) }
}
