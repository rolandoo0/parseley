import Foundation

/// Summary statistics over a list of numbers. Exact decimal arithmetic throughout.
public struct NumberStats: Equatable, Sendable {
    public let count: Int
    public let sum: Decimal
    public let mean: Decimal
    public let median: Decimal
    public let min: Decimal
    public let max: Decimal
    /// Most decimal places among the inputs as written. Used to pick display precision.
    public let inputFractionDigits: Int

    /// Nil for an empty list.
    public init?(values: [Decimal], inputFractionDigits: Int = 0) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        count = values.count
        sum = values.reduce(0, +)
        mean = sum / Decimal(count)
        let mid = count / 2
        median = count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        min = sorted[0]
        max = sorted[count - 1]
        self.inputFractionDigits = inputFractionDigits
    }

    /// Stats over every number `NumberParser` finds in `text`. Nil if there are none.
    public init?(text: String, parser: NumberParser = NumberParser()) {
        let numbers = parser.parse(text)
        self.init(values: numbers.map(\.value), inputFractionDigits: numbers.map(\.fractionDigits).max() ?? 0)
    }

    /// One entry of the stats strip.
    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String { label }
        public let label: String
        public let value: Decimal
        /// For display, with thousands separators: "1,204.5".
        public let display: String
        /// What gets copied: plain digits, ready for a spreadsheet or code: "1204.5".
        public let copyText: String
    }

    /// Count, sum, average, median, min, max, in display order.
    public var items: [Item] {
        // Sums/medians of the inputs need at most a little more precision than the
        // inputs themselves; averages can repeat forever (1/3), so cap them.
        let exactDigits = Swift.max(inputFractionDigits + 1, 2)
        let meanDigits = Swift.min(Swift.max(inputFractionDigits + 2, 2), 10)
        func item(_ label: String, _ value: Decimal, _ digits: Int) -> Item {
            Item(
                label: label, value: value,
                display: NumberFormatting.grouped(value, maxFractionDigits: digits),
                copyText: NumberFormatting.plain(value, maxFractionDigits: digits)
            )
        }
        return [
            item("Count", Decimal(count), 0),
            item("Sum", sum, exactDigits),
            item("Average", mean, meanDigits),
            item("Median", median, exactDigits),
            item("Min", min, exactDigits),
            item("Max", max, exactDigits),
        ]
    }
}

/// Decimal → string, locale-independent (always "." for decimals, "," for thousands).
public enum NumberFormatting {
    /// "1204.5": rounded (half away from zero) to at most `maxFractionDigits`, no
    /// trailing zeros, no thousands separators.
    public static func plain(_ value: Decimal, maxFractionDigits: Int = 6) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, maxFractionDigits, .plain)
        // Decimal's description is locale-independent and never uses exponent notation.
        let text = rounded.description
        return text == "-0" ? "0" : text
    }

    /// "1,204.5": like `plain`, with thousands separators.
    public static func grouped(_ value: Decimal, maxFractionDigits: Int = 6) -> String {
        let text = plain(value, maxFractionDigits: maxFractionDigits)
        let negative = text.hasPrefix("-")
        let unsigned = negative ? String(text.dropFirst()) : text
        let parts = unsigned.split(separator: ".", maxSplits: 1)
        let integer = Array(parts[0])
        var groupedInteger = ""
        for (i, ch) in integer.enumerated() {
            if i > 0 && (integer.count - i) % 3 == 0 { groupedInteger.append(",") }
            groupedInteger.append(ch)
        }
        let fraction = parts.count > 1 ? "." + parts[1] : ""
        return (negative ? "-" : "") + groupedInteger + fraction
    }
}
