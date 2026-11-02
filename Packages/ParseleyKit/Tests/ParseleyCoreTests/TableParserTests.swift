import Foundation
import Testing
@testable import ParseleyCore

private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

@Suite struct TableParserTests {
    @Test func headerRowAndNumericColumns() throws {
        let t = try #require(TableParser.parse("Region\tQ1\tQ2\nNorth\t$1,200\t$1,500\nSouth\t(300)\t450\n"))
        #expect(t.hasHeader)
        #expect(t.rowCount == 2)
        #expect(t.columns.map(\.name) == ["Region", "Q1", "Q2"])
        #expect(t.numericColumns.map(\.name) == ["Q1", "Q2"])
        #expect(t.columns[1].values == [1200, -300])
        #expect(t.columns[2].stats?.sum == 1950)
        #expect(t.columns[0].isNumeric == false)
    }

    @Test func noHeaderUsesLetters() throws {
        let t = try #require(TableParser.parse("1\t2\t3\n4\t5\t6"))
        #expect(!t.hasHeader)
        #expect(t.columns.map(\.name) == ["A", "B", "C"])
        #expect(t.columns.map { $0.stats?.sum } == [5, 7, 9])
    }

    @Test func letterNamesBeyondZ() {
        #expect(TableColumn.letters(for: 0) == "A")
        #expect(TableColumn.letters(for: 25) == "Z")
        #expect(TableColumn.letters(for: 26) == "AA")
        #expect(TableColumn.letters(for: 27) == "AB")
        #expect(TableColumn.letters(for: 701) == "ZZ")
        #expect(TableColumn.letters(for: 702) == "AAA")
    }

    @Test func raggedRowsAndEmptyCells() throws {
        let t = try #require(TableParser.parse("Item\tQty\tPrice\nA\t2\t1.50\nB\t\t2.00\nC\t5"))
        #expect(t.columns[1].values == [2, 5])
        #expect(t.columns[1].filledCells == 2)
        #expect(t.columns[2].values == [d("1.5"), 2])
    }

    @Test func mostlyTextColumnIsNotNumeric() throws {
        let t = try #require(TableParser.parse("Name\tCode\nAlice\tA1\nBob\t7\nCara\tX9"))
        #expect(t.columns[1].values == [7])
        #expect(t.columns[1].isNumeric == false)   // 1 of 3 cells
    }

    @Test func europeanFormat() throws {
        let t = try #require(TableParser.parse("Monat\tBetrag\nJan\t1.204,50\nFeb\t300", format: .european))
        #expect(t.columns[1].values == [d("1204.5"), 300])
    }

    @Test(arguments: ["just text", "1\n2\n3", "a\tb", "", "\n\n"])
    func notATable(_ input: String) {
        #expect(TableParser.parse(input) == nil)
    }

    @Test func allTextGridHasNoHeaderAndNoNumericColumns() throws {
        let t = try #require(TableParser.parse("a\tb\nc\td"))
        #expect(!t.hasHeader)
        #expect(t.numericColumns.isEmpty)
    }

    @Test func windowsLineEndings() throws {
        let t = try #require(TableParser.parse("X\tY\r\n1\t2\r\n3\t4\r\n"))
        #expect(t.hasHeader)
        #expect(t.columns.map(\.values) == [[1, 3], [2, 4]])
    }
}
