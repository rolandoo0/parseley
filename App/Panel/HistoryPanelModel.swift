import AppKit
import Observation
import ParseleyCapture
import ParseleyCore
import ParseleyPaste

/// State and actions behind the history panel. The view (HistoryView) only renders this
/// and forwards user input. Keyboard handling lives in PanelController.
@MainActor
@Observable
final class HistoryPanelModel {
    enum ActivationMode { case paste, copyOnly }

    /// Search text. Changing it re-queries and selects the best (first) match.
    var query = "" {
        didSet { if query != oldValue { reload(resetSelection: true) } }
    }
    private(set) var clips: [Clip] = []
    private(set) var selection = ListSelection()
    private(set) var isAccessibilityTrusted = AccessibilityPermission.isTrusted
    /// Incremented each time the panel opens; HistoryView watches it to focus the search field.
    private(set) var focusRequest = 0
    private(set) var errorMessage: String?

    var selectedClip: Clip? {
        guard let id = selection.selectedID else { return nil }
        return clips.first { $0.id == id }
    }

    // Wired up by PanelController.
    @ObservationIgnored var closePanel: () -> Void = {}
    @ObservationIgnored var pasteTarget: () -> NSRunningApplication? = { nil }

    @ObservationIgnored let appInfo = AppInfoCache()
    @ObservationIgnored private let store: ClipStore
    @ObservationIgnored private let monitor: ClipboardMonitor
    @ObservationIgnored private let pasteService = PasteService()
    @ObservationIgnored private var hasPromptedForAccessibility = false

    /// How many clips the panel lists. Search always runs over the whole history.
    static let fetchLimit = 300

    init(store: ClipStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
    }

    // MARK: - Lifecycle

    func prepareForShow() {
        errorMessage = nil
        if query.isEmpty {
            reload(resetSelection: true)
        } else {
            query = ""   // didSet reloads
        }
        // There's no notification when the user grants Accessibility, so re-check here.
        isAccessibilityTrusted = AccessibilityPermission.isTrusted
        focusRequest += 1
    }

    func reload(resetSelection: Bool = false) {
        do {
            clips = try store.fetch(matching: query, limit: Self.fetchLimit)
            selection.update(ids: ids, resetToFirst: resetSelection)
        } catch {
            errorMessage = "Couldn't load history: \(error.localizedDescription)"
        }
    }

    // MARK: - Selection

    func moveSelection(by delta: Int) {
        selection.move(by: delta, in: ids)
    }

    func select(_ clip: Clip) {
        if let id = clip.id { selection.select(id, in: ids) }
    }

    // MARK: - Actions

    /// Enter / double-click: put the clip on the clipboard, close, and paste into the app
    /// that was frontmost before the panel opened.
    func activate(_ clip: Clip? = nil, mode: ActivationMode = .paste) {
        guard let clip = clip ?? selectedClip, let id = clip.id else { return }
        do {
            try monitor.copyToClipboard(clipID: id)
        } catch {
            errorMessage = "Couldn't copy: \(error.localizedDescription)"
            return
        }
        let target = pasteTarget()
        closePanel()

        guard mode == .paste else { return }
        if pasteService.paste(into: target) == .needsAccessibility {
            // Graceful fallback: the clip is already on the clipboard, so the user can
            // press ⌘V. The first time per launch, also show the system prompt that
            // explains the permission and links to System Settings.
            if !hasPromptedForAccessibility {
                hasPromptedForAccessibility = true
                AccessibilityPermission.requestWithSystemPrompt()
            }
        }
    }

    func togglePin(_ clip: Clip? = nil) {
        guard let clip = clip ?? selectedClip, let id = clip.id else { return }
        perform { try store.setPinned(id: id, !clip.isPinned) }
    }

    func delete(_ clip: Clip) {
        guard let id = clip.id else { return }
        perform { try store.delete(id: id) }
    }

    func deleteSelected() {
        if let clip = selectedClip { delete(clip) }
    }

    func enableAutoPaste() {
        // The prompt adds Parseley to the Accessibility list (so the user only has to
        // flip the switch), then we open that pane directly.
        AccessibilityPermission.requestWithSystemPrompt()
        AccessibilityPermission.openSystemSettings()
    }

    // MARK: - Helpers

    private var ids: [Int64] { clips.compactMap(\.id) }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
