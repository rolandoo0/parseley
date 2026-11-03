import Foundation

/// A parsed JSON document that keeps what Foundation's JSONSerialization loses: the order
/// of object keys (people read JSON top to bottom) and the exact text of numbers
/// (`1.10` stays `1.10`, big integers stay exact).
public indirect enum JSONValue: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    /// The number exactly as written in the source.
    case number(String)
    case bool(Bool)
    case null

    public var isContainer: Bool {
        switch self {
        case .object, .array: true
        default: false
        }
    }

    /// Number of direct children (members or elements); 0 for primitives.
    public var childCount: Int {
        switch self {
        case .object(let members): members.count
        case .array(let elements): elements.count
        default: 0
        }
    }
}

public struct JSONMember: Equatable, Sendable {
    public let key: String
    public let value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

public struct JSONParseError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public let line: Int
    public let column: Int

    public init(message: String, line: Int, column: Int) {
        self.message = message
        self.line = line
        self.column = column
    }

    public var description: String { "\(message) (line \(line), column \(column))" }
}

// MARK: - Parsing

extension JSONValue {
    /// Parses a complete JSON document. Leading/trailing whitespace is allowed; anything
    /// else after the value is an error.
    public static func parse(_ text: String, maxDepth: Int = 256) throws -> JSONValue {
        var parser = JSONTextParser(bytes: Array(text.utf8), maxDepth: maxDepth)
        return try parser.parseDocument()
    }
}

/// A small recursive-descent parser over UTF-8 bytes (RFC 8259).
private struct JSONTextParser {
    let bytes: [UInt8]
    let maxDepth: Int
    var index = 0
    var depth = 0

    init(bytes: [UInt8], maxDepth: Int) {
        // Skip a UTF-8 byte order mark, which some editors add.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            self.bytes = Array(bytes.dropFirst(3))
        } else {
            self.bytes = bytes
        }
        self.maxDepth = maxDepth
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw error("The text is empty") }
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("Unexpected text after the JSON value") }
        return value
    }

    private mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw error("Unexpected end of text") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectWord("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectWord("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectWord("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("Unexpected character")
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter()
        index += 1   // {
        var members: [JSONMember] = []
        skipWhitespace()
        if peek(UInt8(ascii: "}")) { index += 1; depth -= 1; return .object(members) }
        while true {
            skipWhitespace()
            guard peek(UInt8(ascii: "\"")) else { throw error("Expected a key in quotes") }
            let key = try parseString()
            skipWhitespace()
            guard peek(UInt8(ascii: ":")) else { throw error("Expected ':' after the key") }
            index += 1
            skipWhitespace()
            members.append(JSONMember(key, try parseValue()))
            skipWhitespace()
            if peek(UInt8(ascii: ",")) { index += 1; continue }
            if peek(UInt8(ascii: "}")) { index += 1; break }
            throw error("Expected ',' or '}'")
        }
        depth -= 1
        return .object(members)
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter()
        index += 1   // [
        var elements: [JSONValue] = []
        skipWhitespace()
        if peek(UInt8(ascii: "]")) { index += 1; depth -= 1; return .array(elements) }
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            if peek(UInt8(ascii: ",")) { index += 1; continue }
            if peek(UInt8(ascii: "]")) { index += 1; break }
            throw error("Expected ',' or ']'")
        }
        depth -= 1
        return .array(elements)
    }

    private mutating func parseString() throws -> String {
        index += 1   // opening quote
        var out: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    // A UTF-16 surrogate pair spells one character outside the BMP.
                    if (0xD800...0xDBFF).contains(scalar), peek(UInt8(ascii: "\\")),
                       index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try parseHex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                    }
                    let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(character).utf8))
                default:
                    index -= 1
                    throw error("Unknown escape \\\(Character(Unicode.Scalar(escape)))")
                }
            case 0x00...0x1F:
                throw error("Line breaks and tabs inside a string must be escaped")
            default:
                out.append(byte)
                index += 1
            }
        }
        throw error("Unterminated string")
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("Incomplete \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw error("Invalid \\u escape")
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        func digits() -> Bool {
            let begin = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            return index > begin
        }
        if peek(UInt8(ascii: "-")) { index += 1 }
        if peek(UInt8(ascii: "0")) {
            index += 1
        } else if !digits() {
            throw error("Invalid number")
        }
        if peek(UInt8(ascii: ".")) {
            index += 1
            guard digits() else { throw error("Expected digits after the decimal point") }
        }
        if peek(UInt8(ascii: "e")) || peek(UInt8(ascii: "E")) {
            index += 1
            if peek(UInt8(ascii: "+")) || peek(UInt8(ascii: "-")) { index += 1 }
            guard digits() else { throw error("Expected digits in the exponent") }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func expectWord(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw error("Unexpected character")
        }
        index += expected.count
    }

    private mutating func enter() throws {
        depth += 1
        if depth > maxDepth { throw error("Nested more than \(maxDepth) levels deep") }
    }

    private func peek(_ byte: UInt8) -> Bool { index < bytes.count && bytes[index] == byte }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    /// An error pointing at the current position, as a 1-based line and column.
    private func error(_ message: String) -> JSONParseError {
        var line = 1, column = 1
        for byte in bytes[0..<min(index, bytes.count)] {
            if byte == 0x0A { line += 1; column = 1 } else if byte & 0xC0 != 0x80 { column += 1 }
        }
        return JSONParseError(message: message, line: line, column: column)
    }
}

// MARK: - Writing

extension JSONValue {
    /// JSON text for this value. `pretty` indents with two spaces, one member per line.
    public func serialized(pretty: Bool = true) -> String {
        var out = ""
        write(into: &out, pretty: pretty, indent: 0)
        return out
    }

    private func write(into out: inout String, pretty: Bool, indent: Int) {
        let newline = pretty ? "\n" : ""
        let pad = { (level: Int) in pretty ? String(repeating: "  ", count: level) : "" }
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += Self.quoted(s)
        case .array(let elements):
            if elements.isEmpty { out += "[]"; return }
            out += "[" + newline
            for (i, element) in elements.enumerated() {
                out += pad(indent + 1)
                element.write(into: &out, pretty: pretty, indent: indent + 1)
                out += (i < elements.count - 1 ? "," : "") + newline
            }
            out += pad(indent) + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{" + newline
            for (i, member) in members.enumerated() {
                out += pad(indent + 1) + Self.quoted(member.key) + (pretty ? ": " : ":")
                member.value.write(into: &out, pretty: pretty, indent: indent + 1)
                out += (i < members.count - 1 ? "," : "") + newline
            }
            out += pad(indent) + "}"
        }
    }

    /// A JSON string literal with the required escapes.
    public static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
