import Foundation

/// Things worth a second look in a list of numbers: values far from the rest (outliers)
/// and missing numbers in what looks like a sequence (invoice 1001, 1002, 1004…).
public struct NumberInsights: Equatable, Sendable {
    /// Positions (in the input order) of values outside 1.5 × IQR of the middle half.
    public let outlierIndices: [Int]
    /// The outlier values, in input order.
    public let outliers: [Decimal]
    /// Whole numbers missing from a mostly complete run, smallest first (at most 50).
    public let gaps: [Decimal]

    public var isEmpty: Bool { outliers.isEmpty && gaps.isEmpty }

    /// Fewer values than this and "outlier" doesn't mean much.
    public static let minimumForOutliers = 5
    public static let minimumForGaps = 4

    public init(values: [Decimal]) {
        // Outliers: Tukey's fences on the quartiles.
        if values.count >= Self.minimumForOutliers {
            let sorted = values.sorted()
            let half = sorted.count / 2
            let q1 = Self.median(Array(sorted[..<half]))
            let q3 = Self.median(Array(sorted[(sorted.count - half)...]))
            let iqr = q3 - q1
            let low = q1 - iqr * Decimal(string: "1.5")!
            let high = q3 + iqr * Decimal(string: "1.5")!
            let indices = values.indices.filter { values[$0] < low || values[$0] > high }
            outlierIndices = indices
            outliers = indices.map { values[$0] }
        } else {
            outlierIndices = []
            outliers = []
        }

        // Gaps: whole numbers that are mostly consecutive.
        let unique = Array(Set(values)).sorted()
        if unique.count >= Self.minimumForGaps, unique.allSatisfy(Self.isWhole),
           let first = unique.first, let last = unique.last {
            let span = NSDecimalNumber(decimal: last - first).intValue + 1
            let missing = span - unique.count
            // A mostly complete run: at most a third missing, and not absurdly long.
            if missing > 0, missing * 3 <= unique.count, span <= 100_000 {
                var gaps: [Decimal] = []
                var expected = first
                for value in unique {
                    while expected < value, gaps.count < 50 {
                        gaps.append(expected)
                        expected += 1
                    }
                    expected = value + 1
                }
                self.gaps = gaps
            } else {
                gaps = []
            }
        } else {
            gaps = []
        }
    }

    static func median(_ sorted: [Decimal]) -> Decimal {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func isWhole(_ value: Decimal) -> Bool {
        var input = value, rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        return rounded == value
    }
}
