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
    /// ⌘-click / ⇧-click selection of several clips (combined stats, joint transforms).
    private(set) var multi = MultiSelection()
    private(set) var isAccessibilityTrusted = AccessibilityPermission.isTrusted
    /// Incremented each time the panel opens; HistoryView watches it to focus the search field.
    private(set) var focusRequest = 0
    private(set) var errorMessage: String?
    /// Brief confirmation shown in the footer ("Copied Sum: 1,492.5"). Clears itself.
    private(set) var toast: String?

    var selectedClip: Clip? {
        guard let id = selection.selectedID else { return nil }
        return clips.first { $0.id == id }
    }

    /// The clips actions apply to: all multi-selected clips (in list order), or just the
    /// focused one.
    var selectedClips: [Clip] {
        if multi.isActive { return clips.filter { multi.contains($0.id) } }
        return selectedClip.map { [$0] } ?? []
    }

    /// Stats over every number in all multi-selected clips.
    var combinedStats: NumberStats? {
        guard multi.isActive else { return nil }
        let numbers = selectedClips
            .filter { $0.content.utf16.count <= Self.maxStatsLength }
            .flatMap { parser.parse($0.content) }
        return NumberStats(values: numbers.map(\.value), inputFractionDigits: numbers.map(\.fractionDigits).max() ?? 0)
    }

    /// Stats for the selected clip, if it contains 2+ numbers.
    var selectedStats: NumberStats? {
        guard let clip = selectedClip else { return nil }
        return stats(for: clip)
    }

    /// Stats for any clip with 2+ numbers (rows show the sum inline). Cached per clip.
    func stats(for clip: Clip) -> NumberStats? {
        guard let id = clip.id else { return nil }
        if let cached = statsCache[id] { return cached }
        // Very large clips: skip, to keep the panel instant.
        let stats = clip.content.utf16.count <= Self.maxStatsLength ? NumberStats(text: clip.content) : nil
        let result = (stats?.count ?? 0) >= 2 ? stats : nil
        statsCache[id] = result   // clip content never changes, so caching by id is safe
        return result
    }

    // Wired up by PanelController.
    @ObservationIgnored var closePanel: () -> Void = {}
    @ObservationIgnored var pasteTarget: () -> NSRunningApplication? = { nil }
    /// Wired up by AppEnvironment: adds clips to the running series (starting one if needed).
    @ObservationIgnored var addToSeries: ([Clip]) -> Void = { _ in }
    @ObservationIgnored private let parser = NumberParser()

    @ObservationIgnored let appInfo = AppInfoCache()
    @ObservationIgnored private let store: ClipStore
    @ObservationIgnored private let monitor: ClipboardMonitor
    @ObservationIgnored private let pasteService = PasteService()
    @ObservationIgnored private var hasPromptedForAccessibility = false
    @ObservationIgnored private var statsCache: [Int64: NumberStats?] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    static let maxStatsLength = 200_000

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
            if resetSelection { multi.clear() } else { multi.prune(to: ids) }
        } catch {
            errorMessage = "Couldn't load history: \(error.localizedDescription)"
        }
    }

    // MARK: - Selection

    func moveSelection(by delta: Int) {
        multi.clear()   // arrow keys collapse a multi-selection, like in Finder
        selection.move(by: delta, in: ids)
    }

    func select(_ clip: Clip) {
        multi.clear()
        if let id = clip.id { selection.select(id, in: ids) }
    }

    /// Mouse click on a row: plain click selects; ⌘-click toggles it in a multi-selection;
    /// ⇧-click selects the range from the focused row.
    func click(_ clip: Clip) {
        guard let id = clip.id else { return }
        // SwiftUI tap gestures don't report modifier keys; NSEvent knows which are held now.
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            multi.toggle(id, focused: selection.selectedID)
            if multi.contains(id) { selection.select(id, in: ids) }
        } else if modifiers.contains(.shift) {
            multi.extend(to: id, from: selection.selectedID, in: ids)
        } else {
            select(clip)
        }
    }

    /// "Add to series" chip: every selected clip, included even if it mixes text.
    func addSelectionToSeries() {
        let chosen = selectedClips
        guard !chosen.isEmpty else { return }
        addToSeries(chosen)
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

    /// Click on a stat tile: copy its plain value (it also lands in history). The panel
    /// stays open with the original clip selected.
    func copyStat(_ item: NumberStats.Item) {
        do {
            try monitor.copyToClipboard(newText: item.copyText)
            reload()
            showToast("Copied \(item.label.lowercased()): \(item.display)")
        } catch {
            errorMessage = "Couldn't copy: \(error.localizedDescription)"
        }
    }

    /// Transform button: run it on the selected clip, copy the result, add it to history
    /// and select it, so ↩ pastes it immediately.
    func applyTransform(_ transform: any Transform) {
        let chosen = selectedClips
        guard !chosen.isEmpty else { return }
        // Several clips: run the transform over all of them, one per line.
        let input = chosen
            .map { $0.content.trimmingCharacters(in: .newlines) }
            .joined(separator: "\n")
        do {
            let output = try transform.apply(input)
            let result = try monitor.copyToClipboard(newText: output)
            multi.clear()
            reload()
            if let id = result.clip.id { selection.select(id, in: ids) }
            showToast("\(transform.title) copied · ↩ to paste")
        } catch let error as TransformError {
            showToast(error.message)
        } catch {
            errorMessage = "\(transform.title) failed: \(error.localizedDescription)"
        }
    }

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        // A Task with sleep is the modern way to "do this later" on the main actor.
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
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
