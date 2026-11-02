import Foundation

/// Array-backed `ClipStore` for tests and SwiftUI previews. Not thread-safe; use from
/// one thread. Behaviour mirrors `GRDBClipStore`.
public final class InMemoryClipStore: ClipStore {
    private var clips: [Clip] = []
    private var nextID: Int64 = 1
    private let now: () -> Date

    /// - Parameter now: Clock, injectable so tests get deterministic ordering.
    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    @discardableResult
    public func insert(_ newClip: NewClip) throws -> InsertResult {
        let timestamp = now()
        if let latestIndex = indexOfLatest(), clips[latestIndex].content == newClip.content {
            clips[latestIndex].lastUsedAt = timestamp
            return .duplicateOfLatest(clips[latestIndex])
        }
        let clip = Clip(
            id: nextID, content: newClip.content, kind: newClip.kind,
            sourceBundleID: newClip.sourceBundleID, createdAt: timestamp
        )
        nextID += 1
        clips.append(clip)
        return .inserted(clip)
    }

    public func fetch(matching query: String?, limit: Int) throws -> [Clip] {
        var result = sorted(clips)
        if let query, !query.isEmpty {
            result = result.filter { $0.content.range(of: query, options: .caseInsensitive) != nil }
        }
        return Array(result.prefix(limit))
    }

    public func clip(id: Int64) throws -> Clip? { clips.first { $0.id == id } }
    public func count() throws -> Int { clips.count }

    public func setPinned(id: Int64, _ pinned: Bool) throws {
        if let i = clips.firstIndex(where: { $0.id == id }) { clips[i].isPinned = pinned }
    }

    public func touch(id: Int64) throws {
        if let i = clips.firstIndex(where: { $0.id == id }) { clips[i].lastUsedAt = now() }
    }

    public func delete(id: Int64) throws { clips.removeAll { $0.id == id } }

    public func deleteAll(keepingPinned: Bool) throws {
        clips.removeAll { !keepingPinned || !$0.isPinned }
    }

    @discardableResult
    public func trim(toUnpinnedLimit limit: Int) throws -> Int {
        let keep = Set(sorted(clips.filter { !$0.isPinned }).prefix(max(0, limit)).map(\.id))
        let before = clips.count
        clips.removeAll { !$0.isPinned && !keep.contains($0.id) }
        return before - clips.count
    }

    // MARK: - Helpers

    /// Most recently used clip, regardless of pin state (that's what "consecutive" means).
    private func indexOfLatest() -> Int? {
        clips.indices.max { a, b in
            (clips[a].lastUsedAt, clips[a].id ?? 0) < (clips[b].lastUsedAt, clips[b].id ?? 0)
        }
    }

    private func sorted(_ input: [Clip]) -> [Clip] {
        input.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            if a.lastUsedAt != b.lastUsedAt { return a.lastUsedAt > b.lastUsedAt }
            return (a.id ?? 0) > (b.id ?? 0)
        }
    }
}
