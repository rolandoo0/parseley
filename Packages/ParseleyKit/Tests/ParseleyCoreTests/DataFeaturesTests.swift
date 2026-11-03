import Foundation
import Testing
@testable import ParseleyCore

private func d(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Units: sums per unit")
struct UnitBreakdownTests {
    @Test func splitsSumsByUnit() {
        let numbers = NumberParser().parse("$1,204.50\n€380\n$100\n12 kg")
        let breakdown = UnitBreakdown(numbers)
        #expect(breakdown.units == ["USD", "EUR", "kg"])
        #expect(breakdown.isMixed)
        #expect(breakdown.groups.map(\.sum) == [d("1304.50"), 380, 12])
        #expect(breakdown.summary() == "$1,304.50 + €380.00 + 12 kg")
    }

    @Test func oneUnitIsNotMixed() {
        let breakdown = UnitBreakdown(NumberParser().parse("12 kg, 5 kg"))
        #expect(!breakdown.isMixed)
        #expect(breakdown.units == ["kg"])
    }

    @Test func convertsCurrenciesWithManualRates() {
        let breakdown = UnitBreakdown(NumberParser().parse("$100\n€50\n£10"))
        #expect(breakdown.converted(to: "USD", rates: ["EUR": d("1.10"), "GBP": d("1.25")]) == d("167.50"))
        #expect(breakdown.converted(to: "USD", rates: ["EUR": d("1.10")]) == nil)   // no GBP rate
        #expect(UnitBreakdown(NumberParser().parse("$5, 3 kg")).converted(to: "USD", rates: [:]) == nil)
    }

    @Test func displaysValuesWithUnits() {
        #expect(UnitBreakdown.display(d("-1204.5"), unit: "USD") == "-$1,204.50")
        #expect(UnitBreakdown.display(15, unit: "%", fractionDigits: 0) == "15%")
        #expect(UnitBreakdown.display(99, unit: "CHF", fractionDigits: 0) == "99 CHF")
    }
}

@Suite("Quick math")
struct NumberMathTests {
    @Test(arguments: [
        ("× 1.2", NumberMath.Operation.multiply(d("1.2"))), ("*2", .multiply(2)), ("x 3", .multiply(3)),
        ("+ 5", .add(5)), ("-10", .subtract(10)), ("− 1.5", .subtract(d("1.5"))),
        ("/ 4", .divide(4)), ("÷ 3", .divide(3)), ("+ 15%", .increasePercent(15)), ("- 10%", .decreasePercent(10)),
        ("× 20%", .percentOf(20)), ("round 2", .round(2)), ("round", .round(0)), ("ROUND 1", .round(1)),
    ])
    func parsesCommands(_ text: String, _ expected: NumberMath.Operation) {
        #expect(NumberMath.parse(text) == expected)
    }

    @Test(arguments: ["", "sum", "× ", "÷ 0", "/ 5%", "round x", "round 20", "+ 5 kg", "hello 5"])
    func rejectsOtherText(_ text: String) {
        #expect(NumberMath.parse(text) == nil)
    }

    @Test func rewritesNumbersInPlace() throws {
        let text = "Flights $1,204.50\nHotel 380\nTaxis (92.00)"
        #expect(try NumberMath.apply(.multiply(2), to: text) == "Flights $2,409.00\nHotel 760\nTaxis (184.00)")
        #expect(try NumberMath.apply(.increasePercent(10), to: "100\n19.50") == "110\n21.45")
        #expect(try NumberMath.apply(.round(1), to: "1.26, 3") == "1.3, 3.0")
        #expect(try NumberMath.apply(.divide(3), to: "10") == "3.3333")
        #expect(try NumberMath.apply(.add(1), to: "12 kg and 1.2k") == "13 kg and 1.201k")
    }

    @Test func handlesSignChanges() throws {
        #expect(try NumberMath.apply(.subtract(10), to: "$5") == "-$5.00".replacingOccurrences(of: ".00", with: ""))
        #expect(try NumberMath.apply(.add(400), to: "(300)") == "100")
        #expect(try NumberMath.apply(.multiply(-1), to: "-4") == "4")
    }

    @Test func europeanFormat() throws {
        #expect(try NumberMath.apply(.multiply(2), to: "1.204,50 €", format: .european) == "2.409,00 €")
        #expect(NumberMath.parse("× 1,5", format: .european) == .multiply(d("1.5")))
    }

    @Test func noNumbersIsAnError() {
        #expect(throws: TransformError.noNumbers) { try NumberMath.apply(.add(1), to: "no numbers here") }
    }

    @Test func titlesReadNaturally() {
        #expect(NumberMath.Operation.multiply(d("1.2")).title() == "Multiply each number by 1.2")
        #expect(NumberMath.Operation.increasePercent(15).title() == "Increase each number by 15%")
        #expect(NumberMath.Operation.round(0).title() == "Round each number to a whole number")
    }
}

@Suite("Spreadsheet shapes")
struct SpreadsheetTransformTests {
    @Test func listToColumnAndRow() throws {
        #expect(try AsColumnTransform().apply("1, 2, 3") == "1\n2\n3")
        #expect(try AsRowTransform().apply("1\n2\n3") == "1\t2\t3")
    }

    @Test func tableCellsFlatten() throws {
        #expect(try AsColumnTransform().apply("a\tb\nc\td") == "a\nb\nc\nd")
    }

    @Test func transposesTables() throws {
        #expect(try TransposeTransform().apply("Region\tQ1\tQ2\nNorth\t1\t2\nSouth\t3\t4") == "Region\tNorth\tSouth\nQ1\t1\t3\nQ2\t2\t4")
        #expect(try TransposeTransform().apply("1\n2\n3") == "1\t2\t3")
        #expect(try TransposeTransform().apply("a,b,c\nd,e") == "a\td\nb\te\nc\t")
    }

    @Test func registeredButNotButtons() {
        let ids = TransformRegistry.all.map(\.id)
        #expect(TransformRegistry.pasteShapes.isSubset(of: Set(ids)))
    }
}

@Suite("Insights: outliers and gaps")
struct NumberInsightsTests {
    @Test func findsOutliers() {
        let insights = NumberInsights(values: [120, 118, 125, 9_850, 119, 122, d("0.5")])
        #expect(insights.outliers == [9_850, d("0.5")])
        #expect(insights.outlierIndices == [3, 6])
    }

    @Test func noOutliersInTightOrSmallSets() {
        #expect(NumberInsights(values: [10, 11, 12, 13, 14]).outliers.isEmpty)
        #expect(NumberInsights(values: [1, 1_000]).outliers.isEmpty)
    }

    @Test func findsGapsInSequences() {
        #expect(NumberInsights(values: [1001, 1002, 1004, 1005, 1007, 1006, 1008, 1009]).gaps == [1003])
        #expect(NumberInsights(values: [1, 2, 3, 5, 6, 7, 8, 9, 10, 12]).gaps == [4, 11])
    }

    @Test func noGapsInAmounts() {
        #expect(NumberInsights(values: [120, 45, 300, 18]).gaps.isEmpty)
        #expect(NumberInsights(values: [1, 2, 3, d("4.5"), 6]).gaps.isEmpty)
        #expect(NumberInsights(values: [1, 2, 3, 4]).gaps.isEmpty)
    }
}

@Suite("Data table (CSV/TSV)")
struct DataTableTests {
    @Test func parsesCSVWithQuotesAndHeader() throws {
        let csv = "name,city,total\n\"Rivera, Ana\",Lisbon,1204.50\nBo,\"New\nYork\",\"3,000\"\n"
        let table = try #require(DataTable.parse(csv))
        #expect(table.delimiter == .comma)
        #expect(table.hasHeader)
        #expect(table.header == ["name", "city", "total"])
        #expect(table.rows == [["Rivera, Ana", "Lisbon", "1204.50"], ["Bo", "New\nYork", "3,000"]])
        #expect(table.isNumeric(2))
        #expect(!table.isNumeric(0))
        #expect(table.stats(for: 2)?.sum == d("4204.50"))
    }

    @Test func detectsDelimiters() throws {
        #expect(DataTable.parse("a\tb\n1\t2")?.delimiter == .tab)
        #expect(DataTable.parse("a;b\n1,5;2,5", format: .european)?.delimiter == .semicolon)
        #expect(DataTable.parse("a|b|c\n1|2|3")?.delimiter == .pipe)
        #expect(DataTable.parse("just one line, here") == nil)
        #expect(DataTable.parse("no\ndelimiters") == nil)
    }

    @Test func noHeaderWhenFirstRowIsData() throws {
        let table = try #require(DataTable.parse("1,2\n3,4"))
        #expect(!table.hasHeader)
        #expect(table.header == ["Column 1", "Column 2"])
        #expect(table.rows.count == 2)
    }

    @Test func sortsNumericallyAndAlphabetically() throws {
        let table = try #require(DataTable.parse("item,qty\nitem 10,5\nItem 2,40\nitem 1,\nitem 3,100"))
        #expect(table.sorted(by: 1, ascending: false).rows.map { $0[1] } == ["100", "40", "5", ""])
        #expect(table.sorted(by: 0, ascending: true).rows.map { $0[0] } == ["item 1", "Item 2", "item 3", "item 10"])
    }

    @Test func filtersAndExports() throws {
        let table = try #require(DataTable.parse("name,city\nAna,Lisbon\nBo,\"Porto, PT\""))
        #expect(table.filtered("lis").rows == [["Ana", "Lisbon"]])
        #expect(table.filtered("").rows.count == 2)
        #expect(table.export(columns: [1], as: .csv) == "city\nLisbon\n\"Porto, PT\"")
        #expect(table.export(as: .tsv, includeHeader: false) == "Ana\tLisbon\nBo\tPorto, PT")
    }
}

@Suite("Snippets")
struct SnippetTests {
    @Test func findsFieldsInOrder() {
        let snippet = Snippet(name: "x", body: "SELECT * FROM {table} WHERE {column} {clipboard|sql.in} -- {table}")
        #expect(snippet.fields == ["table", "column"])
        #expect(snippet.usesClipboard)
    }

    @Test func rendersFieldsAndPipes() throws {
        let snippet = Snippet(name: "x", body: "SELECT * FROM {table} WHERE id {clipboard|text.clean|sql.in};")
        let text = try snippet.render(clipboard: " 3\n1\n2 ", values: ["table": "orders"])
        #expect(text == "SELECT * FROM orders WHERE id IN (3, 1, 2);")
    }

    @Test func literalBracesAndMissingValues() throws {
        let snippet = Snippet(name: "x", body: "{{\"total\": {clipboard}}} {missing}")
        #expect(try snippet.render(clipboard: "42") == "{\"total\": 42} ")
    }

    @Test func unknownTransformIsReported() {
        let snippet = Snippet(name: "x", body: "{clipboard|nope}")
        #expect(throws: Snippet.RenderError.unknownTransform("nope")) { try snippet.render(clipboard: "1") }
    }

    @Test func startersRender() throws {
        for snippet in SnippetLibrary.starters {
            let values = Dictionary(uniqueKeysWithValues: snippet.fields.map { ($0, "x") })
            _ = try snippet.render(clipboard: "1\n2", values: values)
        }
    }
}
