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
    @ObservationIgnored let panelModel: HistoryPanelModel
    @ObservationIgnored let panelController: PanelController

    init() {
        let store: ClipStore
        var storageError: String?
        do {
            store = try GRDBClipStore(path: GRDBClipStore.defaultDatabaseURL().path)
        } catch {
            store = InMemoryClipStore()
            storageError = "Couldn't open history database: \(error.localizedDescription)"
        }
        let monitor = ClipboardMonitor(
            pasteboard: SystemPasteboard(),
            frontmostApp: WorkspaceFrontmostApp(),
            store: store
        )
        let panelModel = HistoryPanelModel(store: store, monitor: monitor)

        self.store = store
        self.monitor = monitor
        self.panelModel = panelModel
        self.panelController = PanelController(model: panelModel)
        self.storageError = storageError

        // `[weak self]` avoids a retain cycle (self → monitor → closure → self).
        monitor.onEvent = { [weak self] event in
            guard let self else { return }
            lastEventDescription = Self.describe(event)
            refreshCounts()
            // Keep the panel live if it's open while you copy something.
            if panelController.isVisible { panelModel.reload() }
        }
        monitor.start()
        refreshCounts()

        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.panelController.toggle()
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

    func clearHistory() {
        try? store.deleteAll(keepingPinned: true)
        refreshCounts()
        panelModel.reload()
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
