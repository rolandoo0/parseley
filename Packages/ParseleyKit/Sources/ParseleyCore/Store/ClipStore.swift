import Foundation

/// Result of inserting a clip.
public enum InsertResult: Equatable, Sendable {
    /// A new row was created.
    case inserted(Clip)
    /// The content equals the most recent clip, so no new row was created. That clip's
    /// `lastUsedAt` was refreshed instead (consecutive-copy dedupe).
    case duplicateOfLatest(Clip)

    public var clip: Clip {
        switch self {
        case .inserted(let c), .duplicateOfLatest(let c): c
        }
    }
}

/// Storage interface for clipboard history.
///
/// Defined in Core (not in ParseleyStorage) so that the capture pipeline, the UI, and
/// tests depend only on this protocol. The real implementation is `GRDBClipStore`;
/// `InMemoryClipStore` is for tests and SwiftUI previews. A future CLI / MCP server
/// would open the same SQLite file through `GRDBClipStore`.
///
/// Ordering everywhere: pinned first, then most recently used first.
public protocol ClipStore: AnyObject {
    /// Saves a new clip, unless it's identical to the most recent clip (see `InsertResult`).
    @discardableResult
    func insert(_ newClip: NewClip) throws -> InsertResult

    /// Clips whose content contains `query` (case-insensitive), or all clips if `query`
    /// is nil/empty.
    func fetch(matching query: String?, limit: Int) throws -> [Clip]

    func clip(id: Int64) throws -> Clip?
    func count() throws -> Int

    func setPinned(id: Int64, _ pinned: Bool) throws
    /// Marks a clip as just used (moves it to the top of history).
    func touch(id: Int64) throws
    func delete(id: Int64) throws
    /// Deletes everything, or everything except pinned clips.
    func deleteAll(keepingPinned: Bool) throws

    /// Evicts the oldest unpinned clips so at most `limit` unpinned clips remain.
    /// Returns how many were deleted.
    @discardableResult
    func trim(toUnpinnedLimit limit: Int) throws -> Int
}
