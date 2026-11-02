import Foundation

/// A stored clipboard entry, including its full text. Plain value type: no database or
/// UI dependencies, so the app, the CLI and the MCP server share it.
///
/// Lists use the lighter `ClipSummary` instead; load a full `Clip` only when its text
/// is actually needed (preview, paste, transforms).
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
    /// Optional label shown instead of the text, e.g. "Σ 4,210.50 · Q3 expenses".
    public var note: String?

    public init(
        id: Int64? = nil,
        content: String,
        kind: ClipKind,
        sourceBundleID: String? = nil,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        isPinned: Bool = false,
        note: String? = nil
    ) {
        self.id = id
        self.content = content
        self.contentHash = ContentHash.of(content)
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.isPinned = isPinned
        self.note = note
    }
}

/// What a list row needs, without the full text: a short preview plus facts computed
/// once at capture time (line count, number count and sum). Keeps the panel's memory
/// flat no matter how big individual clips are.
public struct ClipSummary: Identifiable, Hashable, Sendable {
    public var id: Int64
    /// First non-blank line, collapsed and truncated (≤ `ClipDigest.previewLength`).
    public var preview: String
    /// Length of the full text in UTF-16 units (cheap to compute, good enough for display).
    public var length: Int
    public var lineCount: Int
    public var kind: ClipKind
    public var sourceBundleID: String?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var isPinned: Bool
    public var note: String?
    /// How many numbers the clip contains, and their sum (nil if none).
    public var numberCount: Int
    public var numberSum: Decimal?

    public init(
        id: Int64, preview: String, length: Int, lineCount: Int, kind: ClipKind,
        sourceBundleID: String?, createdAt: Date, lastUsedAt: Date, isPinned: Bool,
        note: String?, numberCount: Int, numberSum: Decimal?
    ) {
        self.id = id
        self.preview = preview
        self.length = length
        self.lineCount = lineCount
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
        self.note = note
        self.numberCount = numberCount
        self.numberSum = numberSum
    }

    /// The row title: the note if there is one, else the preview.
    public var title: String { note ?? preview }
}

/// Input for `ClipStore.insert`: what the capture pipeline knows about a new copy.
public struct NewClip: Hashable, Sendable {
    public var content: String
    public var kind: ClipKind
    public var sourceBundleID: String?
    /// Numbers already parsed in the source app's format. Nil = the store parses them
    /// itself (US format).
    public var numbers: [Decimal]?
    public var note: String?

    public init(content: String, kind: ClipKind, sourceBundleID: String? = nil,
                numbers: [Decimal]? = nil, note: String? = nil) {
        self.content = content
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.numbers = numbers
        self.note = note
    }
}

/// Facts derived from a clip's text once, at capture time, so lists never re-scan it.
public struct ClipDigest: Equatable, Sendable {
    public static let previewLength = 200
    /// Clips longer than this aren't scanned for numbers (keeps capture instant).
    public static let maxScanLength = 200_000
    /// At most this many numbers are stored per clip.
    public static let maxNumbers = 10_000

    public var preview: String
    public var length: Int
    public var lineCount: Int
    public var numbers: [Decimal]

    public var sum: Decimal? { numbers.isEmpty ? nil : numbers.reduce(0, +) }

    public init(content: String, numbers knownNumbers: [Decimal]? = nil, format: NumberFormat = .us) {
        preview = ClipPreview.title(content, maxLength: Self.previewLength)
        length = content.utf16.count
        lineCount = ClipPreview.lineCount(content)
        if let knownNumbers {
            numbers = Array(knownNumbers.prefix(Self.maxNumbers))
        } else if length <= Self.maxScanLength {
            numbers = Array(NumberParser(format: format).parse(content).prefix(Self.maxNumbers).map(\.value))
        } else {
            numbers = []
        }
    }
}
