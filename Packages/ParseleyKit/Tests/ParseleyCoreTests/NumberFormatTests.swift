import Foundation
import Testing
@testable import ParseleyCore

private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
private let eu = NumberParser(format: .european)
private func euValues(_ text: String) -> [Decimal] { eu.parse(text).map(\.value) }

@Suite struct EuropeanParsingTests {
    @Test(arguments: [
        ("1.204,50", "1204.5"),
        ("1.000.000", "1000000"),
        ("12,5", "12.5"),
        ("€1.204,50", "1204.5"),
        ("1.204,50 €", "1204.5"),
        ("-4,5", "-4.5"),
        ("(300)", "-300"),
        ("12,5%", "12.5"),
        ("1,2k", "1200"),
        ("42", "42"),
    ])
    func values(_ input: String, _ expected: String) {
        #expect(euValues(input) == [d(expected)])
    }

    @Test func columnFromGermanExcel() {
        #expect(euValues("1.204,50\n300\n(12,25)\n") == [d("1204.5"), 300, d("-12.25")])
    }

    @Test func semicolonAndSpaceLists() {
        #expect(euValues("1,5; 2,5; 3") == [d("1.5"), d("2.5"), 3])
        #expect(euValues("1,5 2,5") == [d("1.5"), d("2.5")])
    }

    @Test func digitsAreNormalizedAndFractionCounted() throws {
        let n = try #require(eu.parse("1.204,50").first)
        #expect(n.digits == "1204.50")
        #expect(n.fractionDigits == 2)
    }

    @Test(arguments: ["05.01.2024", "5.1.24", "2024-01-05", "10:30", "1.2.3", "192.168.0.1", "A1"])
    func nonQuantitiesSkipped(_ input: String) {
        #expect(euValues(input).isEmpty, "\(input) → \(euValues(input))")
    }

    @Test func usFormatStillDefault() {
        #expect(NumberParser().parse("1.204,50").map(\.value) == [d("1.204"), 50])
    }

    @Test func numbersOnlyWorksInEuropean() {
        #expect(eu.numbersOnly("1.204,50\n300")?.count == 2)
        #expect(eu.numbersOnly("Summe: 5") == nil)
    }
}

@Suite struct EuropeanFormattingTests {
    @Test func plainAndGrouped() {
        #expect(NumberFormatting.plain(d("1204.5"), format: .european) == "1204,5")
        #expect(NumberFormatting.grouped(d("-1234567.891"), format: .european) == "-1.234.567,891")
        #expect(NumberFormatting.grouped(d("999"), format: .european) == "999")
    }

    @Test func statsItemsInEuropeanFormat() throws {
        let s = try #require(NumberStats(values: [d("1204.5"), 300], inputFractionDigits: 1))
        let sum = try #require(s.items(format: .european).first { $0.label == "Sum" })
        #expect(sum.display == "1.504,5")
        #expect(sum.copyText == "1504,5")
    }

    @Test func primaryStatMovesToFront() throws {
        let s = try #require(NumberStats(values: [1, 2]))
        #expect(s.items(primary: "Average").map(\.label) == ["Average", "Count", "Sum", "Median", "Min", "Max"])
        #expect(s.items(primary: "Nope").map(\.label) == NumberStats.labels)
    }
}

@Suite struct EuropeanTransformTests {
    @Test func splitterKeepsDecimalCommas() {
        #expect(ItemSplitter.split("1,5, 2,5, 3", format: .european).items == ["1,5", "2,5", "3"])
        #expect(ItemSplitter.split("a,b", format: .european).items == ["a", "b"])
    }

    @Test func sqlAndJSONAlwaysUseDotDecimals() throws {
        #expect(try SQLInTransform(format: .european).apply("1.204,50\n12,5") == "IN (1204.5, 12.5)")
        #expect(try JSONArrayTransform(format: .european).apply("1,5\n2") == "[1.5, 2]")
    }

    @Test func sortReadsEuropeanValues() throws {
        #expect(try SortTransform(ascending: true, format: .european).apply("1.000\n2,5\n300") == "2,5\n300\n1.000")
    }

    @Test func plainNumbersKeepsDecimalComma() throws {
        #expect(try RemoveNumberFormattingTransform(format: .european).apply("€1.204,50 und 1,2k") == "1204,50 und 1200")
    }

    @Test func detectorUsesFormat() {
        #expect(TypeDetector(format: .european).detect("1.204,50\n300") == .numberList)
    }

    @Test func registryOrderingWithPins() {
        let ids = TransformRegistry.ordered(pinned: ["sql.in", "nope", "list.dedupe"]).map(\.id)
        #expect(ids == ["sql.in", "list.dedupe", "list.comma", "json.array", "sort.asc", "sort.desc", "text.clean", "number.plain"])
    }
}
