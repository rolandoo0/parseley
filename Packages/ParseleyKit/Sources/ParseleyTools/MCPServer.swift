import Foundation
import ParseleyCore
import ParseleyStorage

/// A Model Context Protocol server over stdio, so AI assistants (Claude Desktop, Claude
/// Code, …) can read your Parseley history: search clips, get stats, run transforms and
/// read-only SQL. It never writes to the history or the clipboard, and it runs only
/// when the assistant launches `parseley mcp` on your Mac.
///
/// Protocol: JSON-RPC 2.0, one message per line on stdin/stdout.
public final class MCPServer {
    public static let defaultProtocolVersion = "2025-06-18"
    private let openToolbox: () throws -> Toolbox
    private var toolbox: Toolbox?

    public init(openToolbox: @escaping () throws -> Toolbox) {
        self.openToolbox = openToolbox
    }

    /// Reads requests from stdin until EOF, writing responses to stdout.
    public func serve() {
        while let line = readLine(strippingNewline: true) {
            guard let response = handle(line) else { continue }
            print(response)
            fflush(stdout)
        }
    }

    /// Handles one JSON-RPC message. Returns the response line, or nil for notifications.
    public func handle(_ line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]) }

        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return nil }   // notifications (e.g. notifications/initialized) get no reply

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return reply(id, [
                "protocolVersion": requested ?? Self.defaultProtocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "parseley", "version": "0.1.0"],
                "instructions": "Read-only access to the user's Parseley clipboard history (text clips, number stats, series totals). Use query_sql for aggregate questions.",
            ])
        case "ping":
            return reply(id, [String: Any]())
        case "tools/list":
            return reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try call(name, arguments)
                return reply(id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch {
                // Tool failures are results (so the model can read them), not protocol errors.
                return reply(id, ["content": [["type": "text", "text": String(describing: error)]], "isError": true])
            }
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    // MARK: - Tools

    private func call(_ name: String, _ args: [String: Any]) throws -> String {
        func string(_ key: String) throws -> String {
            guard let value = args[key] as? String, !value.isEmpty else { throw ToolError.usage("Missing \"\(key)\"") }
            return value
        }
        let limit = min(max((args["limit"] as? Int) ?? 20, 1), 200)
        let format: NumberFormat = (args["format"] as? String) == "european" ? .european : .us

        switch name {
        case "recent_clips":
            return JSONShape.string(try box().recent(limit: limit).map(JSONShape.summary))
        case "search_clips":
            return JSONShape.string(try box().search(try string("query"), limit: limit).map(JSONShape.summary))
        case "get_clip":
            guard let id = (args["id"] as? Int).map(Int64.init) else { throw ToolError.usage("Missing \"id\"") }
            guard let clip = try box().clip(id: id) else { throw ToolError.notFound("Clip \(id)") }
            return JSONShape.string(JSONShape.clip(clip))
        case "number_stats":
            guard let stats = Toolbox.stats(of: try string("text"), format: format) else { throw ToolError.noNumbers }
            return JSONShape.string(JSONShape.stats(stats))
        case "transform_text":
            return try Toolbox.transform(try string("text"), with: try string("transform"), format: format)
        case "list_series":
            return JSONShape.string(try box().series(limit: limit).map(JSONShape.series))
        case "query_sql":
            return JSONShape.string(JSONShape.query(try box().sql(try string("sql"), maxRows: 500)))
        default:
            throw ToolError.usage("Unknown tool \(name)")
        }
    }

    /// Opened lazily, so `initialize` works even before the app has created a history.
    private func box() throws -> Toolbox {
        if let toolbox { return toolbox }
        let opened = try openToolbox()
        toolbox = opened
        return opened
    }

    static let tools: [[String: Any]] = {
        let limit: [String: Any] = ["type": "integer", "description": "Max results (1–200, default 20)"]
        let format: [String: Any] = ["type": "string", "enum": ["us", "european"],
                                     "description": "Number format: us = 1,204.50, european = 1.204,50"]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required],
             "annotations": ["readOnlyHint": true]]
        }
        return [
            tool("recent_clips", "Most recent clipboard clips (preview, kind, app, number count and sum).", ["limit": limit]),
            tool("search_clips", "Clips whose text or note contains a query (case-insensitive).",
                 ["query": ["type": "string"], "limit": limit], ["query"]),
            tool("get_clip", "Full text of one clip by id.", ["id": ["type": "integer"]], ["id"]),
            tool("number_stats", "Count, sum, average, median, min and max of the numbers in a text (handles $1,204.50, (300), 12%, 1.2k).",
                 ["text": ["type": "string"], "format": format], ["text"]),
            tool("transform_text", "Apply a Parseley transform to text.",
                 ["text": ["type": "string"],
                  "transform": ["type": "string", "enum": TransformRegistry.all.map(\.id)],
                  "format": format], ["text", "transform"]),
            tool("list_series", "Running and past series (running tallies) with their stats.", ["limit": limit]),
            tool("query_sql", """
                Read-only SQLite query over the history. Views: clips(id, content, kind, app, created_at, \
                last_used_at, pinned, note, number_count, number_sum, number_sum_exact); numbers(clip_id, position, \
                value, value_exact, app, created_at); series_list(id, name, created_at, ended_at); \
                series_values(series_id, series_name, entry_id, app, created_at, value, value_exact). \
                Dates are 'YYYY-MM-DD HH:MM:SS.SSS' UTC. At most 500 rows are returned.
                """, ["sql": ["type": "string"]], ["sql"]),
        ]
    }()

    // MARK: - JSON-RPC helpers

    private func reply(_ id: Any, _ result: Any) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ object: [String: Any]) -> String {
        JSONShape.string(object, pretty: false)
    }
}
