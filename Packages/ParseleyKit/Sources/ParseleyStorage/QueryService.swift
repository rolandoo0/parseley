import Foundation
import GRDB

/// Result of a SQL query, as text cells (NULL → nil).
public struct QueryResult: Equatable, Sendable {
    public var columns: [String]
    public var rows: [[String?]]
    /// True when more rows existed than `maxRows`.
    public var truncated: Bool
}

public enum QueryError: Error, Equatable, CustomStringConvertible {
    case notReadOnly
    case sqlite(String)

    public var description: String {
        switch self {
        case .notReadOnly: "Only read-only queries (SELECT / WITH) are allowed."
        case .sqlite(let message): message
        }
    }
}

/// Runs read-only SQL over the history. Views for convenience (created by migration v4):
///
///     clips(id, content, kind, app, created_at, last_used_at, pinned, note,
///           number_count, number_sum, number_sum_exact)
///     numbers(clip_id, position, value, value_exact, app, created_at)
///     series_list(id, name, created_at, ended_at)
///     series_values(series_id, series_name, entry_id, app, created_at, value, value_exact)
///
/// Example: `SELECT app, SUM(value) FROM numbers GROUP BY app ORDER BY 2 DESC`
public final class QueryService: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(database: ParseleyDatabase) {
        dbQueue = database.dbQueue
    }

    public func run(_ sql: String, maxRows: Int = 1_000) throws -> QueryResult {
        do {
            // `read` also puts the connection in query-only mode: defence in depth.
            return try dbQueue.read { db in
                // makeStatement compiles exactly one statement and throws on several.
                // Only plain queries: no PRAGMA/ATTACH/etc., even ones SQLite calls read-only.
                guard Self.startsWithQueryKeyword(sql) else { throw QueryError.notReadOnly }
                let statement = try db.makeStatement(sql: sql)
                guard statement.isReadonly else { throw QueryError.notReadOnly }
                var rows: [[String?]] = []
                var truncated = false
                let cursor = try Row.fetchCursor(statement)
                while let row = try cursor.next() {
                    if rows.count == maxRows { truncated = true; break }
                    rows.append(row.databaseValues.map(Self.text))
                }
                return QueryResult(columns: statement.columnNames, rows: rows, truncated: truncated)
            }
        } catch let error as QueryError {
            throw error
        } catch let error as DatabaseError {
            throw QueryError.sqlite(error.message ?? error.description)
        }
    }

    /// Tables and views a query can use, with their columns (for help / MCP).
    public func schema() throws -> [(name: String, columns: [String])] {
        try dbQueue.read { db in
            let names = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'view' AND name IN ('clips', 'numbers', 'series_list', 'series_values')
                ORDER BY name
                """)
            return try names.map { name in (name, try db.columns(in: name).map(\.name)) }
        }
    }

    /// First keyword (after whitespace and comments) is SELECT, WITH or VALUES.
    static func startsWithQueryKeyword(_ sql: String) -> Bool {
        var rest = Substring(sql)
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.hasPrefix("--") {
                rest = rest.drop { $0 != "\n" }
            } else if rest.hasPrefix("/*"), let end = rest.range(of: "*/") {
                rest = rest[end.upperBound...]
            } else {
                break
            }
        }
        let keyword = rest.prefix { $0.isLetter }.uppercased()
        return ["SELECT", "WITH", "VALUES"].contains(keyword)
    }

    private static func text(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .null: nil
        case .int64(let i): String(i)
        case .double(let d): d.rounded() == d && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s): s
        case .blob(let data): "<\(data.count) bytes>"
        }
    }
}
