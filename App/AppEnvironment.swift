import Foundation
import KeyboardShortcuts
import Observation
import ParseleyCapture
import ParseleyCore
import ParseleyPaste
import ParseleyStorage

/// Composition root: builds the long-lived services once and wires them together.
/// Views get what they need from here instead of creating their own.
///
/// `@Observable` (macOS 14's Observation framework) makes SwiftUI views that read a
/// property here re-render automatically when it changes. No `@Published` needed.
/// `@ObservationIgnored` opts out properties the UI never displays.
///
/// `@MainActor`: everything here touches UI or the clipboard and runs on the main thread.
@MainActor
@Observable
final class AppEnvironment {
    private(set) var totalClipCount = 0
    /// Human-readable result of the last clipboard change. Handy for checking privacy
    /// filtering while developing.
    private(set) var lastEventDescription = "Waiting for a copy…"
    /// Non-nil if the database couldn't be opened (history then lives in memory only).
    private(set) var storageError: String?

    @ObservationIgnored let store: ClipStore
    @ObservationIgnored let monitor: ClipboardMonitor
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let modes: ModeController
    @ObservationIgnored let panelModel: HistoryPanelModel
    @ObservationIgnored let panelController: PanelController
    @ObservationIgnored let series: SeriesController
    @ObservationIgnored let seriesBar: SeriesBarController

    init() {
        // One SQLite file holds both clip history and series.
        let store: ClipStore
        let seriesStore: SeriesStore
        var storageError: String?
        do {
            let database = try ParseleyDatabase(path: ParseleyDatabase.defaultURL().path)
            store = try GRDBClipStore(database: database)
            seriesStore = GRDBSeriesStore(database: database)
        } catch {
            store = InMemoryClipStore()
            seriesStore = InMemorySeriesStore()
            storageError = "Couldn't open history database: \(error.localizedDescription)"
        }

        let settings = AppSettings()
        var configuration = ClipboardMonitor.Configuration()
        configuration.historyLimit = settings.historyLimit
        configuration.privacy = settings.privacyPolicy
        let monitor = ClipboardMonitor(
            pasteboard: SystemPasteboard(),
            frontmostApp: WorkspaceFrontmostApp(),
            store: store,
            configuration: configuration
        )
        let modes = ModeController()
        let appInfo = AppInfoCache()
        let panelModel = HistoryPanelModel(store: store, monitor: monitor, modes: modes, appInfo: appInfo)
        let series = SeriesController(
            tracker: SeriesTracker(store: seriesStore, rules: settings.seriesRules),
            monitor: monitor,
            appInfo: appInfo
        )
        series.modes = modes
        panelModel.series = series
        // Each copy is read in the number format of the mode its source app belongs to.
        monitor.numberFormatForSource = { [weak modes] source in
            modes?.mode(forSource: source).numberFormat ?? .us
        }

        self.store = store
        self.monitor = monitor
        self.settings = settings
        self.modes = modes
        self.panelModel = panelModel
        self.panelController = PanelController(model: panelModel)
        self.series = series
        self.seriesBar = SeriesBarController(series: series)
        self.storageError = storageError

        // `[weak self]` avoids a retain cycle (self → monitor → closure → self).
        monitor.onEvent = { [weak self] event in
            guard let self else { return }
            lastEventDescription = Self.describe(event)
            if case .stored(let result) = event {
                // Counts toward a running series unless the source app's mode opts out
                // (Writing, Dev). No-op when no series is running.
                let mode = modes.mode(forSource: result.clip.sourceBundleID)
                if mode.countsInSeries {
                    self.series.ingest(result.clip, format: mode.numberFormat)
                }
            }
            refreshCounts()
            // Keep the panel live if it's open while you copy something.
            if panelController.isVisible { panelModel.reload() }
        }
        monitor.start()
        refreshCounts()

        settings.onChange = { [weak self] in self?.applySettings() }
        series.onActiveChanged = { [weak self] active in self?.seriesBar.setVisible(active) }
        seriesBar.setVisible(series.isActive)   // a series may have been running at quit

        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.panelController.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleSeries) { [weak self] in
            self?.series.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .newSeries) { [weak self] in
            self?.series.startNew()
        }
        KeyboardShortcuts.onKeyUp(for: .copySeriesTotal) { [weak self] in
            self?.series.copyCurrentOrLastTotal()
        }
    }

    // MARK: - Actions

    func showPanel() {
        panelController.show()
    }

    var isAccessibilityTrusted: Bool { AccessibilityPermission.isTrusted }

    func enableAutoPaste() {
        panelModel.enableAutoPaste()
    }

    func clearHistory(keepingPinned: Bool = true) {
        try? store.deleteAll(keepingPinned: keepingPinned)
        refreshCounts()
        panelModel.reload()
    }

    /// Pushes changed settings into the running services.
    private func applySettings() {
        monitor.configuration.historyLimit = settings.historyLimit
        monitor.configuration.privacy = settings.privacyPolicy
        series.tracker.rules = settings.seriesRules
        // Apply a lowered limit right away rather than at the next copy.
        try? store.trim(toUnpinnedLimit: settings.historyLimit)
        refreshCounts()
    }

    // MARK: - Helpers

    private func refreshCounts() {
        totalClipCount = (try? store.count()) ?? 0
    }

    private static func describe(_ event: CaptureEvent) -> String {
        switch event {
        case .stored(.inserted(let clip)):
            return "Saved \(clip.kind.displayName.lowercased()) from \(clip.sourceBundleID ?? "unknown app")"
        case .stored(.duplicateOfLatest):
            return "Same as previous copy (not duplicated)"
        case .skipped(.privacy(.blockedPasteboardType(let type))):
            return "Skipped: marked private (\(type))"
        case .skipped(.privacy(.excludedApp(let app))):
            return "Skipped: excluded app (\(app))"
        case .skipped(.privacy(.allow)):
            return "Skipped"
        case .skipped(.noText):
            return "Skipped: not text"
        case .skipped(.whitespaceOnly):
            return "Skipped: only whitespace"
        case .skipped(.tooLong(let n)):
            return "Skipped: too long (\(n) characters)"
        case .failed(let message):
            return "Error saving clip: \(message)"
        }
    }
}
