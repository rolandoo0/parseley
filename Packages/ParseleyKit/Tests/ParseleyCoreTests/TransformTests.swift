import Foundation
import Testing
@testable import ParseleyCore

private func run(_ t: some Transform, _ input: String) throws -> String {
    try t.apply(input)
}

// MARK: - Splitting

@Suite struct ItemSplitterTests {
    @Test func linesWinOverOtherSeparators() {
        let s = ItemSplitter.split("a, b\nc d\n\ne\n")
        #expect(s.items == ["a, b", "c d", "e"])
        #expect(s.separator == .newline)
    }

    @Test func windowsLineEndings() {
        #expect(ItemSplitter.split("a\r\nb\r\n").items == ["a", "b"])
    }

    @Test func singleLineTabs() {
        let s = ItemSplitter.split("a\tb\t c ")
        #expect(s.items == ["a", "b", "c"])
        #expect(s.separator == .tab)
    }

    @Test func singleLineCommasRespectThousands() {
        let s = ItemSplitter.split("$1,204.50, 300,7")
        #expect(s.items == ["$1,204.50", "300", "7"])
        #expect(s.separator == .comma)
    }

    @Test func commaThousandsOnlyWhenExactlyThreeDigitsFollow() {
        #expect(ItemSplitter.split("1,2345").items == ["1", "2345"])
        #expect(ItemSplitter.split("1,000").items == ["1,000"])
        #expect(ItemSplitter.split("1,000,000,2").items == ["1,000,000", "2"])
    }

    @Test func semicolons() {
        let s = ItemSplitter.split("a; b;c")
        #expect(s.items == ["a", "b", "c"])
        #expect(s.separator == .semicolon)
    }

    @Test func spaces() {
        let s = ItemSplitter.split("  a   b c ")
        #expect(s.items == ["a", "b", "c"])
        #expect(s.separator == .space)
    }

    @Test func singleItemAndEmpty() {
        #expect(ItemSplitter.split("hello").items == ["hello"])
        #expect(ItemSplitter.split("").items.isEmpty)
        #expect(ItemSplitter.split(" \n \n").items.isEmpty)
    }

    @Test func unquote() {
        #expect(ItemSplitter.unquote("'a'") == "a")
        #expect(ItemSplitter.unquote("\"a b\"") == "a b")
        #expect(ItemSplitter.unquote("'a\"") == "'a\"")
        #expect(ItemSplitter.unquote("'") == "'")
        #expect(ItemSplitter.unquote("it's") == "it's")
    }
}

// MARK: - Individual transforms

@Suite struct CommaListTransformTests {
    let t = CommaListTransform()

    @Test func fromColumn() throws {
        #expect(try run(t, "a\nb\nc\n") == "a, b, c")
    }

    @Test func fromSpacesAndTabs() throws {
        #expect(try run(t, "1 2 3") == "1, 2, 3")
        #expect(try run(t, "1\t2") == "1, 2")
    }

    @Test func keepsNumberFormatting() throws {
        #expect(try run(t, "$1,204.50\n300") == "$1,204.50, 300")
    }

    @Test func singleItem() throws {
        #expect(try run(t, "solo") == "solo")
    }

    @Test func emptyThrows() {
        #expect(throws: TransformError.noItems) { try run(t, "  \n ") }
    }
}

@Suite struct SQLInTransformTests {
    let t = SQLInTransform()

    @Test func stringsAreQuoted() throws {
        #expect(try run(t, "apple\nbanana") == "IN ('apple', 'banana')")
    }

    @Test func numbersAreNotQuotedAndAreNormalized() throws {
        #expect(try run(t, "1\n2\n3") == "IN (1, 2, 3)")
        #expect(try run(t, "$1,204.50\n(300)\n12%") == "IN (1204.5, -300, 12)")
    }

    @Test func mixedListQuotesEverything() throws {
        #expect(try run(t, "42\nabc") == "IN ('42', 'abc')")
    }

    @Test func escapesSingleQuotes() throws {
        #expect(try run(t, "O'Brien\nD'Arcy") == "IN ('O''Brien', 'D''Arcy')")
    }

    @Test func alreadyQuotedItemsAreNotDoubleQuoted() throws {
        #expect(try run(t, "'a', 'b'") == "IN ('a', 'b')")
        #expect(try run(t, "\"a\"\n\"b\"") == "IN ('a', 'b')")
    }

    @Test func idsWithLeadingZerosStayStrings() throws {
        // Zip codes / ids: "00123" as a number would lose its zeros.
        #expect(try run(t, "00123\n00456") == "IN ('00123', '00456')")
    }

    @Test func emptyThrows() {
        #expect(throws: TransformError.noItems) { try run(t, "") }
    }
}

@Suite struct JSONArrayTransformTests {
    let t = JSONArrayTransform()

    @Test func strings() throws {
        #expect(try run(t, "a\nb") == #"["a", "b"]"#)
    }

    @Test func numbers() throws {
        #expect(try run(t, "1\n2.5\n-3") == "[1, 2.5, -3]")
        #expect(try run(t, "$1,000\n(5)") == "[1000, -5]")
    }

    @Test func mixedBecomesStrings() throws {
        #expect(try run(t, "1\nx") == #"["1", "x"]"#)
    }

    @Test func escapesSpecialCharacters() throws {
        #expect(try run(t, "say \"hi\"\tok") == #"["say \"hi\"", "ok"]"#)
        #expect(try run(t, #"C:\path"#) == #"["C:\\path"]"#)
    }

    @Test func outputIsValidJSON() throws {
        let out = try run(t, "a\"b\nc\\d\né🙂")
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String]
        #expect(parsed == ["a\"b", "c\\d", "é🙂"])
    }

    @Test func emptyThrows() {
        #expect(throws: TransformError.noItems) { try run(t, "\n") }
    }
}

@Suite struct SortTransformTests {
    @Test func numericAscendingKeepsOriginalFormatting() throws {
        #expect(try run(SortTransform(ascending: true), "$1,000\n(5)\n20\n3.5") == "(5)\n3.5\n20\n$1,000")
    }

    @Test func numericDescending() throws {
        #expect(try run(SortTransform(ascending: false), "10\n9\n100") == "100\n10\n9")
    }

    @Test func numericNotLexicographic() throws {
        #expect(try run(SortTransform(ascending: true), "10, 9, 100") == "9, 10, 100")
    }

    @Test func textIsCaseInsensitiveAndNatural() throws {
        #expect(try run(SortTransform(ascending: true), "banana\nApple\ncherry") == "Apple\nbanana\ncherry")
        #expect(try run(SortTransform(ascending: true), "file10\nfile2\nfile1") == "file1\nfile2\nfile10")
        #expect(try run(SortTransform(ascending: false), "b a c") == "c b a")
    }

    @Test func preservesSeparatorStyle() throws {
        #expect(try run(SortTransform(ascending: true), "c\tb\ta") == "a\tb\tc")
        #expect(try run(SortTransform(ascending: true), "c; a") == "a; c")
    }

    @Test func isStableForEqualValues() throws {
        #expect(try run(SortTransform(ascending: true), "$5\n1\n5.00") == "1\n$5\n5.00")
    }

    @Test func emptyThrows() {
        #expect(throws: TransformError.noItems) { try run(SortTransform(ascending: true), "") }
    }
}

@Suite struct DedupeTransformTests {
    let t = DedupeTransform()

    @Test func keepsFirstOccurrenceInOrder() throws {
        #expect(try run(t, "b\na\nb\nc\na") == "b\na\nc")
    }

    @Test func comparesTrimmedItems() throws {
        #expect(try run(t, "a\n  a  \nb") == "a\nb")
    }

    @Test func isCaseSensitive() throws {
        #expect(try run(t, "a\nA") == "a\nA")
    }

    @Test func worksOnCommaLists() throws {
        #expect(try run(t, "1, 2, 1, 3") == "1, 2, 3")
    }

    @Test func emptyThrows() {
        #expect(throws: TransformError.noItems) { try run(t, " ") }
    }
}

@Suite struct CleanWhitespaceTransformTests {
    let t = CleanWhitespaceTransform()

    @Test func trimsLinesCollapsesSpacesDropsBlankLines() throws {
        #expect(try run(t, "  hello    world  \n\n\n  second   line \n") == "hello world\nsecond line")
    }

    @Test func keepsTabsBetweenColumns() throws {
        #expect(try run(t, " a\t b \n c \td ") == "a\tb\nc\td")
    }

    @Test func normalizesOddSpacesAndRemovesZeroWidthCharacters() throws {
        #expect(try run(t, "a\u{00A0}\u{00A0}b\u{200B}c\u{FEFF}") == "a bc")
    }

    @Test func normalizesLineEndings() throws {
        #expect(try run(t, "a\r\nb\rc") == "a\nb\nc")
    }

    @Test func allWhitespaceThrows() {
        #expect(throws: TransformError.noItems) { try run(t, " \n\t ") }
    }
}

@Suite struct RemoveNumberFormattingTransformTests {
    let t = RemoveNumberFormattingTransform()

    @Test func stripsCurrencyAndThousands() throws {
        #expect(try run(t, "$1,204.50\n$300") == "1204.50\n300")
    }

    @Test func parenthesesBecomeMinus() throws {
        #expect(try run(t, "($1,204.50)") == "-1204.50")
    }

    @Test func expandsSuffixes() throws {
        #expect(try run(t, "1.2k and 3M") == "1200 and 3000000")
    }

    @Test func keepsPercentSign() throws {
        #expect(try run(t, "growth 12%") == "growth 12%")
    }

    @Test func leavesOtherTextAlone() throws {
        #expect(try run(t, "Total: $1,000 on 2024-01-05 (approx)") == "Total: 1000 on 2024-01-05 (approx)")
    }

    @Test func keepsTrailingZerosAsTyped() throws {
        #expect(try run(t, "$5.00") == "5.00")
    }

    @Test func noNumbersThrows() {
        #expect(throws: TransformError.noNumbers) { try run(t, "hello") }
    }
}

// MARK: - Registry & chaining

@Suite struct TransformRegistryTests {
    @Test func idsAreUniqueAndStable() {
        let ids = TransformRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids == ["list.comma", "sql.in", "json.array", "sort.asc", "sort.desc",
                        "list.dedupe", "text.clean", "number.plain", "paste.column", "paste.row", "table.transpose"])
    }

    @Test func lookupByID() {
        #expect(TransformRegistry.transform(id: "sql.in")?.title == "SQL IN")
        #expect(TransformRegistry.transform(id: "nope") == nil)
    }

    @Test func chainRunsStepsInOrder() throws {
        let chain = TransformChain(steps: [DedupeTransform(), SortTransform(ascending: true), SQLInTransform()])
        #expect(try chain.apply("3\n1\n3\n2") == "IN (1, 2, 3)")
        #expect(chain.id == "list.dedupe>sort.asc>sql.in")
    }

    @Test func chainStopsAtFirstError() {
        let chain = TransformChain(steps: [CleanWhitespaceTransform(), SQLInTransform()])
        #expect(throws: TransformError.noItems) { try chain.apply("   ") }
    }
}
