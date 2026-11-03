import Foundation

/// Quick math on every number in a clip: "× 1.2", "+ 15%", "÷ 3", "round 2". Each number
/// is rewritten in place, keeping the text around it, its currency, unit and thousands
/// separators: "Flights $1,204.50" × 2 → "Flights $2,409.00".
public enum NumberMath {
    public enum Operation: Equatable, Sendable {
        case add(Decimal)
        case subtract(Decimal)
        case multiply(Decimal)
        case divide(Decimal)
        /// "+ 15%": increase by a percentage.
        case increasePercent(Decimal)
        /// "- 10%": decrease by a percentage.
        case decreasePercent(Decimal)
        /// "× 15%": take a percentage of each number.
        case percentOf(Decimal)
        case round(Int)

        public func apply(to value: Decimal) -> Decimal {
            switch self {
            case .add(let x): return value + x
            case .subtract(let x): return value - x
            case .multiply(let x): return value * x
            case .divide(let x): return value / x
            case .increasePercent(let p): return value * (1 + p / 100)
            case .decreasePercent(let p): return value * (1 - p / 100)
            case .percentOf(let p): return value * p / 100
            case .round(let digits): return NumberMath.rounded(value, digits)
            }
        }

        /// "Multiply each number by 1.2".
        public func title(format: NumberFormat = .us) -> String {
            func n(_ x: Decimal) -> String { NumberFormatting.grouped(x, maxFractionDigits: 6, format: format) }
            switch self {
            case .add(let x): return "Add \(n(x)) to each number"
            case .subtract(let x): return "Subtract \(n(x)) from each number"
            case .multiply(let x): return "Multiply each number by \(n(x))"
            case .divide(let x): return "Divide each number by \(n(x))"
            case .increasePercent(let p): return "Increase each number by \(n(p))%"
            case .decreasePercent(let p): return "Decrease each number by \(n(p))%"
            case .percentOf(let p): return "Take \(n(p))% of each number"
            case .round(let d): return d == 0 ? "Round each number to a whole number" : "Round each number to \(d) decimal\(d == 1 ? "" : "s")"
            }
        }
    }

    /// Reads what's typed after ">" in the command bar: "× 1.2", "*1.2", "x 1.2", "+ 5",
    /// "-10%", "/ 3", "÷3", "round 2", "round". Nil if it isn't quick math.
    public static func parse(_ command: String, format: NumberFormat = .us) -> Operation? {
        let text = command.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        if lower == "round" { return .round(0) }
        if lower.hasPrefix("round") {
            let rest = lower.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let digits = Int(rest), (0...10).contains(digits) else { return nil }
            return .round(digits)
        }
        guard let symbol = text.first else { return nil }
        let operand = text.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !operand.isEmpty, let number = NumberParser(format: format).parseWhole(operand),
              number.unit == nil || number.unit == "%" else { return nil }
        let value = number.value
        let percent = number.isPercent
        switch symbol {
        case "+": return percent ? .increasePercent(value) : .add(value)
        case "-", "−": return percent ? .decreasePercent(value) : .subtract(value)
        case "*", "×", "x", "X": return percent ? .percentOf(value) : .multiply(value)
        case "/", "÷":
            guard value != 0, !percent else { return nil }
            return .divide(value)
        default: return nil
        }
    }

    /// Applies `operation` to every number in `text`, rewriting each in place.
    public static func apply(_ operation: Operation, to text: String, format: NumberFormat = .us) throws -> String {
        let numbers = NumberParser(format: format).parse(text)
        guard !numbers.isEmpty else { throw TransformError.noNumbers }
        var result = text
        // Back to front, so earlier ranges stay valid while later text changes length.
        for number in numbers.reversed() {
            let newValue = operation.apply(to: number.value)
            result.replaceSubrange(number.range, with: rewrite(number, as: newValue, operation: operation, format: format))
        }
        return result
    }

    /// The number's original text with new digits: same currency, unit, grouping and
    /// sign style; at least as many decimals as before.
    static func rewrite(_ number: ParsedNumber, as value: Decimal, operation: Operation, format: NumberFormat) -> String {
        let fraction: Int
        if case .round(let digits) = operation {
            fraction = digits
        } else {
            fraction = max(number.fractionDigits, neededDigits(value / number.multiplier, max: 4))
        }
        let magnitude = abs(value / number.multiplier)
        let text16 = number.text.utf16
        guard let offsets = number.digitsOffsets, offsets.upperBound <= text16.count else {
            return (value < 0 ? "-" : "") + formatted(magnitude, fractionDigits: fraction, grouped: false, format: format)
        }
        var text = number.text
        let start = text16.index(text16.startIndex, offsetBy: offsets.lowerBound)
        let end = text16.index(text16.startIndex, offsetBy: offsets.upperBound)
        let grouped = text[start..<end].contains(format.groupingSeparator)
        text.replaceSubrange(start..<end, with: formatted(magnitude, fractionDigits: fraction, grouped: grouped, format: format))

        let wasNegative = number.value < 0
        let isNegative = value < 0
        if wasNegative && !isNegative {
            // Drop the minus sign or the accounting parentheses.
            text = text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            if let sign = text.firstIndex(where: { $0 == "-" || $0 == "−" }) { text.remove(at: sign) }
        } else if !wasNegative && isNegative {
            text = "-" + text
        }
        return text
    }

    /// Digits after the point needed to show `value` exactly, capped at `max`.
    static func neededDigits(_ value: Decimal, max: Int) -> Int {
        let text = NumberFormatting.machinePlain(value, maxFractionDigits: max)
        guard let dot = text.firstIndex(of: ".") else { return 0 }
        return text.distance(from: text.index(after: dot), to: text.endIndex)
    }

    static func rounded(_ value: Decimal, _ digits: Int) -> Decimal {
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, digits, .plain)
        return output
    }

    /// Exactly `fractionDigits` decimals, optionally with thousands separators.
    static func formatted(_ value: Decimal, fractionDigits: Int, grouped: Bool, format: NumberFormat) -> String {
        let base = grouped
            ? NumberFormatting.grouped(value, maxFractionDigits: fractionDigits, format: format)
            : NumberFormatting.plain(value, maxFractionDigits: fractionDigits, format: format)
        guard fractionDigits > 0 else { return base }
        let separator = Character(format.decimalSeparator)
        if let dot = base.firstIndex(of: separator) {
            let have = base.distance(from: base.index(after: dot), to: base.endIndex)
            return base + String(repeating: "0", count: max(0, fractionDigits - have))
        }
        return base + format.decimalSeparator + String(repeating: "0", count: fractionDigits)
    }
}
