import Foundation
import Testing
@testable import ParseleyCore

/// Helper: parse and return just the values as Decimals.
private func values(_ text: String) -> [Decimal] {
    NumberParser().parse(text).map(\.value)
}

private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

@Suite struct NumberParserBasicsTests {
    @Test(arguments: [
        ("42", "42"),
        ("-4.5", "-4.5"),
        ("+7", "7"),
        ("0.25", "0.25"),
        (".5", "0.5"),
        ("007", "7"),
        ("1204.50", "1204.5"),
        ("−3", "-3"),                 // Unicode minus sign
    ])
    func plainNumbers(_ input: String, _ expected: String) {
        #expect(values(input) == [d(expected)])
    }

    @Test(arguments: [
        ("$1,204.50", "1204.5"),
        ("$1,000,000", "1000000"),
        ("1,204", "1204"),
        ("€99.99", "99.99"),
        ("£5", "5"),
        ("¥1,000", "1000"),
        ("$ 12", "12"),
        ("100€", "100"),
        ("-$5.25", "-5.25"),
        ("$-5.25", "-5.25"),
    ])
    func currencyAndThousands(_ input: String, _ expected: String) {
        #expect(values(input) == [d(expected)])
    }

    @Test(arguments: [
        ("(300)", "-300"),
        ("($1,204.50)", "-1204.5"),
        ("(12.5%)", "-12.5"),
        ("(-5)", "-5"),               // already negative: stays negative, not double-negated
    ])
    func parenthesesMeanNegative(_ input: String, _ expected: String) {
        #expect(values(input) == [d(expected)])
    }

    @Test func percentKeepsItsValueAndIsFlagged() throws {
        let n = try #require(NumberParser().parse("12%").first)
        #expect(n.value == 12)
        #expect(n.isPercent)
        #expect(values("12 %") == [12])
        #expect(values("-4.5%") == [d("-4.5")])
    }

    @Test(arguments: [
        ("1.2k", "1200"),
        ("1.2K", "1200"),
        ("3M", "3000000"),
        ("2.5B", "2500000000"),
        ("$4bn", "4000000000"),
        ("-1.5k", "-1500"),
        ("(2k)", "-2000"),
    ])
    func magnitudeSuffixes(_ input: String, _ expected: String) {
        #expect(values(input) == [d(expected)])
    }

    @Test func currencySymbolIsRecorded() throws {
        #expect(NumberParser().parse("$5").first?.currencySymbol == "$")
        #expect(NumberParser().parse("5").first?.currencySymbol == nil)
    }

    @Test func keepsMatchedTextAndRange() throws {
        let text = "Total: $1,204.50 due"
        let n = try #require(NumberParser().parse(text).first)
        #expect(n.text == "$1,204.50")
        #expect(String(text[n.range]) == "$1,204.50")
    }

    @Test func fractionDigitsAreRecorded() {
        #expect(NumberParser().parse("1.50").first?.fractionDigits == 2)
        #expect(NumberParser().parse("3").first?.fractionDigits == 0)
    }
}

@Suite struct NumberParserListsTests {
    @Test func newlineSeparated() {
        #expect(values("10\n20\n30") == [10, 20, 30])
    }

    @Test func excelColumnWithCRLFAndTrailingNewline() {
        #expect(values("1,204.50\r\n300\r\n(12)\r\n") == [d("1204.5"), 300, -12])
    }

    @Test func googleSheetsColumnWithCurrency() {
        #expect(values("$1,000.00\n$2,500.50\n-$100.00\n") == [1000, d("2500.5"), -100])
    }

    @Test func currencyOnNextLineBelongsToNextNumber() throws {
        let found = NumberParser().parse("$1,204.50\n$300")
        #expect(found.map(\.text) == ["$1,204.50", "$300"])
        #expect(found.map(\.currencySymbol) == ["$", "$"])
        #expect(NumberParser().parse("5\n%").map(\.isPercent) == [false])
    }

    @Test func tabSeparated() {
        #expect(values("1\t2\t3") == [1, 2, 3])
    }

    @Test func commaSeparatedWithAndWithoutSpaces() {
        #expect(values("1,2,3") == [1, 2, 3])
        #expect(values("1, 2, 3") == [1, 2, 3])
        #expect(values("1.5,2.5") == [d("1.5"), d("2.5")])
    }

    @Test func commaListOfThousands() {
        // "1,000, 2,000" → thousands separators inside, list separators between.
        #expect(values("1,000, 2,000, 3,500") == [1000, 2000, 3500])
    }

    @Test func spaceSeparated() {
        #expect(values("4 8 15 16 23 42") == [4, 8, 15, 16, 23, 42])
    }

    @Test func semicolonsAndPipes() {
        #expect(values("1;2;3") == [1, 2, 3])
        #expect(values("1 | 2 | 3") == [1, 2, 3])
    }

    @Test func tableWithHeaderRow() {
        let table = "Region\tQ1\tQ2\nNorth\t$1,200\t$1,500\nSouth\t(300)\t450\n"
        #expect(values(table) == [1200, 1500, -300, 450])
    }

    @Test func blankLinesAreIgnored() {
        #expect(values("\n\n1\n\n\n2\n") == [1, 2])
    }
}

@Suite struct NumberParserMessyTextTests {
    @Test func numbersInProse() {
        #expect(values("Revenue grew 12% to $1.2M, up from $980k last year.") == [12, 1_200_000, 980_000])
    }

    @Test func labelsWithColons() {
        #expect(values("Subtotal: 100\nTax: 8.25\nTotal: 108.25") == [100, d("8.25"), d("108.25")])
    }

    @Test(arguments: [
        "abc123",          // glued to letters
        "A1",
        "SKU-1234",        // hyphenated identifier
        "COVID-19",
        "5kg",             // unit glued on
        "3Mbps",
        "1e5",
        "file_2",
    ])
    func identifiersAreNotNumbers(_ input: String) {
        #expect(values(input).isEmpty, "\(input) → \(values(input))")
    }

    @Test(arguments: [
        "2024-01-05",
        "2024-01-05T10:30:00",
        "01/05/2024",
        "1/5/24",
        "10:30",
        "10:30:15",
        "version 1.2.3",
        "192.168.0.1",
        "(555) 123-4567",
        "555-123-4567",
        "555.123.4567",
    ])
    func datesTimesVersionsIPsAndPhonesAreSkipped(_ input: String) {
        #expect(values(input).isEmpty, "\(input) → \(values(input))")
    }

    @Test func skipsDateButKeepsAmountOnSameLine() {
        #expect(values("2024-01-05\t$1,250.00") == [1250])
        #expect(values("Paid 120 on 3/14/2024 at 9:15") == [120])
    }

    @Test func standaloneOpenOrCloseParenIsNotNegative() {
        #expect(values("f(3)") == [3])
        #expect(values("(3") == [3])
        #expect(values("3)") == [3])
    }

    @Test func emptyAndNonNumericInput() {
        #expect(values("").isEmpty)
        #expect(values("   \n\t").isEmpty)
        #expect(values("hello world").isEmpty)
        #expect(values("$").isEmpty)
        #expect(values("-").isEmpty)
        #expect(values("%").isEmpty)
        #expect(values("...").isEmpty)
    }

    @Test func trailingSentencePunctuationIsFine() {
        #expect(values("It cost 40.") == [40])
        #expect(values("Is it 40?") == [40])
        #expect(values("We have 3, 4, and 5!") == [3, 4, 5])
    }

    @Test func largeAndPreciseValuesStayExact() {
        // Decimal, not Double: no 0.1 + 0.2 = 0.30000000000000004 surprises.
        #expect(values("0.1\n0.2") == [d("0.1"), d("0.2")])
        #expect(values("12345678901234567.89") == [d("12345678901234567.89")])
    }
}

@Suite struct NumberParserWholeValueTests {
    @Test(arguments: ["42", " $1,204.50 ", "(300)", "12%", "1.2k", "-4.5"])
    func parsesWholeStringAsOneNumber(_ input: String) {
        #expect(NumberParser().parseWhole(input) != nil)
    }

    @Test(arguments: ["", "abc", "42 apples", "1 2", "2024-01-05", "$", "1,2"])
    func rejectsAnythingElse(_ input: String) {
        #expect(NumberParser().parseWhole(input) == nil)
    }
}
