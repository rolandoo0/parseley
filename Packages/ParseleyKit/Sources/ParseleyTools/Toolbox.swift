import Foundation
import ParseleyCore
import ParseleyStorage

/// Everything the CLI and the MCP server can do, over a read-only view of the history.
/// Returns plain values; the CLI and MCP layers only format them.
public final class Toolbox {
    let clips: GRDBClipStore
    let series: GRDBSeriesStore
    let query: QueryService

    public init(database: ParseleyDatabase) throws {
        clips = try GRDBClipStore(database: database)
        series = GRDBSeriesStore(database: database)
        query = QueryService(database: database)
    }

    /// Opens the history read-only (default location unless `path` is given).
    public static func open(path: String?) throws -> Toolbox {
        let resolved = try path ?? ParseleyDatabase.defaultURL().path
        return try Toolbox(database: ParseleyDatabase(path: resolved, readOnly: true))
    }

    public func recent(limit: Int) throws -> [ClipSummary] {
        try clips.summaries(matching: nil, limit: limit)
    }

    public func search(_ text: String, limit: Int) throws -> [ClipSummary] {
        try clips.summaries(matching: text, limit: limit)
    }

    public func clip(id: Int64) throws -> Clip? {
        try clips.clip(id: id)
    }

    /// The most recent clip (what `stats`/`transform` use when given nothing else).
    public func latestClip() throws -> Clip? {
        try clips.fetch(matching: nil, limit: 50).max { $0.lastUsedAt < $1.lastUsedAt }
    }

    public func series(limit: Int) throws -> [Series] {
        try series.recentSeries(limit: limit)
    }

    public func sql(_ text: String, maxRows: Int = 1_000) throws -> QueryResult {
        try query.run(text, maxRows: maxRows)
    }

    public func schema() throws -> [(name: String, columns: [String])] {
        try query.schema()
    }

    // MARK: - Pure helpers (no database needed)

    public static func stats(of text: String, format: NumberFormat) -> NumberStats? {
        NumberStats(text: text, parser: NumberParser(format: format))
    }

    public static func transform(_ text: String, with id: String, format: NumberFormat) throws -> String {
        guard let transform = TransformRegistry.transform(id: id, format: format) else {
            throw ToolError.unknownTransform(id)
        }
        return try transform.apply(text)
    }
}

public enum ToolError: Error, CustomStringConvertible, Equatable {
    case unknownTransform(String)
    case notFound(String)
    case usage(String)
    case noNumbers

    public var description: String {
        switch self {
        case .unknownTransform(let id):
            "Unknown transform \"\(id)\". Available: \(TransformRegistry.all.map(\.id).joined(separator: ", "))"
        case .notFound(let what): "\(what) not found"
        case .usage(let message): message
        case .noNumbers: "No numbers found"
        }
    }
}

// MARK: - JSON shapes shared by CLI (--json) and MCP

enum JSONShape {
    static func summary(_ s: ClipSummary) -> [String: Any] {
        var dict: [String: Any] = [
            "id": s.id, "kind": s.kind.rawValue, "preview": s.preview, "length": s.length,
            "lines": s.lineCount, "pinned": s.isPinned, "created_at": iso(s.createdAt),
            "last_used_at": iso(s.lastUsedAt), "number_count": s.numberCount,
        ]
        if let app = s.sourceBundleID { dict["app"] = app }
        if let note = s.note { dict["note"] = note }
        if let sum = s.numberSum { dict["number_sum"] = sum.description }
        return dict
    }

    static func clip(_ c: Clip) -> [String: Any] {
        var dict: [String: Any] = [
            "id": c.id ?? 0, "kind": c.kind.rawValue, "content": c.content, "pinned": c.isPinned,
            "created_at": iso(c.createdAt), "last_used_at": iso(c.lastUsedAt),
        ]
        if let app = c.sourceBundleID { dict["app"] = app }
        if let note = c.note { dict["note"] = note }
        return dict
    }

    /// Stats as exact decimal strings (machine format, "." decimals).
    static func stats(_ s: NumberStats) -> [String: Any] {
        func v(_ d: Decimal) -> String { NumberFormatting.plain(d, maxFractionDigits: 10) }
        return ["count": s.count, "sum": v(s.sum), "average": v(s.mean), "median": v(s.median),
                "min": v(s.min), "max": v(s.max)]
    }

    static func series(_ s: Series) -> [String: Any] {
        var dict: [String: Any] = [
            "id": s.id.uuidString, "name": s.name, "created_at": iso(s.createdAt),
            "active": s.endedAt == nil, "entries": s.entries.count, "value_count": s.values.count,
        ]
        if let ended = s.endedAt { dict["ended_at"] = iso(ended) }
        if let seriesStats = s.stats { dict["stats"] = stats(seriesStats) }
        return dict
    }

    static func query(_ r: QueryResult) -> [String: Any] {
        ["columns": r.columns,
         "rows": r.rows.map { row in row.map { $0 as Any? ?? NSNull() } },
         "truncated": r.truncated]
    }

    static func string(_ value: Any, pretty: Bool = true) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
