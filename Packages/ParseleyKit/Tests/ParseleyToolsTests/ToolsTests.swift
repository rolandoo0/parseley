import Foundation
import Testing
import ParseleyCore
import ParseleyStorage
@testable import ParseleyTools

/// Thread-safe test clock: one minute per tick.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_700_000_000)
    func tick() -> Date { lock.lock(); defer { lock.unlock() }; t += 60; return t }
}

/// A real database file, written the way the app writes it, then opened read-only.
final class FixtureDatabase {
    let directory: URL
    let path: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("parseley.sqlite").path

        let database = try ParseleyDatabase(path: path)          // read-write, migrates
        let clock = Clock()
        let clips = try GRDBClipStore(database: database, now: { clock.tick() })
        try clips.insert(NewClip(content: "apples and pears", kind: .text, sourceBundleID: "com.apple.Notes"))
        try clips.insert(NewClip(content: "$1,204.50\n300\n(12)", kind: .numberList, sourceBundleID: "com.microsoft.Excel"))
        try clips.insert(NewClip(content: "10\n20", kind: .numberList, sourceBundleID: "com.microsoft.Excel"))

        let tracker = SeriesTracker(store: GRDBSeriesStore(database: database))
        tracker.start(name: "Q3")
        tracker.ingest(content: "5\n7", clipID: nil, sourceBundleID: "com.microsoft.Excel")
        tracker.stop()
    }

    func open(_ path: String?) throws -> Toolbox { try Toolbox.open(path: path ?? self.path) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@Suite struct CLITests {
    let db: FixtureDatabase
    init() throws { db = try FixtureDatabase() }

    func run(_ args: [String], stdin: String? = nil) -> CLI.Output {
        CLI.run(args, stdin: stdin, openToolbox: db.open)
    }

    @Test func helpAndUnknownCommand() {
        #expect(run([]).stdout.contains("USAGE"))
        let bad = run(["frobnicate"])
        #expect(bad.code == 1)
        #expect(bad.stderr.contains("Unknown command"))
    }

    @Test func recentListsNewestFirstWithSums() {
        let out = run(["recent", "-n", "2"])
        #expect(out.code == 0)
        let lines = out.stdout.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("10") && lines[0].contains("(Σ 30)"))
        #expect(lines[1].contains("$1,204.50"))
    }

    @Test func recentAsJSON() throws {
        let out = run(["recent", "--json"])
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [[String: Any]])
        #expect(rows.count == 3)
        #expect(rows[0]["number_sum"] as? String == "30")
        #expect(rows[0]["app"] as? String == "com.microsoft.Excel")
    }

    @Test func searchAndGet() {
        #expect(run(["search", "apple"]).stdout.contains("apples and pears"))
        #expect(run(["get", "1"]).stdout == "apples and pears")
        #expect(run(["get", "999"]).code == 1)
        #expect(run(["get"]).stderr.contains("parseley get <id>"))
    }

    @Test func statsAndSumFromStdinClipOrLatest() {
        #expect(run(["sum"], stdin: "1\n2\n3.5").stdout == "6.5")
        #expect(run(["sum", "2"]).stdout == "1492.5")
        #expect(run(["sum"]).stdout == "30")                  // latest clip
        #expect(run(["sum", "--eu"], stdin: "1.000,5\n2").stdout == "1002,5")
        let stats = run(["stats"], stdin: "$1,204.50\n300\n(12)").stdout
        #expect(stats.contains("Sum      1,492.5"))
        #expect(stats.contains("Max      1,204.5"))
        #expect(run(["sum"], stdin: "no numbers here").code == 1)
    }

    @Test func statsJSONUsesExactStrings() throws {
        let out = run(["stats", "--json"], stdin: "0.1\n0.2")
        let dict = try #require(try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        #expect(dict["sum"] as? String == "0.3")
        #expect(dict["count"] as? Int == 2)
    }

    @Test func transforms() {
        #expect(run(["transform", "sql.in"], stdin: "b\na\nb").stdout == "IN ('b', 'a', 'b')")
        #expect(run(["transform", "sort.asc", "3"]).stdout == "10\n20")
        #expect(run(["transform", "nope"], stdin: "x").stderr.contains("Unknown transform"))
        #expect(run(["transforms"]).stdout.contains("json.array"))
    }

    @Test func seriesListing() {
        let out = run(["series"]).stdout
        #expect(out.contains("Q3 · Σ 12 · 2 values · ended"))
    }

    @Test func sqlOverViews() {
        let out = run(["sql", "SELECT app, SUM(value) AS total FROM numbers GROUP BY app ORDER BY total DESC"])
        #expect(out.code == 0, "\(out.stderr)")
        #expect(out.stdout.contains("com.microsoft.Excel"))
        #expect(out.stdout.contains("1522.5"))
        let series = run(["sql", "SELECT series_name, SUM(value) FROM series_values GROUP BY series_id"])
        #expect(series.stdout.contains("Q3") && series.stdout.contains("12"))
        #expect(run(["sql"]).stdout.contains("Views:"))
    }

    @Test func sqlIsReadOnly() {
        for statement in ["DELETE FROM clip", "DROP TABLE clip", "INSERT INTO clip (content) VALUES ('x')",
                          "SELECT 1; DELETE FROM clip", "PRAGMA writable_schema = 1",
                          "ATTACH DATABASE '/tmp/x' AS x", "/* sneaky */ DELETE FROM clip"] {
            let out = run(["sql", statement])
            #expect(out.code == 1, "\(statement) should be refused")
        }
        #expect(run(["recent", "--json"]).stdout.contains("apples"), "history untouched")
        #expect(run(["sql", "-- comment\nWITH x AS (SELECT 1 AS n) SELECT n FROM x"]).code == 0)
    }

    @Test func missingDatabaseExplainsWhatToDo() {
        let out = CLI.run(["recent", "--db", "/nonexistent/x.sqlite"])
        #expect(out.code == 1)
        #expect(out.stderr.contains("Run the app first"))
    }
}

@Suite struct MCPServerTests {
    let db: FixtureDatabase
    let server: MCPServer

    init() throws {
        let db = try FixtureDatabase()
        self.db = db
        server = MCPServer(openToolbox: { try db.open(nil) })
    }

    func send(_ object: [String: Any]) throws -> [String: Any] {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let response = try #require(server.handle(line))
        return try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    func callTool(_ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let response = try send(["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                 "params": ["name": name, "arguments": arguments]])
        let result = try #require(response["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    @Test func initializeEchoesProtocolVersion() throws {
        let response = try send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                 "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "test"]]])
        #expect(response["id"] as? Int == 1)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "parseley")
    }

    @Test func notificationsGetNoReply() {
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(server.handle("") == nil)
    }

    @Test func listsReadOnlyTools() throws {
        let response = try send(["jsonrpc": "2.0", "id": "a", "method": "tools/list"])
        #expect(response["id"] as? String == "a")
        let tools = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String ?? "" } ==
                ["recent_clips", "search_clips", "get_clip", "number_stats", "transform_text", "list_series", "query_sql"])
    }

    @Test func toolsWork() throws {
        #expect(try callTool("search_clips", ["query": "pears"]).text.contains("apples and pears"))
        #expect(try callTool("get_clip", ["id": 2]).text.contains("$1,204.50"))
        #expect(try callTool("number_stats", ["text": "1\n2"]).text.contains("\"sum\" : \"3\""))
        #expect(try callTool("transform_text", ["text": "b\na", "transform": "sort.asc"]).text == "a\nb")
        #expect(try callTool("list_series").text.contains("\"name\" : \"Q3\""))
        #expect(try callTool("query_sql", ["sql": "SELECT COUNT(*) AS n FROM clips"]).text.contains("\"3\""))
    }

    @Test func toolErrorsAreResultsNotProtocolErrors() throws {
        let missing = try callTool("get_clip", ["id": 999])
        #expect(missing.isError)
        #expect(try callTool("query_sql", ["sql": "DELETE FROM clip"]).isError)
        #expect(try callTool("number_stats", [:]).text.contains("Missing"))
    }

    @Test func unknownMethodAndBadJSON() throws {
        let response = try send(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32601)
        let bad = try #require(server.handle("{not json"))
        #expect(bad.contains("-32700"))
    }
}
