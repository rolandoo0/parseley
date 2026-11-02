import Foundation
import Observation
import ParseleyCapture
import ParseleyCore
import ParseleyStorage

/// Composition root: builds the long-lived services once and exposes the state the UI
/// needs. Views get services from here instead of creating their own.
///
/// `@Observable` (macOS 14's Observation framework) makes SwiftUI views that read a
/// property here re-render automatically when it changes. No `@Published` needed.
/// `@ObservationIgnored` opts out properties the UI never displays.
///
/// Everything here runs on the main thread (SwiftUI and the capture timer both use it).
@Observable
final class AppEnvironment {
    /// Most recent clips, shown in the menu. Refreshed after every clipboard change.
    private(set) var recentClips: [Clip] = []
    private(set) var totalClipCount = 0
    /// Human-readable result of the last clipboard change, handy for checking privacy
    /// filtering while developing.
    private(set) var lastEventDescription = "Waiting for a copy…"
    /// Non-nil if the database couldn't be opened (history then lives in memory only).
    private(set) var storageError: String?

    @ObservationIgnored let store: ClipStore
    @ObservationIgnored let monitor: ClipboardMonitor

    static let menuClipCount = 15

    init() {
        let store: ClipStore
        var storageError: String?
        do {
            store = try GRDBClipStore(path: GRDBClipStore.defaultDatabaseURL().path)
        } catch {
            store = InMemoryClipStore()
            storageError = "Couldn't open history database: \(error.localizedDescription)"
        }
        self.store = store
        self.storageError = storageError
        self.monitor = ClipboardMonitor(
            pasteboard: SystemPasteboard(),
            frontmostApp: WorkspaceFrontmostApp(),
            store: store
        )

        // `[weak self]` avoids a retain cycle (self → monitor → closure → self).
        monitor.onEvent = { [weak self] event in
            self?.lastEventDescription = Self.describe(event)
            self?.reload()
        }
        monitor.start()
        reload()
    }

    // MARK: - Actions

    func reload() {
        do {
            recentClips = try store.fetch(matching: nil, limit: Self.menuClipCount)
            totalClipCount = try store.count()
        } catch {
            lastEventDescription = "Error reading history: \(error.localizedDescription)"
        }
    }

    /// Puts a history clip back on the clipboard (⌘V it yourself; auto-paste comes in M2).
    func copy(_ clip: Clip) {
        guard let id = clip.id else { return }
        do {
            try monitor.copyToClipboard(clipID: id)
            lastEventDescription = "Copied from history"
        } catch {
            lastEventDescription = "Copy failed: \(error.localizedDescription)"
        }
        reload()
    }

    func clearHistory() {
        try? store.deleteAll(keepingPinned: true)
        reload()
    }

    // MARK: - Helpers

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
