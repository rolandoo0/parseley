import Foundation

/// A stored clipboard entry. Plain value type: no database or UI dependencies, so it
/// can be shared by the app, a future CLI, and a future MCP server.
public struct Clip: Identifiable, Hashable, Sendable {
    /// Database row id. `nil` only before the clip has been saved.
    public var id: Int64?
    public var content: String
    /// Fast fingerprint of `content` (see `ContentHash`). Used for lookups, not security.
    public var contentHash: String
    public var kind: ClipKind
    /// Bundle id of the app that was frontmost when the copy happened, e.g. "com.apple.Safari".
    public var sourceBundleID: String?
    /// When the clip was first captured.
    public var createdAt: Date
    /// When the clip was last copied, re-copied, or pasted from history. History is
    /// ordered by this, so re-using an old clip moves it back to the top.
    public var lastUsedAt: Date
    /// Pinned clips are listed first and never evicted by the history limit.
    public var isPinned: Bool

    public init(
        id: Int64? = nil,
        content: String,
        kind: ClipKind,
        sourceBundleID: String? = nil,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.content = content
        self.contentHash = ContentHash.of(content)
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.isPinned = isPinned
    }
}

/// Input for `ClipStore.insert`: what the capture pipeline knows about a new copy.
public struct NewClip: Hashable, Sendable {
    public var content: String
    public var kind: ClipKind
    public var sourceBundleID: String?

    public init(content: String, kind: ClipKind, sourceBundleID: String? = nil) {
        self.content = content
        self.kind = kind
        self.sourceBundleID = sourceBundleID
    }
}
