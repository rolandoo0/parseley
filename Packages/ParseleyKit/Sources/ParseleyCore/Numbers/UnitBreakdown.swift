import Foundation

/// Sums per unit, so "$1,204.50 + €380 + 12 kg" isn't silently added up as 1,596.50.
/// Numbers without a unit count with whichever unit the rest share; they're kept apart
/// only when the clip mixes several units.
public struct UnitBreakdown: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        /// Nil for bare numbers.
        public let unit: String?
        public let sum: Decimal
        public let count: Int
        /// Most digits after the decimal point among the inputs (for display).
        public let fractionDigits: Int
    }

    /// One group per unit, in order of first appearance.
    public let groups: [Group]

    public init(_ numbers: [ParsedNumber]) {
        var order: [String?] = []
        var sums: [String?: (Decimal, Int, Int)] = [:]
        for n in numbers {
            if sums[n.unit] == nil { order.append(n.unit) }
            let current = sums[n.unit] ?? (0, 0, 0)
            sums[n.unit] = (current.0 + n.value, current.1 + 1, max(current.2, n.fractionDigits))
        }
        groups = order.map { unit in
            let (sum, count, digits) = sums[unit]!
            return Group(unit: unit, sum: sum, count: count, fractionDigits: digits)
        }
    }

    /// Distinct units (bare numbers not included).
    public var units: [String] { groups.compactMap(\.unit) }

    /// More than one unit: a plain sum would add apples and oranges.
    public var isMixed: Bool { units.count >= 2 }

    /// The total in `base`, converting currencies with `rates` (1 unit = rate × base).
    /// Nil unless every number is a currency with a known rate (or already in `base`).
    public func converted(to base: String, rates: [String: Decimal]) -> Decimal? {
        guard !groups.isEmpty else { return nil }
        var total: Decimal = 0
        for group in groups {
            guard let unit = group.unit, NumberUnits.currencyCodes.contains(unit) else { return nil }
            let rate: Decimal? = unit == base ? 1 : rates[unit]
            guard let rate else { return nil }
            total += group.sum * rate
        }
        return total
    }

    /// "$1,204.50 + €380 + 12 kg".
    public func summary(format: NumberFormat = .us) -> String {
        groups.map { group in
            // Money always shows cents; other units as many decimals as their inputs had.
            let isMoney = group.unit.map(NumberUnits.currencyCodes.contains) ?? false
            return Self.display(group.sum, unit: group.unit,
                                fractionDigits: isMoney ? max(2, group.fractionDigits) : group.fractionDigits, format: format)
        }
            .joined(separator: " + ")
    }

    /// A value with its unit the way people write it: "$1,204.50", "€380", "12 kg",
    /// "15%", "99 CHF".
    public static func display(_ value: Decimal, unit: String?, fractionDigits: Int = 2, format: NumberFormat = .us) -> String {
        let number = (value < 0 ? "-" : "") + NumberMath.formatted(abs(value), fractionDigits: fractionDigits, grouped: true, format: format)
        guard let unit else { return number }
        if unit == "%" { return number + "%" }
        if let symbol = symbols[unit] {
            return number.hasPrefix("-") ? "-" + symbol + number.dropFirst() : symbol + number
        }
        return number + " " + unit
    }

    static let symbols: [String: String] = ["USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥"]
}
