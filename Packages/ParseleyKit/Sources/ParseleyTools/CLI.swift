import Foundation
import ParseleyCore
import ParseleyStorage

/// The `parseley` command line, as a pure function so it can be unit-tested:
/// arguments + optional piped stdin in, stdout/stderr text and exit code out.
public enum CLI {
    public struct Output: Equatable {
        public var stdout = ""
        public var stderr = ""
        public var code: Int32 = 0
    }

    public static let usage = """
        parseley: your Parseley clipboard history from the terminal (read-only).

        USAGE
          parseley recent [-n 20] [--json]          Latest clips
          parseley search <text> [-n 20] [--json]   Clips containing text
          parseley get <id>                         Print a clip's full text
          parseley stats [<id>] [--eu] [--json]     Count, sum, average, median, min, max
          parseley sum [<id>] [--eu]                Just the sum
          parseley transform <name> [<id>] [--eu]   Apply a transform (see `transforms`)
          parseley transforms                       List transform names
          parseley series [-n 10] [--json]          Running and past series
          parseley sql "<SELECT …>" [--json]        Read-only SQL (see `parseley sql --help`)
          parseley mcp                              Run the MCP server on stdin/stdout

        stats / sum / transform read piped input if there is any, else clip <id>, else the
        latest clip:   pbpaste | parseley sum     parseley transform sql.in 42

        OPTIONS
          --db <path>   History database (default: ~/Library/Application Support/Parseley/parseley.sqlite)
          --eu          Read numbers as 1.204,50 instead of 1,204.50
          --json        Machine-readable output
        """

    static let sqlHelp = """
        Read-only SQL over your history (SQLite). Views:
          clips(id, content, kind, app, created_at, last_used_at, pinned, note,
                number_count, number_sum, number_sum_exact)
          numbers(clip_id, position, value, value_exact, app, created_at)
          series_list(id, name, created_at, ended_at)
          series_values(series_id, series_name, entry_id, app, created_at, value, value_exact)

        Examples:
          parseley sql "SELECT app, ROUND(SUM(value), 2) FROM numbers GROUP BY app ORDER BY 2 DESC"
          parseley sql "SELECT series_name, SUM(value) FROM series_values GROUP BY series_id"
          parseley sql "SELECT id, substr(content, 1, 40) FROM clips WHERE kind = 'numberList' LIMIT 10"
        """

    /// - Parameters:
    ///   - stdin: piped input, or nil when stdin is a terminal.
    ///   - openToolbox: opens the history (injected so tests can use a temp database).
    public static func run(
        _ arguments: [String], stdin: String? = nil,
        openToolbox: (String?) throws -> Toolbox = { try Toolbox.open(path: $0) }
    ) -> Output {
        var args = Arguments(arguments)
        let json = args.flag("--json")
        let format: NumberFormat = args.flag("--eu") ? .european : .us
        let dbPath = args.option("--db")
        let limit = args.option("-n").flatMap(Int.init)
        let command = args.positional.first ?? "help"
        let rest = Array(args.positional.dropFirst())

        do {
            switch command {
            case "help", "--help", "-h":
                return Output(stdout: usage)

            case "transforms":
                let lines = TransformRegistry.all.map { "\($0.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \($0.title)" }
                return Output(stdout: lines.joined(separator: "\n"))

            case "stats", "sum":
                let text = try input(stdin: stdin, idArgument: rest.first, dbPath: dbPath, open: openToolbox)
                guard let stats = Toolbox.stats(of: text, format: format) else { throw ToolError.noNumbers }
                let items = stats.items(format: format)
                if command == "sum" {
                    return Output(stdout: items.first { $0.label == "Sum" }?.copyText ?? "")
                }
                if json { return Output(stdout: JSONShape.string(JSONShape.stats(stats))) }
                return Output(stdout: items.map { "\($0.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \($0.display)" }
                    .joined(separator: "\n"))

            case "transform":
                guard let name = rest.first else { throw ToolError.usage("parseley transform <name> [<id>]: see `parseley transforms`") }
                let text = try input(stdin: stdin, idArgument: rest.dropFirst().first, dbPath: dbPath, open: openToolbox)
                return Output(stdout: try Toolbox.transform(text, with: name, format: format))

            case "recent", "search":
                let toolbox = try openToolbox(dbPath)
                let rows: [ClipSummary]
                if command == "search" {
                    guard let text = rest.first else { throw ToolError.usage("parseley search <text>") }
                    rows = try toolbox.search(text, limit: limit ?? 20)
                } else {
                    rows = try toolbox.recent(limit: limit ?? 20)
                }
                if json { return Output(stdout: JSONShape.string(rows.map(JSONShape.summary))) }
                return Output(stdout: rows.map(line).joined(separator: "\n"))

            case "get":
                guard let id = rest.first.flatMap(Int64.init) else { throw ToolError.usage("parseley get <id>") }
                guard let clip = try openToolbox(dbPath).clip(id: id) else { throw ToolError.notFound("Clip \(id)") }
                if json { return Output(stdout: JSONShape.string(JSONShape.clip(clip))) }
                return Output(stdout: clip.content)

            case "series":
                let list = try openToolbox(dbPath).series(limit: limit ?? 10)
                if json { return Output(stdout: JSONShape.string(list.map(JSONShape.series))) }
                return Output(stdout: list.map { s in
                    let sum = s.stats?.items(format: format).first { $0.label == "Sum" }?.display ?? "0"
                    let state = s.endedAt == nil ? "running" : "ended"
                    return "\(s.name) · Σ \(sum) · \(s.values.count) values · \(state) · \(JSONShape.iso(s.createdAt))"
                }.joined(separator: "\n"))

            case "sql":
                guard let query = rest.first, query != "--help" else { return Output(stdout: sqlHelp) }
                let result = try openToolbox(dbPath).sql(query)
                var output = Output(stdout: json ? JSONShape.string(JSONShape.query(result)) : table(result))
                if result.truncated { output.stderr = "(showing the first \(result.rows.count) rows)" }
                return output

            default:
                throw ToolError.usage("Unknown command \"\(command)\".\n\n\(usage)")
            }
        } catch {
            return Output(stderr: "parseley: \(error)", code: 1)
        }
    }

    // MARK: - Helpers

    /// Piped text, else clip <id>, else the latest clip.
    private static func input(stdin: String?, idArgument: String?, dbPath: String?,
                              open: (String?) throws -> Toolbox) throws -> String {
        if let idArgument {
            guard let id = Int64(idArgument) else { throw ToolError.usage("Expected a clip id, got \"\(idArgument)\"") }
            guard let clip = try open(dbPath).clip(id: id) else { throw ToolError.notFound("Clip \(id)") }
            return clip.content
        }
        if let stdin, !stdin.isEmpty { return stdin }
        guard let clip = try open(dbPath).latestClip() else { throw ToolError.notFound("Any clip") }
        return clip.content
    }

    /// "42  numberList  $1,204.50  (Σ 1492.5)"
    private static func line(_ row: ClipSummary) -> String {
        var text = "\(String(row.id).padding(toLength: 6, withPad: " ", startingAt: 0))\(row.kind.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))\(row.title)"
        if row.numberCount >= 2, let sum = row.numberSum { text += "  (Σ \(sum))" }
        return text
    }

    /// A simple aligned text table.
    static func table(_ result: QueryResult) -> String {
        guard !result.columns.isEmpty else { return "" }
        let cells = result.rows.map { $0.map { ($0 ?? "NULL").replacingOccurrences(of: "\n", with: "⏎") } }
        let widths = result.columns.indices.map { i in
            min(40, max(result.columns[i].count, cells.map { $0[i].count }.max() ?? 0))
        }
        func render(_ row: [String]) -> String {
            row.enumerated().map { i, value in
                let clipped = value.count > widths[i] ? String(value.prefix(widths[i] - 1)) + "…" : value
                return clipped.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        let header = render(result.columns)
        let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")
        return ([header, rule] + cells.map(render)).joined(separator: "\n")
    }
}

/// Minimal argument parsing: flags (--json), options (--db x, -n 5) and positionals.
struct Arguments {
    private var items: [String]
    init(_ items: [String]) { self.items = items }

    mutating func flag(_ name: String) -> Bool {
        guard let i = items.firstIndex(of: name) else { return false }
        items.remove(at: i)
        return true
    }

    mutating func option(_ name: String) -> String? {
        guard let i = items.firstIndex(of: name), i + 1 < items.count else { return nil }
        let value = items[i + 1]
        items.removeSubrange(i...(i + 1))
        return value
    }

    var positional: [String] { items }
}
