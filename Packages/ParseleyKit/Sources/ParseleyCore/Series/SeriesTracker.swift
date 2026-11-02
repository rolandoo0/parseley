import Foundation

/// The running-tally engine: owns the active series, decides what each copy contributes,
/// raises "start a new series?" prompts, and persists every change.
///
/// Plain logic with an injectable clock and store, so it's fully unit-testable. Use from
/// the main thread.
public final class SeriesTracker {
    public enum IgnoreReason: Equatable, Sendable {
        case noActiveSeries
        case noNumbers
        /// Same clip copied again within `repeatCopyWindow` (an accidental double ⌘C).
        case repeatedCopy
    }

    public enum IngestResult: Equatable, Sendable {
        case ignored(IgnoreReason)
        /// Numbers-only copy: counted.
        case added(SeriesEntry)
        /// Text mixed with numbers: kept as "skipped · click to add", not counted.
        case skipped(SeriesEntry)
    }

    public private(set) var active: Series?
    public private(set) var prompt: SeriesPrompt?
    public var rules: SeriesRules
    /// Called after every change (the UI refreshes from it).
    public var onChange: (() -> Void)?
    /// Last persistence error, if any (the tracker keeps working in memory).
    public private(set) var lastError: String?

    private let store: SeriesStore
    private let now: () -> Date
    private let parser = NumberParser()
    /// Clips longer than this aren't scanned (keeps capture instant).
    private static let maxContentLength = 200_000

    public init(store: SeriesStore, rules: SeriesRules = SeriesRules(), now: @escaping () -> Date = Date.init) {
        self.store = store
        self.rules = rules
        self.now = now
        // Resume a series that was running when the app quit.
        active = try? store.activeSeries()
    }

    public var isActive: Bool { active != nil }

    // MARK: - Lifecycle

    /// Starts a series (ending the current one first, if any).
    @discardableResult
    public func start(name: String? = nil) -> Series {
        if active != nil { finishActive() }
        let series = Series(name: name ?? defaultName(), createdAt: now())
        active = series
        prompt = nil
        persist(series)
        changed()
        return series
    }

    /// Ends the active series; it stays in the store as history.
    public func stop() {
        guard active != nil else { return }
        finishActive()
        changed()
    }

    public func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var series = active, !trimmed.isEmpty else { return }
        series.name = trimmed
        update(series)
    }

    // MARK: - Copies

    /// Feeds one copy into the active series.
    /// - Parameter force: include it even if it mixes text and numbers (manual "add").
    @discardableResult
    public func ingest(content: String, clipID: Int64?, sourceBundleID: String?, force: Bool = false) -> IngestResult {
        guard var series = active else { return .ignored(.noActiveSeries) }
        guard content.utf16.count <= Self.maxContentLength else { return .ignored(.noNumbers) }
        let timestamp = now()

        if !force, let clipID, let last = series.entries.last, last.clipID == clipID,
           timestamp.timeIntervalSince(last.createdAt) < rules.repeatCopyWindow {
            return .ignored(.repeatedCopy)
        }

        let numbersOnly = parser.numbersOnly(content)
        let numbers = numbersOnly ?? parser.parse(content)
        guard !numbers.isEmpty else { return .ignored(.noNumbers) }

        let entry = SeriesEntry(
            clipID: clipID, sourceBundleID: sourceBundleID, createdAt: timestamp,
            values: numbers.map(\.value), preview: ClipPreview.title(content, maxLength: 60),
            isIncluded: force || numbersOnly != nil
        )

        if entry.isIncluded, let previous = series.includedEntries.last {
            if let gap = rules.idleGap, timestamp.timeIntervalSince(previous.createdAt) >= gap {
                let minutes = Int(timestamp.timeIntervalSince(previous.createdAt) / 60)
                prompt = .idleGap(minutes: minutes, entryID: entry.id)
            } else if rules.askOnAppSwitch, previous.sourceBundleID != sourceBundleID {
                prompt = .appSwitch(from: previous.sourceBundleID, to: sourceBundleID, entryID: entry.id)
            }
        }

        series.entries.append(entry)
        if !entry.isIncluded { dropOldSkipped(&series) }
        update(series)
        return entry.isIncluded ? .added(entry) : .skipped(entry)
    }

    /// "Click to add" (true) or leave out (false).
    public func setIncluded(_ included: Bool, entryID: UUID) {
        guard var series = active, let i = series.entries.firstIndex(where: { $0.id == entryID }) else { return }
        series.entries[i].isIncluded = included
        update(series)
    }

    public func remove(entryID: UUID) {
        guard var series = active else { return }
        series.entries.removeAll { $0.id == entryID }
        if prompt?.entryID == entryID { prompt = nil }
        update(series)
    }

    /// Removes the most recent counted copy.
    public func undoLast() {
        guard let last = active?.includedEntries.last else { return }
        remove(entryID: last.id)
    }

    // MARK: - Prompts

    /// "Start new series": moves the prompted copy (and anything copied after it) into a
    /// fresh series; the rest stays in the old one, which is ended.
    public func acceptPrompt() {
        guard let prompt, var old = active,
              let index = old.entries.firstIndex(where: { $0.id == prompt.entryID })
        else { self.prompt = nil; changed(); return }
        let moved = Array(old.entries[index...])
        old.entries.removeSubrange(index...)
        old.endedAt = now()
        persist(old)

        let fresh = Series(name: defaultName(), createdAt: now(), entries: moved)
        active = fresh
        self.prompt = nil
        persist(fresh)
        changed()
    }

    /// "Keep": the copy stays in the current series.
    public func dismissPrompt() {
        guard prompt != nil else { return }
        prompt = nil
        changed()
    }

    // MARK: - History

    public func recentSeries(limit: Int = 10) -> [Series] {
        (try? store.recentSeries(limit: limit)) ?? []
    }

    // MARK: - Helpers

    private func finishActive() {
        guard var series = active else { return }
        series.endedAt = now()
        persist(series)
        active = nil
        prompt = nil
    }

    private func dropOldSkipped(_ series: inout Series) {
        let skipped = series.skippedEntries
        guard skipped.count > rules.maxSkippedEntries else { return }
        let drop = Set(skipped.prefix(skipped.count - rules.maxSkippedEntries).map(\.id))
        series.entries.removeAll { drop.contains($0.id) }
    }

    private func update(_ series: Series) {
        active = series
        persist(series)
        changed()
    }

    private func persist(_ series: Series) {
        do {
            try store.save(series)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    private func defaultName() -> String {
        "Series \(((try? store.count()) ?? 0) + 1)"
    }

    private func changed() {
        onChange?()
    }
}
