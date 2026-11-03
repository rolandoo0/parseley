import Foundation

/// A saved text template with fields, e.g. `SELECT * FROM {table} WHERE id {clipboard|sql.in};`
///
/// - `{clipboard}` is the selected clip's text.
/// - `{name}` is a field you fill in when using the snippet.
/// - `|transform` pipes a value through transforms by id (`{clipboard|text.clean|sql.in}`).
/// - `{{` and `}}` write literal braces.
public struct Snippet: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var body: String

    public init(id: String = UUID().uuidString, name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }

    public static let clipboardField = "clipboard"

    /// Fields to ask for, in order of first appearance (`clipboard` isn't one).
    public var fields: [String] {
        var seen: [String] = []
        for token in Self.tokens(body) {
            if case .field(let name, _) = token, name != Self.clipboardField, !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    /// True if the body uses `{clipboard}`.
    public var usesClipboard: Bool {
        Self.tokens(body).contains { if case .field(let name, _) = $0 { name == Self.clipboardField } else { false } }
    }

    public enum RenderError: Error, Equatable, Sendable {
        case unknownTransform(String)
        case transformFailed(String, String)

        public var message: String {
            switch self {
            case .unknownTransform(let id): "Unknown transform \"\(id)\""
            case .transformFailed(let id, let why): "\(id): \(why)"
            }
        }
    }

    /// The finished text. Missing field values are left empty.
    public func render(clipboard: String, values: [String: String] = [:], format: NumberFormat = .us) throws -> String {
        var out = ""
        for token in Self.tokens(body) {
            switch token {
            case .text(let text):
                out += text
            case .field(let name, let pipes):
                var value = name == Self.clipboardField ? clipboard : (values[name] ?? "")
                for id in pipes {
                    guard let transform = TransformRegistry.transform(id: id, format: format) else {
                        throw RenderError.unknownTransform(id)
                    }
                    do {
                        value = try transform.apply(value)
                    } catch let error as TransformError {
                        throw RenderError.transformFailed(id, error.message)
                    }
                }
                out += value
            }
        }
        return out
    }

    enum Token: Equatable {
        case text(String)
        case field(String, pipes: [String])
    }

    static func tokens(_ body: String) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var chars = Array(body)[...]
        while let ch = chars.first {
            chars = chars.dropFirst()
            if ch == "{" && chars.first == "{" { text.append("{"); chars = chars.dropFirst(); continue }
            if ch == "}" && chars.first == "}" { text.append("}"); chars = chars.dropFirst(); continue }
            if ch == "{", let close = chars.firstIndex(of: "}") {
                let inside = String(chars[chars.startIndex..<close])
                let parts = inside.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if let name = parts.first, !name.isEmpty, !name.contains("{"), !name.contains("\n") {
                    if !text.isEmpty { tokens.append(.text(text)); text = "" }
                    tokens.append(.field(name, pipes: parts.dropFirst().filter { !$0.isEmpty }))
                    chars = chars[chars.index(after: close)...]
                    continue
                }
            }
            text.append(ch)
        }
        if !text.isEmpty { tokens.append(.text(text)) }
        return tokens
    }
}

public struct SnippetLibrary: Equatable, Codable, Sendable {
    public var snippets: [Snippet]

    public init(snippets: [Snippet] = SnippetLibrary.starters) {
        self.snippets = snippets
    }

    public static let starters: [Snippet] = [
        Snippet(id: "starter.sql-ids", name: "SQL: rows by id",
                body: "SELECT * FROM {table} WHERE id {clipboard|text.clean|list.dedupe|sql.in};"),
        Snippet(id: "starter.total-line", name: "Total line",
                body: "Total for {period}: {clipboard}"),
        Snippet(id: "starter.markdown-link", name: "Markdown link",
                body: "[{title}]({clipboard})"),
    ]

    public mutating func upsert(_ snippet: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[i] = snippet } else { snippets.append(snippet) }
    }

    public mutating func remove(id: String) { snippets.removeAll { $0.id == id } }
}
