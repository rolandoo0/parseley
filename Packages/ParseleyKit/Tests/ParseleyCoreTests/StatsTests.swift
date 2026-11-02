import Foundation
import Testing
import ParseleyCore

private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

@Suite struct NumberStatsTests {
    @Test func emptyHasNoStats() {
        #expect(NumberStats(values: []) == nil)
    }

    @Test func singleValue() throws {
        let s = try #require(NumberStats(values: [5]))
        #expect(s.count == 1)
        #expect(s.sum == 5)
        #expect(s.mean == 5)
        #expect(s.median == 5)
        #expect(s.min == 5)
        #expect(s.max == 5)
    }

    @Test func oddCount() throws {
        let s = try #require(NumberStats(values: [3, 1, 2]))
        #expect(s.count == 3)
        #expect(s.sum == 6)
        #expect(s.mean == 2)
        #expect(s.median == 2)
        #expect(s.min == 1)
        #expect(s.max == 3)
    }

    @Test func evenCountMedianAveragesMiddleTwo() throws {
        let s = try #require(NumberStats(values: [4, 1, 3, 2]))
        #expect(s.median == d("2.5"))
    }

    @Test func negativesAndDecimalsAreExact() throws {
        let s = try #require(NumberStats(values: [d("0.1"), d("0.2"), d("-1204.5")]))
        #expect(s.sum == d("-1204.2"))
        #expect(s.min == d("-1204.5"))
        #expect(s.max == d("0.2"))
    }

    @Test func meanOfRepeatingDecimal() throws {
        let s = try #require(NumberStats(values: [1, 1, 2]))
        // 4/3: compare rounded, Decimal carries ~38 significant digits.
        #expect(NumberFormatting.plain(s.mean, maxFractionDigits: 4) == "1.3333")
    }

    @Test func buildsFromText() throws {
        let s = try #require(NumberStats(text: "$1,204.50\n300\n(12)"))
        #expect(s.count == 3)
        #expect(s.sum == d("1492.5"))
    }
}

@Suite struct NumberStatsItemsTests {
    @Test func stripItemsInOrderWithDisplayAndCopyText() throws {
        let s = try #require(NumberStats(text: "$1,204.50\n300\n(12)"))
        let items = s.items
        #expect(items.map(\.label) == ["Count", "Sum", "Average", "Median", "Min", "Max"])
        #expect(items.map(\.display) == ["3", "1,492.5", "497.5", "300", "-12", "1,204.5"])
        #expect(items.map(\.copyText) == ["3", "1492.5", "497.5", "300", "-12", "1204.5"])
    }

    @Test func averageIsRoundedButSumStaysExact() throws {
        let s = try #require(NumberStats(text: "1\n1\n2"))
        let byLabel = Dictionary(uniqueKeysWithValues: s.items.map { ($0.label, $0.copyText) })
        #expect(byLabel["Average"] == "1.33")
        #expect(byLabel["Sum"] == "4")
    }

    @Test func bigNumbersGetGrouped() throws {
        let s = try #require(NumberStats(text: "1.2M\n3M"))
        #expect(s.items.first { $0.label == "Sum" }?.display == "4,200,000")
    }
}

@Suite struct NumberFormattingTests {
    @Test(arguments: [
        ("1204.5", 6, "1204.5"),
        ("1000000", 6, "1000000"),
        ("-0.25", 6, "-0.25"),
        ("1.333333333333", 4, "1.3333"),
        ("2.5", 0, "3"),           // rounds half away from zero (.plain)
        ("-2.5", 0, "-3"),
        ("1.10", 6, "1.1"),        // no trailing zeros
        ("0", 2, "0"),
    ])
    func plain(_ input: String, _ digits: Int, _ expected: String) {
        #expect(NumberFormatting.plain(d(input), maxFractionDigits: digits) == expected)
    }

    @Test(arguments: [
        ("1204.5", "1,204.5"),
        ("-1234567.891", "-1,234,567.891"),
        ("999", "999"),
        ("0.5", "0.5"),
    ])
    func grouped(_ input: String, _ expected: String) {
        #expect(NumberFormatting.grouped(d(input)) == expected)
    }
}
