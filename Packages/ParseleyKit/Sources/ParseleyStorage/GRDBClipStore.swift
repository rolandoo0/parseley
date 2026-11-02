import Foundation
import GRDB
import ParseleyCore

/// SQLite-backed `ClipStore` using GRDB.
///
/// GRDB's `DatabaseQueue` serializes all access to one SQLite connection, so this class
/// is safe to call from any thread. In the app we call it from the main thread: with
/// ≤1,000 short rows each query takes well under a millisecond.
public final class GRDBClipStore: ClipStore, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let now: @Sendable () -> Date

    /// Opens (creating if needed) the database file at `path` and runs migrations.
    public convenience init(path: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
        try self.init(dbQueue: DatabaseQueue(path: path), now: now)
    }

    /// A private in-memory database, for tests.
    public static func inMemory(now: @escaping @Sendable () -> Date = { Date() }) throws -> GRDBClipStore {
        try GRDBClipStore(dbQueue: DatabaseQueue(), now: now)
    }

    init(dbQueue: DatabaseQueue, now: @escaping @Sendable () -> Date) throws {
        self.dbQueue = dbQueue
        self.now = now
        try Schema.migrator.migrate(dbQueue)
    }

    /// Default location: ~/Library/Application Support/Parseley/parseley.sqlite
    public static func defaultDatabaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = support.appendingPathComponent("Parseley", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("parseley.sqlite")
    }

    // MARK: - ClipStore

    @discardableResult
    public func insert(_ newClip: NewClip) throws -> InsertResult {
        try dbQueue.write { db in
            let timestamp = now()
            if var latest = try ClipRecord.order(ClipRecord.recency).fetchOne(db),
               latest.content == newClip.content {
                latest.lastUsedAt = timestamp
                try latest.update(db)
                return .duplicateOfLatest(latest.clip)
            }
            var record = ClipRecord(
                id: nil, content: newClip.content, contentHash: ContentHash.of(newClip.content),
                kind: newClip.kind.rawValue, sourceBundleID: newClip.sourceBundleID,
                createdAt: timestamp, lastUsedAt: timestamp, isPinned: false
            )
            try record.insert(db)   // sets record.id via didInsert
            return .inserted(record.clip)
        }
    }

    public func fetch(matching query: String?, limit: Int) throws -> [Clip] {
        try dbQueue.read { db in
            var request = ClipRecord.all()
            if let query, !query.isEmpty {
                // LIKE is case-insensitive for ASCII in SQLite. Escape LIKE wildcards so a
                // search for "50%" matches literally.
                let escaped = query
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                request = request.filter(sql: "content LIKE ? ESCAPE '\\'", arguments: ["%\(escaped)%"])
            }
            return try request
                .order(Column("isPinned").desc, Column("lastUsedAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
                .map(\.clip)
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
                try db.execute(sql: "DELETE FROM clip WHERE isPinned = 0")
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
                WHERE isPinned = 0
                  AND id NOT IN (
                    SELECT id FROM clip WHERE isPinned = 0
                    ORDER BY lastUsedAt DESC, id DESC
                    LIMIT ?
                  )
                """, arguments: [max(0, limit)])
            return db.changesCount
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

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var clip: Clip {
        var c = Clip(
            id: id, content: content, kind: ClipKind(storedValue: kind),
            sourceBundleID: sourceBundleID, createdAt: createdAt,
            lastUsedAt: lastUsedAt, isPinned: isPinned
        )
        c.contentHash = contentHash
        return c
    }
}
