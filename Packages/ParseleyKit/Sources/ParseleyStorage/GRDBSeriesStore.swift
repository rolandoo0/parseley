import Foundation
import GRDB
import ParseleyCore

/// One SQLite database file shared by the clip and series stores, the CLI and the MCP
/// server. The app opens it read-write (running migrations); tools open it read-only.
public final class ParseleyDatabase: @unchecked Sendable {
    let dbQueue: DatabaseQueue
    public let isReadOnly: Bool

    /// - Parameter readOnly: open without write access and without migrating (for the
    ///   CLI / MCP server while the app keeps writing). Waits up to 3 s if the app is
    ///   mid-write.
    public init(path: String, readOnly: Bool = false) throws {
        var configuration = Configuration()
        configuration.readonly = readOnly
        configuration.busyMode = .timeout(3)
        if readOnly, !FileManager.default.fileExists(atPath: path) {
            throw ParseleyDatabaseError.notFound(path)
        }
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        isReadOnly = readOnly
        if readOnly {
            let applied = try dbQueue.read { try Schema.migrator.appliedMigrations($0) }
            guard Set(applied).isSuperset(of: Schema.migrator.migrations) else {
                throw ParseleyDatabaseError.needsUpgrade
            }
        } else {
            try Schema.migrator.migrate(dbQueue)
        }
    }

    private init(queue: DatabaseQueue) throws {
        dbQueue = queue
        isReadOnly = false
        try Schema.migrator.migrate(dbQueue)
    }

    /// A private in-memory database, for tests.
    public static func inMemory() throws -> ParseleyDatabase {
        try ParseleyDatabase(queue: DatabaseQueue())
    }

    /// ~/Library/Application Support/Parseley/parseley.sqlite
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = support.appendingPathComponent("Parseley", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("parseley.sqlite")
    }
}

public enum ParseleyDatabaseError: Error, CustomStringConvertible {
    case notFound(String)
    case needsUpgrade

    public var description: String {
        switch self {
        case .notFound(let path): "No Parseley history at \(path). Run the app first, or pass --db <path>."
        case .needsUpgrade: "The history database is from an older Parseley. Open the app once to upgrade it."
        }
    }
}

/// SQLite-backed `SeriesStore`. Tables: `series` and `seriesEntry` (see Schema).
public final class GRDBSeriesStore: SeriesStore, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(database: ParseleyDatabase) {
        dbQueue = database.dbQueue
    }

    public func save(_ series: Series) throws {
        try dbQueue.write { db in
            // "Upsert": insert, or update the existing row with the same id. (INSERT OR
            // REPLACE would delete the row first, cascading to its entries.)
            try db.execute(sql: """
                INSERT INTO series (id, name, createdAt, endedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, endedAt = excluded.endedAt
                """, arguments: [series.id.uuidString, series.name, series.createdAt, series.endedAt])
            // Entries are few (dozens), so replacing them all is simplest and atomic.
            try db.execute(sql: "DELETE FROM seriesEntry WHERE seriesId = ?", arguments: [series.id.uuidString])
            for (position, entry) in series.entries.enumerated() {
                try db.execute(sql: """
                    INSERT INTO seriesEntry
                      (id, seriesId, position, clipId, sourceBundleID, createdAt, valuesJSON, preview, isIncluded)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        entry.id.uuidString, series.id.uuidString, position, entry.clipID,
                        entry.sourceBundleID, entry.createdAt, try Self.encode(entry.values),
                        entry.preview, entry.isIncluded,
                    ])
            }
        }
    }

    public func activeSeries() throws -> Series? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM series WHERE endedAt IS NULL ORDER BY createdAt DESC LIMIT 1")
                .map { try load($0, db) }
        }
    }

    public func recentSeries(limit: Int) throws -> [Series] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM series ORDER BY createdAt DESC LIMIT ?", arguments: [limit])
                .map { try load($0, db) }
        }
    }

    public func delete(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM series WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series") ?? 0 }
    }

    // MARK: - Helpers

    private func load(_ row: Row, _ db: Database) throws -> Series {
        let idString: String = row["id"]
        let entryRows = try Row.fetchAll(
            db, sql: "SELECT * FROM seriesEntry WHERE seriesId = ? ORDER BY position", arguments: [idString]
        )
        let entries = try entryRows.map { r in
            let entryID: String = r["id"]
            return SeriesEntry(
                id: UUID(uuidString: entryID) ?? UUID(),
                clipID: r["clipId"],
                sourceBundleID: r["sourceBundleID"],
                createdAt: r["createdAt"],
                values: try Self.decode(r["valuesJSON"]),
                preview: r["preview"],
                isIncluded: r["isIncluded"]
            )
        }
        return Series(
            id: UUID(uuidString: idString) ?? UUID(),
            name: row["name"],
            createdAt: row["createdAt"],
            endedAt: row["endedAt"],
            entries: entries
        )
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Decimals are stored as strings ("1204.5") so they round-trip exactly.
    static func encode(_ values: [Decimal]) throws -> String {
        let data = try JSONEncoder().encode(values.map(\.description))
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) throws -> [Decimal] {
        let strings = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        return strings.compactMap { Decimal(string: $0, locale: posix) }
    }
}
