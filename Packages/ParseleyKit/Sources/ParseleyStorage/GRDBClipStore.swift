import Foundation
import GRDB
import ParseleyCore

/// SQLite-backed `ClipStore` using GRDB.
///
/// GRDB's `DatabaseQueue` serializes all access to one SQLite connection, so this class
/// is safe to call from any thread. In the app we call it from the main thread: with
/// ≤1,000 short rows each query takes well under a millisecond.
public final class GRDBClipStore: ClipStore, @unchecked Sendable {
    let dbQueue: DatabaseQueue
    private let now: @Sendable () -> Date

    /// Opens (creating if needed) the database file at `path` and runs migrations.
    public convenience init(path: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
        try self.init(dbQueue: DatabaseQueue(path: path), now: now)
    }

    /// A private in-memory database, for tests.
    public static func inMemory(now: @escaping @Sendable () -> Date = { Date() }) throws -> GRDBClipStore {
        try GRDBClipStore(dbQueue: DatabaseQueue(), now: now)
    }

    /// Uses a shared database (the app opens one file for clips and series).
    public convenience init(database: ParseleyDatabase, now: @escaping @Sendable () -> Date = { Date() }) throws {
        try self.init(dbQueue: database.dbQueue, now: now, migrate: !database.isReadOnly)
    }

    init(dbQueue: DatabaseQueue, now: @escaping @Sendable () -> Date, migrate: Bool = true) throws {
        self.dbQueue = dbQueue
        self.now = now
        if migrate { try Schema.migrator.migrate(dbQueue) }
    }

    /// Default location: ~/Library/Application Support/Parseley/parseley.sqlite
    public static func defaultDatabaseURL() throws -> URL {
        try ParseleyDatabase.defaultURL()
    }

    // MARK: - ClipStore

    @discardableResult
    public func insert(_ newClip: NewClip) throws -> InsertResult {
        try dbQueue.write { db in
            let timestamp = now()
            // Only compare text with the latest clip (consecutive-copy dedupe): fetch just
            // its id and content.
            if let latest = try Row.fetchOne(db, sql: "SELECT id, content FROM clip ORDER BY lastUsedAt DESC, id DESC LIMIT 1"),
               (latest["content"] as String) == newClip.content {
                let id: Int64 = latest["id"]
                try db.execute(sql: "UPDATE clip SET lastUsedAt = ? WHERE id = ?", arguments: [timestamp, id])
                return .duplicateOfLatest(try ClipRecord.fetchOne(db, key: id)!.clip)
            }
            return .inserted(try Self.add(newClip, at: timestamp, in: db))
        }
    }

    @discardableResult
    public func append(_ newClip: NewClip) throws -> Clip {
        try dbQueue.write { db in try Self.add(newClip, at: now(), in: db) }
    }

    public func fetch(matching query: String?, limit: Int) throws -> [Clip] {
        try dbQueue.read { db in
            var request = ClipRecord.all()
            if let pattern = Self.likePattern(query) {
                request = request.filter(sql: "content LIKE ? ESCAPE '\\' OR note LIKE ? ESCAPE '\\'", arguments: [pattern, pattern])
            }
            return try request
                .order(Column("isPinned").desc, Column("lastUsedAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
                .map(\.clip)
        }
    }

    public func summaries(matching query: String?, limit: Int) throws -> [ClipSummary] {
        try dbQueue.read { db in
            // Never selects `content`: rows stay small however big the clips are.
            var sql = """
                SELECT id, preview, length, lineCount, kind, sourceBundleID, createdAt, lastUsedAt,
                       isPinned, note, numberCount, numberSum
                FROM clip
                """
            var arguments: StatementArguments = []
            if let pattern = Self.likePattern(query) {
                sql += " WHERE content LIKE ? ESCAPE '\\' OR note LIKE ? ESCAPE '\\'"
                arguments += [pattern, pattern]
            }
            sql += " ORDER BY isPinned DESC, lastUsedAt DESC, id DESC LIMIT ?"
            arguments += [limit]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                ClipSummary(
                    id: row["id"], preview: row["preview"], length: row["length"], lineCount: row["lineCount"],
                    kind: ClipKind(storedValue: row["kind"]), sourceBundleID: row["sourceBundleID"],
                    createdAt: row["createdAt"], lastUsedAt: row["lastUsedAt"], isPinned: row["isPinned"],
                    note: row["note"], numberCount: row["numberCount"],
                    numberSum: (row["numberSum"] as String?).flatMap { Decimal(string: $0, locale: Self.posix) }
                )
            }
        }
    }

    public func clip(id: Int64) throws -> Clip? {
        try dbQueue.read { db in try ClipRecord.fetchOne(db, key: id)?.clip }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in try ClipRecord.fetchCount(db) }
    }

    public func setPinned(id: Int64, _ pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clip SET isPinned = ? WHERE id = ?", arguments: [pinned, id])
        }
    }

    public func touch(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clip SET lastUsedAt = ? WHERE id = ?", arguments: [now(), id])
        }
    }

    public func delete(id: Int64) throws {
        _ = try dbQueue.write { db in try ClipRecord.deleteOne(db, key: id) }
    }

    public func deleteAll(keepingPinned: Bool) throws {
        try dbQueue.write { db in
            if keepingPinned {
                try db.execute(sql: "DELETE FROM clip WHERE \(Self.evictable)")
            } else {
                try db.execute(sql: "DELETE FROM clip")
            }
        }
    }

    @discardableResult
    public func trim(toUnpinnedLimit limit: Int) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM clip
                WHERE \(Self.evictable)
                  AND id NOT IN (
                    SELECT id FROM clip WHERE \(Self.evictable)
                    ORDER BY lastUsedAt DESC, id DESC
                    LIMIT ?
                  )
                """, arguments: [max(0, limit)])
            return db.changesCount
        }
    }

    // MARK: - Helpers

    /// Rows the history limit may delete: not pinned, not a series total.
    static let evictable = "isPinned = 0 AND kind != '\(ClipKind.seriesTotal.rawValue)'"
    static let posix = Locale(identifier: "en_US_POSIX")

    /// "%query%" with LIKE wildcards escaped, so a search for "50%" matches literally.
    static func likePattern(_ query: String?) -> String? {
        guard let query, !query.isEmpty else { return nil }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    /// Inserts a clip with its digest (preview, counts, numbers).
    static func add(_ newClip: NewClip, at timestamp: Date, in db: Database) throws -> Clip {
        let digest = ClipDigest(content: newClip.content, numbers: newClip.numbers)
        var record = ClipRecord(
            id: nil, content: newClip.content, contentHash: ContentHash.of(newClip.content),
            kind: newClip.kind.rawValue, sourceBundleID: newClip.sourceBundleID,
            createdAt: timestamp, lastUsedAt: timestamp, isPinned: false,
            preview: digest.preview, length: digest.length, lineCount: digest.lineCount,
            numberCount: digest.numbers.count, numberSum: digest.sum?.description, note: newClip.note
        )
        try record.insert(db)   // sets record.id via didInsert
        try insertNumbers(digest.numbers, clipID: record.id!, in: db)
        return record.clip
    }

    static func insertNumbers(_ numbers: [Decimal], clipID: Int64, in db: Database) throws {
        guard !numbers.isEmpty else { return }
        // A cached prepared statement: compiled once, reused for every row.
        let statement = try db.cachedStatement(sql: "INSERT INTO clipNumber (clipId, position, value) VALUES (?, ?, ?)")
        for (position, value) in numbers.enumerated() {
            try statement.execute(arguments: [clipID, position, value.description])
        }
    }
}

// MARK: - Schema

enum Schema {
    /// Migrations run in order, once each; GRDB records which ones have run. Never edit a
    /// shipped migration. Add "v2", "v3"… instead.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "clip") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("content", .text).notNull()
                t.column("contentHash", .text).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("sourceBundleID", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime).notNull().indexed()
                t.column("isPinned", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v2-series") { db in
            try db.create(table: "series") { t in
                t.primaryKey("id", .text)                 // UUID string
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)             // NULL while active
            }
            try db.create(table: "seriesEntry") { t in
                t.primaryKey("id", .text)
                // Deleting a series deletes its entries (SQLite foreign key cascade).
                t.column("seriesId", .text).notNull().indexed()
                    .references("series", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("clipId", .integer)               // not a foreign key: clips get trimmed
                t.column("sourceBundleID", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("valuesJSON", .text).notNull()    // ["1204.5","300"]: exact decimals as strings
                t.column("preview", .text).notNull()
                t.column("isIncluded", .boolean).notNull()
            }
        }
        migrator.registerMigration("v3-digests") { db in
            // Facts computed once per clip so lists never load or re-parse full text.
            try db.alter(table: "clip") { t in
                t.add(column: "preview", .text).notNull().defaults(to: "")
                t.add(column: "length", .integer).notNull().defaults(to: 0)
                t.add(column: "lineCount", .integer).notNull().defaults(to: 0)
                t.add(column: "numberCount", .integer).notNull().defaults(to: 0)
                t.add(column: "numberSum", .text)          // exact decimal as text
                t.add(column: "note", .text)
            }
            // Every number found in every clip: lets SQL (CLI / MCP) answer things like
            // "sum of everything copied from Excel today".
            try db.create(table: "clipNumber") { t in
                t.column("clipId", .integer).notNull().references("clip", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("value", .text).notNull()          // exact decimal as text
                t.primaryKey(["clipId", "position"])
            }
            try db.create(index: "clip_listOrder", on: "clip", columns: ["isPinned", "lastUsedAt", "id"])

            // Fill in existing clips, one at a time to keep memory flat.
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM clip")
            for id in ids {
                guard let content = try String.fetchOne(db, sql: "SELECT content FROM clip WHERE id = ?", arguments: [id])
                else { continue }
                let digest = ClipDigest(content: content)
                try db.execute(sql: """
                    UPDATE clip SET preview = ?, length = ?, lineCount = ?, numberCount = ?, numberSum = ?
                    WHERE id = ?
                    """, arguments: [digest.preview, digest.length, digest.lineCount,
                                     digest.numbers.count, digest.sum?.description, id])
                try GRDBClipStore.insertNumbers(digest.numbers, clipID: id, in: db)
            }
        }
        migrator.registerMigration("v4-sql-views") { db in
            // Friendly read-only views for SQL from the CLI / MCP server. Exact decimals are
            // kept as text (*_exact); the REAL columns are for SUM/AVG/ORDER BY.
            try db.execute(sql: """
                CREATE VIEW clips AS
                  SELECT id, content, kind, sourceBundleID AS app, createdAt AS created_at,
                         lastUsedAt AS last_used_at, isPinned AS pinned, note,
                         numberCount AS number_count, CAST(numberSum AS REAL) AS number_sum,
                         numberSum AS number_sum_exact
                  FROM clip;
                CREATE VIEW numbers AS
                  SELECT n.clipId AS clip_id, n.position, CAST(n.value AS REAL) AS value,
                         n.value AS value_exact, c.sourceBundleID AS app, c.createdAt AS created_at
                  FROM clipNumber n JOIN clip c ON c.id = n.clipId;
                CREATE VIEW series_list AS
                  SELECT id, name, createdAt AS created_at, endedAt AS ended_at FROM series;
                CREATE VIEW series_values AS
                  SELECT e.seriesId AS series_id, s.name AS series_name, e.id AS entry_id,
                         e.sourceBundleID AS app, e.createdAt AS created_at,
                         CAST(j.value AS REAL) AS value, j.value AS value_exact
                  FROM seriesEntry e
                  JOIN series s ON s.id = e.seriesId,
                       json_each(e.valuesJSON) j
                  WHERE e.isIncluded = 1;
                """)
        }
        return migrator
    }
}

// MARK: - Record

/// Database row ↔ Swift struct mapping. Kept private to this module so `Clip` (in Core)
/// stays free of GRDB. Codable property names = column names.
struct ClipRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clip"
    /// "Most recent first", used for consecutive-copy dedupe (ignores pin state).
    static let recency: [any SQLOrderingTerm] = [Column("lastUsedAt").desc, Column("id").desc]

    var id: Int64?
    var content: String
    var contentHash: String
    var kind: String
    var sourceBundleID: String?
    var createdAt: Date
    var lastUsedAt: Date
    var isPinned: Bool
    var preview: String
    var length: Int
    var lineCount: Int
    var numberCount: Int
    var numberSum: String?
    var note: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var clip: Clip {
        var c = Clip(
            id: id, content: content, kind: ClipKind(storedValue: kind),
            sourceBundleID: sourceBundleID, createdAt: createdAt,
            lastUsedAt: lastUsedAt, isPinned: isPinned, note: note
        )
        c.contentHash = contentHash
        return c
    }
}
