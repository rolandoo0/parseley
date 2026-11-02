import Foundation
import Observation
import ParseleyCapture
import ParseleyCore

/// Bridges the (non-observable) `SeriesTracker` engine to SwiftUI: mirrors its state
/// into observable properties and exposes the actions the bar, panel and menu use.
@MainActor
@Observable
final class SeriesController {
    private(set) var active: Series?
    private(set) var prompt: SeriesPrompt?
    private(set) var recent: [Series] = []
    private(set) var toast: String?
    /// The bar's expanded state. Expands by itself when a prompt appears.
    var isExpanded = false {
        didSet { if isExpanded != oldValue { onExpandedChanged?(isExpanded) } }
    }

    /// Called when a series starts/stops (shows/hides the bar).
    @ObservationIgnored var onActiveChanged: ((Bool) -> Void)?
    @ObservationIgnored var onExpandedChanged: ((Bool) -> Void)?

    /// Display format follows the current mode (set by AppEnvironment).
    @ObservationIgnored weak var modes: ModeController?

    @ObservationIgnored let tracker: SeriesTracker
    @ObservationIgnored let appInfo: AppInfoCache
    @ObservationIgnored private let monitor: ClipboardMonitor
    @ObservationIgnored private let store: ClipStore
    /// Called after a series total was saved to history (AppEnvironment refreshes).
    @ObservationIgnored var onHistoryChanged: (() -> Void)?
    /// Shows a message when the bar isn't visible (set to the app's toast).
    @ObservationIgnored var announce: ((String) -> Void)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(tracker: SeriesTracker, monitor: ClipboardMonitor, store: ClipStore, appInfo: AppInfoCache) {
        self.tracker = tracker
        self.monitor = monitor
        self.store = store
        self.appInfo = appInfo
        tracker.onChange = { [weak self] in self?.sync() }
        tracker.onSeriesEnded = { [weak self] series in self?.recordTotal(of: series) }
        sync()
    }

    var isActive: Bool { active != nil }
    var stats: NumberStats? { active?.stats }
    var format: NumberFormat { modes?.current.numberFormat ?? .us }
    /// Stat tiles in the current mode's format, its main stat first.
    var statItems: [NumberStats.Item] {
        stats?.items(format: format, primary: modes?.current.primaryStat) ?? []
    }
    var sumItem: NumberStats.Item? { stats?.items(format: format).first { $0.label == "Sum" } }

    // MARK: - Lifecycle

    /// Start if nothing is running, otherwise stop.
    func toggle() {
        if tracker.isActive {
            tracker.stop()
        } else {
            tracker.start()
        }
    }

    /// End the current series (it's saved) and start a fresh one.
    func startNew() {
        tracker.start()
        showToast("Started \(tracker.active?.name ?? "a new series")")
    }

    func stop() { tracker.stop() }
    func rename(_ name: String) { tracker.rename(name) }

    // MARK: - Copies

    /// A copy captured from the clipboard, read in its source app's number format.
    func ingest(_ clip: Clip, format: NumberFormat) {
        tracker.ingest(content: clip.content, clipID: clip.id, sourceBundleID: clip.sourceBundleID, format: format)
    }

    /// "Add to series" from the history panel: always included (the user chose them),
    /// starting a series first if none is running.
    func add(_ clips: [Clip], format: NumberFormat? = nil) {
        let format = format ?? self.format
        if !tracker.isActive { tracker.start() }
        var added = 0
        for clip in clips {
            if case .added = tracker.ingest(content: clip.content, clipID: clip.id, sourceBundleID: clip.sourceBundleID,
                                            force: true, format: format) {
                added += 1
            }
        }
        showToast(added == 0 ? "No numbers to add" : "Added \(added) clip\(added == 1 ? "" : "s") to \(active?.name ?? "series")")
    }

    func include(_ entry: SeriesEntry) { tracker.setIncluded(true, entryID: entry.id) }
    func exclude(_ entry: SeriesEntry) { tracker.setIncluded(false, entryID: entry.id) }
    func remove(_ entry: SeriesEntry) { tracker.remove(entryID: entry.id) }
    func undoLast() { tracker.undoLast() }
    func acceptPrompt() { tracker.acceptPrompt() }
    func dismissPrompt() { tracker.dismissPrompt() }

    // MARK: - Copying results

    func copy(_ item: NumberStats.Item) {
        copyText(item.copyText, message: "Copied \(item.label.lowercased()): \(item.display)")
    }

    func copySum() {
        guard let sum = sumItem else { return showToast("Nothing counted yet") }
        copy(sum)
    }

    /// Global hotkey: the running series' total, or the last finished series' total.
    func copyCurrentOrLastTotal() {
        if isActive { return copySum() }
        if let last = recent.first(where: { $0.endedAt != nil && !$0.values.isEmpty }) {
            copySum(of: last)
        } else {
            showToast("No series yet")
        }
    }

    /// The result the "paste series result" hotkey pastes: from the running series, or
    /// the last finished one when none is running. `preferred` is a stat label ("Sum",
    /// "Average"…); nil means the current mode's main stat. Falls back to the sum.
    func pasteResult(preferred: String?) -> (item: NumberStats.Item, series: Series)? {
        let series: Series? = isActive
            ? active
            : recent.first { $0.endedAt != nil && !$0.values.isEmpty }
        guard let series, let stats = series.stats else { return nil }
        let label = preferred ?? modes?.current.primaryStat ?? "Sum"
        let items = stats.items(format: format)
        guard let item = items.first(where: { $0.label == label }) ?? items.first(where: { $0.label == "Sum" })
        else { return nil }
        return (item, series)
    }

    /// All counted values as a column, ready to paste into a spreadsheet.
    func copyValues() {
        guard let values = active?.values, !values.isEmpty else { return showToast("Nothing counted yet") }
        let column = values.map { NumberFormatting.plain($0, maxFractionDigits: 20, format: format) }.joined(separator: "\n")
        copyText(column, message: "Copied \(values.count) values")
    }

    /// Menu bar "Recent series": copy that series' total.
    func copySum(of series: Series) {
        guard let sum = series.stats?.items(format: format).first(where: { $0.label == "Sum" }) else { return }
        copyText(sum.copyText, message: "Copied \(series.name) total")
    }

    // MARK: - Helpers

    /// Saves a finished series' total into clipboard history (as a "Series total" clip
    /// that the history limit never deletes). Pasting it pastes the plain number.
    private func recordTotal(of series: Series) {
        guard let stats = series.stats else { return }
        let items = stats.items(format: format)
        guard let sum = items.first(where: { $0.label == "Sum" }) else { return }
        let note = "Σ \(sum.display) · \(series.name) · \(stats.count) value\(stats.count == 1 ? "" : "s")"
        do {
            try store.append(NewClip(
                content: sum.copyText, kind: .seriesTotal,
                sourceBundleID: Bundle.main.bundleIdentifier, numbers: [stats.sum], note: note
            ))
            onHistoryChanged?()
        } catch {
            showToast("Couldn't save the total: \(error.localizedDescription)")
        }
    }

    private func copyText(_ text: String, message: String) {
        do {
            try monitor.copyToClipboard(newText: text)
            showToast(message)
            if !isActive { announce?(message) }   // no bar to show it in
        } catch {
            showToast("Couldn't copy: \(error.localizedDescription)")
        }
    }

    private func sync() {
        let wasActive = active != nil
        let hadPrompt = prompt != nil
        active = tracker.active
        prompt = tracker.prompt
        recent = tracker.recentSeries(limit: 8)
        if prompt != nil && !hadPrompt { isExpanded = true }   // make the question visible
        if wasActive != (active != nil) {
            if active == nil { isExpanded = false }
            onActiveChanged?(active != nil)
        }
    }

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
