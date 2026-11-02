import Foundation
import Testing
import ParseleyCore
@testable import ParseleyStorage

private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Suite struct GRDBSeriesStoreTests {
    let database: ParseleyDatabase
    let store: GRDBSeriesStore

    init() throws {
        database = try ParseleyDatabase.inMemory()
        store = GRDBSeriesStore(database: database)
    }

    func makeSeries(_ name: String, at offset: TimeInterval = 0, ended: Bool = false) -> Series {
        Series(
            name: name, createdAt: t0 + offset, endedAt: ended ? t0 + offset + 60 : nil,
            entries: [
                SeriesEntry(clipID: 7, sourceBundleID: "com.excel", createdAt: t0 + offset + 1,
                            values: [d("1204.50"), d("-12"), d("0.1")], preview: "1,204.50", isIncluded: true),
                SeriesEntry(clipID: nil, sourceBundleID: nil, createdAt: t0 + offset + 2,
                            values: [4512, 8], preview: "Invoice #4512", isIncluded: false),
            ]
        )
    }

    @Test func roundTripsEverythingExactly() throws {
        let s = makeSeries("Q3")
        try store.save(s)
        let loaded = try #require(try store.activeSeries())
        #expect(loaded == s)
        #expect(loaded.values == [d("1204.5"), -12, d("0.1")])
    }

    @Test func saveUpdatesInPlace() throws {
        var s = makeSeries("Q3")
        try store.save(s)
        s.name = "Renamed"
        s.entries.removeLast()
        s.entries[0].isIncluded = false
        s.endedAt = t0 + 500
        try store.save(s)
        #expect(try store.count() == 1)
        let loaded = try #require(try store.recentSeries(limit: 5).first)
        #expect(loaded == s)
    }

    @Test func activeIsTheLatestUnended() throws {
        try store.save(makeSeries("old", at: 0, ended: true))
        try store.save(makeSeries("running", at: 100))
        try store.save(makeSeries("ended later", at: 200, ended: true))
        #expect(try store.activeSeries()?.name == "running")
    }

    @Test func noActiveWhenAllEnded() throws {
        try store.save(makeSeries("done", ended: true))
        #expect(try store.activeSeries() == nil)
    }

    @Test func recentIsNewestFirstWithLimit() throws {
        for i in 0..<5 { try store.save(makeSeries("s\(i)", at: TimeInterval(i * 100), ended: true)) }
        #expect(try store.recentSeries(limit: 3).map(\.name) == ["s4", "s3", "s2"])
    }

    @Test func deleteCascadesToEntries() throws {
        let s = makeSeries("gone")
        try store.save(s)
        try store.delete(id: s.id)
        #expect(try store.count() == 0)
        // Saving a new series with the same entries' ids must not collide with leftovers.
        try store.save(s)
        #expect(try store.activeSeries()?.entries.count == 2)
    }

    @Test func sharesTheDatabaseWithTheClipStore() throws {
        let clips = try GRDBClipStore(database: database)
        try clips.insert(NewClip(content: "42", kind: .number))
        try store.save(makeSeries("Q3"))
        #expect(try clips.count() == 1)
        #expect(try store.count() == 1)
    }

    @Test func worksWithTheTracker() throws {
        let tracker = SeriesTracker(store: store)
        tracker.start(name: "Live")
        tracker.ingest(content: "10\n20", clipID: 1, sourceBundleID: "com.excel")
        let relaunched = SeriesTracker(store: GRDBSeriesStore(database: database))
        #expect(relaunched.active?.name == "Live")
        #expect(relaunched.active?.values == [10, 20])
    }

    @Test func migratesAnExistingV1DatabaseFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("p.sqlite").path

        // Opening twice must be fine (migrations already applied the second time).
        do {
            let db = try ParseleyDatabase(path: path)
            try GRDBSeriesStore(database: db).save(makeSeries("persisted"))
        }
        let reopened = try ParseleyDatabase(path: path)
        #expect(try GRDBSeriesStore(database: reopened).activeSeries()?.name == "persisted")
    }
}
