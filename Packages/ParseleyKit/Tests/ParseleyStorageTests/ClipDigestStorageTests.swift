import Foundation
import GRDB
import Testing
import ParseleyCore
@testable import ParseleyStorage

private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

@Suite struct ClipDigestStorageTests {
    let clock = TestClock()
    let store: GRDBClipStore

    init() throws {
        let clock = self.clock
        store = try GRDBClipStore.inMemory(now: { clock.now() })
    }

    @Test func summariesCarryPreviewCountsAndSumWithoutFullText() throws {
        let big = "Revenue\n" + String(repeating: "x", count: 50_000)
        try store.insert(NewClip(content: big, kind: .text))
        try store.insert(NewClip(content: "$1,204.50\n300\n(12)", kind: .numberList))
        let rows = try store.summaries(matching: nil, limit: 10)

        #expect(rows[0].numberCount == 3)
        #expect(rows[0].numberSum == d("1492.5"))
        #expect(rows[0].lineCount == 3)
        #expect(rows[1].preview == "Revenue")
        #expect(rows[1].length == big.utf16.count)
        #expect(rows[1].numberCount == 0)
        #expect(rows[1].numberSum == nil)
    }

    @Test func previewIsTruncated() throws {
        try store.insert(NewClip(content: String(repeating: "abc ", count: 500), kind: .text))
        let row = try #require(try store.summaries(matching: nil, limit: 1).first)
        #expect(row.preview.count <= ClipDigest.previewLength)
    }

    @Test func numbersFromCaptureAreUsedAsGiven() throws {
        // e.g. parsed in European format by the capture pipeline.
        try store.insert(NewClip(content: "1.204,50", kind: .number, numbers: [d("1204.5")]))
        #expect(try store.summaries(matching: nil, limit: 1).first?.numberSum == d("1204.5"))
    }

    @Test func numbersAreStoredPerClipAndCascadeOnDelete() throws {
        let clip = try store.insert(NewClip(content: "1\n2\n3", kind: .numberList)).clip
        let count = { try self.store.dbQueueForTests.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clipNumber") ?? 0 } }
        #expect(try count() == 3)
        try store.delete(id: clip.id!)
        #expect(try count() == 0)
    }

    @Test func summariesSearchContentAndNote() throws {
        try store.insert(NewClip(content: "apples", kind: .text))
        try store.append(NewClip(content: "4210.5", kind: .seriesTotal, note: "Σ 4,210.5 · Q3 expenses"))
        #expect(try store.summaries(matching: "q3", limit: 10).map(\.title) == ["Σ 4,210.5 · Q3 expenses"])
        #expect(try store.summaries(matching: "apple", limit: 10).map(\.preview) == ["apples"])
        #expect(try store.fetch(matching: "Q3", limit: 10).first?.note == "Σ 4,210.5 · Q3 expenses")
    }

    @Test func appendDoesNotDedupe() throws {
        try store.insert(NewClip(content: "42", kind: .number))
        let appended = try store.append(NewClip(content: "42", kind: .seriesTotal, note: "Σ 42"))
        #expect(try store.count() == 2)
        #expect(appended.kind == .seriesTotal)
    }

    @Test func seriesTotalsSurviveTrimAndClearAllButPinned() throws {
        try store.append(NewClip(content: "100", kind: .seriesTotal, note: "Σ 100"))
        for i in 0..<5 { try store.insert(NewClip(content: "c\(i)", kind: .text)) }
        try store.trim(toUnpinnedLimit: 2)
        #expect(Set(try store.summaries(matching: nil, limit: 10).map(\.title)) == ["Σ 100", "c4", "c3"])

        try store.deleteAll(keepingPinned: true)
        #expect(try store.summaries(matching: nil, limit: 10).map(\.title) == ["Σ 100"])
        try store.deleteAll(keepingPinned: false)
        #expect(try store.count() == 0)
    }

    @Test func migrationBackfillsExistingClips() throws {
        // A database as it was before v3: only the v1/v2 migrations applied.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v2-series")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO clip (content, contentHash, kind, createdAt, lastUsedAt, isPinned)
                VALUES ('$1,000\n$250', 'x', 'numberList', '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000', 0)
                """)
        }
        let upgraded = try GRDBClipStore(dbQueue: queue, now: { Date() })   // runs v3
        let row = try #require(try upgraded.summaries(matching: nil, limit: 1).first)
        #expect(row.preview == "$1,000")
        #expect(row.numberCount == 2)
        #expect(row.numberSum == 1250)
        #expect(row.lineCount == 2)
    }

    @Test func listingStaysSmallWhateverTheClipSize() throws {
        // 300 clips of ~20 KB each: summaries must not carry the 6 MB of text.
        let chunk = String(repeating: "lorem ipsum ", count: 1_700)   // ~20 KB
        for i in 0..<300 { try store.insert(NewClip(content: "\(i) \(chunk)", kind: .text)) }

        var start = Date()
        let full = try store.fetch(matching: nil, limit: 300)
        let fullTime = Date().timeIntervalSince(start)
        start = Date()
        let rows = try store.summaries(matching: nil, limit: 300)
        let summaryTime = Date().timeIntervalSince(start)

        let fullBytes = full.reduce(0) { $0 + $1.content.utf8.count }
        let summaryBytes = rows.reduce(0) { $0 + $1.preview.utf8.count }
        print("300 clips: full fetch \(fullBytes / 1024) KB in \(Int(fullTime * 1000)) ms; summaries \(summaryBytes / 1024) KB in \(Int(summaryTime * 1000)) ms")
        #expect(summaryBytes < fullBytes / 100)
    }
}

extension GRDBClipStore {
    /// Test-only access to the underlying queue.
    var dbQueueForTests: DatabaseQueue { dbQueue }
}
