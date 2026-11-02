import Foundation

/// One copy that went into a series. Keeps its own numbers, so a whole spreadsheet
/// column is one entry (one row in the bar, undone in one go) while stats still count
/// every value individually: the "hybrid" model.
public struct SeriesEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The history clip it came from (nil if that clip was later deleted or trimmed).
    public var clipID: Int64?
    public var sourceBundleID: String?
    public var createdAt: Date
    public var values: [Decimal]
    /// Short one-line label for the bar.
    public var preview: String
    /// False for copies that mixed text and numbers: shown as "skipped · click to add"
    /// and left out of the stats until the user includes them.
    public var isIncluded: Bool

    public init(
        id: UUID = UUID(), clipID: Int64?, sourceBundleID: String?, createdAt: Date,
        values: [Decimal], preview: String, isIncluded: Bool
    ) {
        self.id = id
        self.clipID = clipID
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.values = values
        self.preview = preview
        self.isIncluded = isIncluded
    }

    public var subtotal: Decimal { values.reduce(0, +) }
}

/// A running tally: numbers collected from successive copies while it's active.
public struct Series: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Nil while the series is active.
    public var endedAt: Date?
    public var entries: [SeriesEntry]

    public init(id: UUID = UUID(), name: String, createdAt: Date, endedAt: Date? = nil, entries: [SeriesEntry] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.entries = entries
    }

    public var includedEntries: [SeriesEntry] { entries.filter(\.isIncluded) }
    public var skippedEntries: [SeriesEntry] { entries.filter { !$0.isIncluded } }

    /// Every included value, in order: what the stats are computed over.
    public var values: [Decimal] { includedEntries.flatMap(\.values) }

    public var stats: NumberStats? {
        let values = values
        let digits = values.map(Self.fractionDigits).max() ?? 0
        return NumberStats(values: values, inputFractionDigits: digits)
    }

    private static func fractionDigits(_ value: Decimal) -> Int {
        let text = NumberFormatting.plain(value, maxFractionDigits: 20)
        return text.split(separator: ".", maxSplits: 1).dropFirst().first?.count ?? 0
    }
}

/// When to suggest starting a new series. The tracker never splits on its own: it adds
/// the copy and *asks*, and the user can move that copy into a fresh series.
public struct SeriesRules: Equatable, Sendable {
    /// Suggest a new series when this long has passed since the last counted copy.
    /// Nil = off.
    public var idleGap: TimeInterval? = 10 * 60
    /// Suggest a new series when numbers start coming from a different app.
    public var askOnAppSwitch = false
    /// Copying the same clip again within this window is treated as an accidental
    /// double ⌘C and ignored.
    public var repeatCopyWindow: TimeInterval = 3
    /// How many "skipped · click to add" entries to keep (older ones are dropped).
    public var maxSkippedEntries = 5

    public init() {}
}

/// A pending question shown in the series bar.
public enum SeriesPrompt: Equatable, Sendable {
    /// No counted copy for `minutes`; the copy `entryID` might start a new task.
    case idleGap(minutes: Int, entryID: UUID)
    /// Numbers now come from a different app than before.
    case appSwitch(from: String?, to: String?, entryID: UUID)

    public var entryID: UUID {
        switch self {
        case .idleGap(_, let id), .appSwitch(_, _, let id): id
        }
    }
}

/// Persistence for series. Implemented by GRDBSeriesStore (SQLite) and InMemorySeriesStore.
public protocol SeriesStore: AnyObject {
    /// Inserts or replaces the series and all its entries.
    func save(_ series: Series) throws
    /// The most recent series that hasn't ended, if any (restored at launch).
    func activeSeries() throws -> Series?
    /// Most recent first, including the active one.
    func recentSeries(limit: Int) throws -> [Series]
    func delete(id: UUID) throws
    func count() throws -> Int
}

/// Array-backed `SeriesStore` for tests and previews.
public final class InMemorySeriesStore: SeriesStore {
    private var all: [Series] = []
    public init() {}

    public func save(_ series: Series) throws {
        if let i = all.firstIndex(where: { $0.id == series.id }) { all[i] = series } else { all.append(series) }
    }
    public func activeSeries() throws -> Series? {
        all.filter { $0.endedAt == nil }.max { $0.createdAt < $1.createdAt }
    }
    public func recentSeries(limit: Int) throws -> [Series] {
        Array(all.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
    public func delete(id: UUID) throws { all.removeAll { $0.id == id } }
    public func count() throws -> Int { all.count }
}
