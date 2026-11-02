import Testing
@testable import ParseleyCore

// Swift Testing: `@Test` marks a test; `arguments:` runs it once per input (a
// parameterized test, each case reported separately). `#expect` records a failure but
// keeps going; `#require` stops the test.

@Suite struct TypeDetectorTests {
    let detector = TypeDetector()

    @Test(arguments: [
        "https://example.com",
        "http://example.com/path?q=1#frag",
        "  https://example.com/  \n",
        "www.example.com",
        "ftp://files.example.com/x.zip",
        "file:///Users/me/notes.txt",
    ])
    func urls(_ input: String) {
        #expect(detector.detect(input) == .url)
    }

    @Test(arguments: [
        "https://",              // no host
        "example.com",           // no scheme, no www
        "javascript:alert(1)",   // unsupported scheme
        "see https://example.com for details", // prose containing a URL
        "www.",
    ])
    func notURLs(_ input: String) {
        #expect(detector.detect(input) != .url)
    }

    @Test(arguments: ["me@example.com", "first.last+tag@sub.example.co.uk"])
    func emails(_ input: String) {
        #expect(detector.detect(input) == .email)
    }

    @Test(arguments: ["me@", "@example.com", "me@example", "a@b@c.com", "me@.com", "me@example.", "me@ex..com"])
    func notEmails(_ input: String) {
        #expect(detector.detect(input) != .email)
    }

    @Test(arguments: [
        #"{"a": 1}"#,
        #"[1, 2, 3]"#,
        "{\n  \"nested\": {\"b\": [true, null]}\n}",
        "  []  ",
    ])
    func json(_ input: String) {
        #expect(detector.detect(input) == .json)
    }

    @Test(arguments: [
        "{not json}",
        "[1, 2,",
        "\"just a string\"",
        "42",
    ])
    func notJSON(_ input: String) {
        #expect(detector.detect(input) != .json)
    }

    @Test(arguments: [
        "name\tage\nalice\t30\nbob\t25",
        "a\tb\r\nc\td\r\n",          // Windows line endings, trailing newline
        "a\t\tc\nd\te\tf",            // empty cell keeps column count
    ])
    func tables(_ input: String) {
        #expect(detector.detect(input) == .table)
    }

    @Test(arguments: [
        "a\tb",                        // single row
        "a\tb\nc",                     // ragged
        "a\tb\nc\td\te",               // ragged
        "one\ntwo\nthree",             // single column (numbers handled in M3)
    ])
    func notTables(_ input: String) {
        #expect(detector.detect(input) != .table)
    }

    @Test(arguments: ["42", "$1,204.50", "(300)", "12%", " 1.2k \n"])
    func singleNumber(_ input: String) {
        #expect(detector.detect(input) == .number)
    }

    @Test(arguments: [
        "1\n2\n3",
        "$1,204.50\r\n300\r\n(12)\r\n",
        "1, 2, 3",
        "4 8 15 16",
        "1;2|3",
    ])
    func numberLists(_ input: String) {
        #expect(detector.detect(input) == .numberList)
    }

    @Test(arguments: [
        "Total: 5",
        "12 apples, 3 pears",
        "2024-01-05",          // dates aren't numbers
        "1.2.3",
    ])
    func textWithNumbersIsStillText(_ input: String) {
        #expect(detector.detect(input) == .text)
    }

    @Test func numericSpreadsheetRangeIsATable() {
        #expect(detector.detect("1\t2\n3\t4") == .table)
    }

    @Test(arguments: ["", "   ", "\n\t", "hello world", "multi\nline\ntext"])
    func plainText(_ input: String) {
        #expect(detector.detect(input) == .text)
    }
}

@Suite struct ContentHashTests {
    @Test func knownVectors() {
        // Reference values for 64-bit FNV-1a.
        #expect(ContentHash.of("") == "cbf29ce484222325")
        #expect(ContentHash.of("a") == "af63dc4c8601ec8c")
        #expect(ContentHash.of("foobar") == "85944171f73967e8")
    }

    @Test func isFixedWidthAndDistinguishesInputs() {
        #expect(ContentHash.of("hello").count == 16)
        #expect(ContentHash.of("hello") != ContentHash.of("hello "))
        #expect(ContentHash.of("é") == ContentHash.of("é"))
    }
}

@Suite struct ClipKindTests {
    @Test func unknownStoredValueFallsBackToText() {
        #expect(ClipKind(storedValue: "hologram") == .text)
        #expect(ClipKind(storedValue: "json") == .json)
    }
}
