import Foundation
import Testing
import ParseleyCore
@testable import ParseleyStorage

/// Deterministic clock: each call returns one second later than the previous one.
/// Whole seconds avoid surprises from SQLite storing dates with millisecond precision.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        current += 1
        return current
    }
}

@Suite struct GRDBClipStoreTests {
    let clock = TestClock()
    let store: GRDBClipStore

    init() throws {
        let clock = self.clock
        store = try GRDBClipStore.inMemory(now: { clock.now() })
    }

    @discardableResult
    func add(_ text: String, kind: ClipKind = .text, source: String? = nil) throws -> Clip {
        try store.insert(NewClip(content: text, kind: kind, sourceBundleID: source)).clip
    }

    @Test func insertAssignsIDAndRoundTripsFields() throws {
        let clip = try add("hello", kind: .url, source: "com.apple.Safari")
        let id = try #require(clip.id)
        let fetched = try #require(try store.clip(id: id))
        #expect(fetched.content == "hello")
        #expect(fetched.kind == .url)
        #expect(fetched.sourceBundleID == "com.apple.Safari")
        #expect(fetched.contentHash == ContentHash.of("hello"))
        #expect(fetched.isPinned == false)
        #expect(fetched.createdAt == clip.createdAt)
    }

    @Test func consecutiveDuplicateIsNotStoredTwice() throws {
        let first = try store.insert(NewClip(content: "same", kind: .text))
        let second = try store.insert(NewClip(content: "same", kind: .text))
        guard case .inserted = first, case .duplicateOfLatest(let dup) = second else {
            Issue.record("expected inserted then duplicate, got \(first) / \(second)")
            return
        }
        #expect(dup.id == first.clip.id)
        #expect(dup.lastUsedAt > first.clip.lastUsedAt)
        #expect(try store.count() == 1)
    }

    @Test func nonConsecutiveDuplicateIsStored() throws {
        try add("a"); try add("b"); try add("a")
        #expect(try store.count() == 3)
    }

    @Test func dedupeIsExactMatch() throws {
        try add("a"); try add("a "); try add("A")
        #expect(try store.count() == 3)
    }

    @Test func fetchOrdersPinnedFirstThenMostRecent() throws {
        let a = try add("a"); try add("b"); try add("c")
        try store.setPinned(id: a.id!, true)
        #expect(try store.fetch(matching: nil, limit: 10).map(\.content) == ["a", "c", "b"])
    }

    @Test func touchMovesClipToTop() throws {
        let a = try add("a"); try add("b")
        try store.touch(id: a.id!)
        #expect(try store.fetch(matching: nil, limit: 10).map(\.content) == ["a", "b"])
    }

    @Test func dedupeComparesAgainstMostRecentlyUsed() throws {
        // After pasting "a" from history it's the latest, so copying "a" again is a dup.
        let a = try add("a"); try add("b")
        try store.touch(id: a.id!)
        let result = try store.insert(NewClip(content: "a", kind: .text))
        let expected = try #require(try store.clip(id: a.id!))
        #expect(result == .duplicateOfLatest(expected))
    }

    @Test func searchIsCaseInsensitiveSubstring() throws {
        try add("Quarterly Revenue"); try add("revenue by region"); try add("costs")
        #expect(try store.fetch(matching: "REVENUE", limit: 10).map(\.content) == ["revenue by region", "Quarterly Revenue"])
        #expect(try store.fetch(matching: "", limit: 10).count == 3)
    }

    @Test func searchTreatsLikeWildcardsLiterally() throws {
        try add("50% off"); try add("500 units"); try add("a_b"); try add("axb"); try add(#"C:\path"#)
        #expect(try store.fetch(matching: "50%", limit: 10).map(\.content) == ["50% off"])
        #expect(try store.fetch(matching: "a_b", limit: 10).map(\.content) == ["a_b"])
        #expect(try store.fetch(matching: #"C:\p"#, limit: 10).map(\.content) == [#"C:\path"#])
    }

    @Test func fetchRespectsLimit() throws {
        for i in 0..<20 { try add("clip \(i)") }
        let page = try store.fetch(matching: nil, limit: 5)
        #expect(page.map(\.content) == ["clip 19", "clip 18", "clip 17", "clip 16", "clip 15"])
    }

    @Test func trimEvictsOldestUnpinnedAndKeepsPinned() throws {
        let oldest = try add("oldest")
        try store.setPinned(id: oldest.id!, true)
        for i in 0..<5 { try add("c\(i)") }
        let deleted = try store.trim(toUnpinnedLimit: 3)
        #expect(deleted == 2)
        #expect(try store.fetch(matching: nil, limit: 10).map(\.content) == ["oldest", "c4", "c3", "c2"])
    }

    @Test func trimToZeroKeepsOnlyPinned() throws {
        let a = try add("a"); try add("b")
        try store.setPinned(id: a.id!, true)
        try store.trim(toUnpinnedLimit: 0)
        #expect(try store.fetch(matching: nil, limit: 10).map(\.content) == ["a"])
    }

    @Test func deleteAndDeleteAll() throws {
        let a = try add("a"); let b = try add("b"); try add("c")
        try store.delete(id: b.id!)
        #expect(try store.count() == 2)
        try store.setPinned(id: a.id!, true)
        try store.deleteAll(keepingPinned: true)
        #expect(try store.fetch(matching: nil, limit: 10).map(\.content) == ["a"])
        try store.deleteAll(keepingPinned: false)
        #expect(try store.count() == 0)
    }

    @Test func unpinning() throws {
        let a = try add("a"); try add("b")
        try store.setPinned(id: a.id!, true)
        try store.setPinned(id: a.id!, false)
        #expect(try store.fetch(matching: nil, limit: 10).map(\.content) == ["b", "a"])
    }

    @Test func handlesUnicodeAndLargeContent() throws {
        let emoji = "📋 naïve café — 日本語\n\ttabs"
        let big = String(repeating: "x", count: 200_000)
        let e = try add(emoji); let b = try add(big)
        #expect(try store.clip(id: e.id!)?.content == emoji)
        #expect(try store.clip(id: b.id!)?.content.count == 200_000)
    }

    @Test func persistsAcrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("test.sqlite").path

        do {
            let s = try GRDBClipStore(path: path)
            try s.insert(NewClip(content: "survives", kind: .text))
        }
        let reopened = try GRDBClipStore(path: path)   // migrations must be idempotent
        #expect(try reopened.fetch(matching: nil, limit: 10).map(\.content) == ["survives"])
    }
}
