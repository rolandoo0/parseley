import AppKit
import Observation
import ParseleyCapture
import ParseleyCore
import ParseleyPaste

/// One entry in the `>` command bar.
struct PanelCommand: Identifiable {
    let id: String
    let title: String
    /// Extra info shown on the right ("1,492.5", "Transform", "Mode").
    let detail: String
    let icon: String
    /// Extra words it should be found by ("sum total" for "Copy series total").
    var keywords: String = ""
    let run: () -> Void

    /// What the command bar matches against: the title first, then the keywords.
    var searchText: String { keywords.isEmpty ? title : "\(title) \(keywords)" }
}

/// State and actions behind the history panel. The view (HistoryView) only renders this
/// and forwards user input. Keyboard handling lives in PanelController.
@MainActor
@Observable
final class HistoryPanelModel {
    enum ActivationMode { case paste, copyOnly }

    /// Search text. Starting it with ">" switches to the command bar.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            if isCommandMode {
                // Remember what the commands act on before the list changes underneath.
                if !oldValue.hasPrefix(">") { commandTargets = selectedClips }
                commandIndex = 0
            } else {
                reload(resetSelection: true)
            }
        }
    }
    /// Lightweight rows (no full text): what the list shows.
    private(set) var clips: [ClipSummary] = []
    private(set) var selection = ListSelection() {
        // A different clip means a different table: back to "all columns".
        didSet { if selection.selectedID != oldValue.selectedID { selectedColumn = nil } }
    }
    /// For a table clip: the column the stats are about (nil = every number).
    private(set) var selectedColumn: Int?
    /// ⌘-click / ⇧-click selection of several clips (combined stats, joint transforms).
    private(set) var multi = MultiSelection()
    private(set) var isAccessibilityTrusted = AccessibilityPermission.isTrusted
    /// Incremented each time the panel opens; HistoryView watches it to focus the search field.
    private(set) var focusRequest = 0
    private(set) var errorMessage: String?
    /// Brief confirmation shown in the footer ("Copied Sum: 1,492.5"). Clears itself.
    private(set) var toast: String?
    /// Highlighted row in the command bar.
    private(set) var commandIndex = 0

    // MARK: - Mode

    let modes: ModeController
    /// Set by AppEnvironment (created after this model).
    @ObservationIgnored weak var series: SeriesController?
    @ObservationIgnored weak var recipes: RecipeController?
    @ObservationIgnored weak var pasteQueue: PasteQueueController?

    var mode: Mode { modes.current }
    private var format: NumberFormat { mode.numberFormat }

    /// Transform buttons in the current mode's order (reading numbers in its format),
    /// followed by the user's recipes.
    var transforms: [any Transform] {
        TransformRegistry.ordered(pinned: mode.pinnedTransforms, format: format)
            + (recipes?.transforms(format: format) ?? [])
    }

    // MARK: - Selection

    var selectedSummary: ClipSummary? {
        guard let id = selection.selectedID else { return nil }
        return clips.first { $0.id == id }
    }

    /// The focused clip with its full text, loaded on demand (and cached briefly).
    var selectedClip: Clip? {
        selection.selectedID.flatMap(fullClip)
    }

    /// The clips actions apply to, with full text: all multi-selected clips (in list
    /// order), or just the focused one.
    var selectedClips: [Clip] {
        if multi.isActive { return clips.filter { multi.contains($0.id) }.compactMap { fullClip($0.id) } }
        return selectedClip.map { [$0] } ?? []
    }

    var multiSelectedCount: Int { multi.isActive ? multi.ids.count : 0 }

    // MARK: - Stats

    /// Stats for whatever is selected (combined for a multi-selection). Nil when the
    /// current mode hides numbers or there are fewer than two.
    var selectionStats: NumberStats? {
        guard mode.showsNumbers else { return nil }
        if multi.isActive { return combinedStats(of: selectedClips) }
        if let column = selectedColumn, let table = selectedTable, table.columns.indices.contains(column) {
            return table.columns[column].stats
        }
        return selectedClip.flatMap { stats(for: $0) }
    }

    /// The stat tiles for the selection, in the mode's format with its main stat first.
    var statItems: [NumberStats.Item] {
        selectionStats?.items(format: format, primary: mode.primaryStat) ?? []
    }

    /// "Σ 1,492.5 · 3 values" for a list row, or nil. Uses the sum stored at capture
    /// time, so rows never re-read or re-parse clip text.
    func rowSummary(for row: ClipSummary) -> String? {
        guard mode.showsNumbers, row.kind != .seriesTotal, row.numberCount >= 2, let sum = row.numberSum else { return nil }
        return "Σ \(NumberFormatting.grouped(sum, maxFractionDigits: 6, format: format))  ·  \(row.numberCount) values"
    }

    /// Stats for one clip with 2+ numbers. Cached for the most recent clips only.
    func stats(for clip: Clip) -> NumberStats? {
        guard let id = clip.id else { return nil }
        let key = "\(id)|\(format.rawValue)"
        if let cached = statsCache[key] { return cached }
        // Very large clips: skip, to keep the panel instant.
        let stats = clip.content.utf16.count <= Self.maxStatsLength
            ? NumberStats(text: clip.content, parser: NumberParser(format: format)) : nil
        let result = (stats?.count ?? 0) >= 2 ? stats : nil
        if statsCache.count > 16 { statsCache.removeAll() }   // small and bounded
        statsCache[key] = result   // clip content never changes, so caching is safe
        return result
    }

    private func combinedStats(of clips: [Clip]) -> NumberStats? {
        let parser = NumberParser(format: format)
        let numbers = clips
            .filter { $0.content.utf16.count <= Self.maxStatsLength }
            .flatMap { parser.parse($0.content) }
        return NumberStats(values: numbers.map(\.value), inputFractionDigits: numbers.map(\.fractionDigits).max() ?? 0)
    }

    // MARK: - Tables

    /// The focused clip as a spreadsheet range, if it is one with numeric columns.
    var selectedTable: ParsedTable? {
        guard mode.showsNumbers, !multi.isActive, let row = selectedSummary, row.lineCount >= 2,
              let clip = selectedClip else { return nil }
        let key = "\(row.id)|\(format.rawValue)"
        if let cached = tableCache[key] { return cached }
        let table = clip.content.contains("\t") && clip.content.utf16.count <= Self.maxStatsLength
            ? TableParser.parse(clip.content, format: format) : nil
        let result = (table?.numericColumns.isEmpty ?? true) ? nil : table
        if tableCache.count > 8 { tableCache.removeAll() }
        tableCache[key] = result
        return result
    }

    /// Column chip: nil = all numbers in the clip.
    func selectColumn(_ index: Int?) {
        selectedColumn = index
    }

    // MARK: - Command bar

    var isCommandMode: Bool { query.hasPrefix(">") }

    /// Commands matching what's typed after ">", best first.
    var commands: [PanelCommand] {
        FuzzyMatch.rank(allCommands, query: String(query.dropFirst()), key: \.searchText)
    }

    /// What the commands will act on, for the header ("3 clips", "“$1,204.50…”").
    var commandTargetDescription: String {
        switch commandTargets.count {
        case 0: return "Nothing selected"
        case 1: return "“\(ClipPreview.title(commandTargets[0].content, maxLength: 50))”"
        default: return "\(commandTargets.count) clips"
        }
    }

    // MARK: - Dependencies

    /// Welcome-tour hooks (set by AppEnvironment).
    @ObservationIgnored var onStatCopied: (() -> Void)?
    @ObservationIgnored var onCommandRun: (() -> Void)?

    // Wired up by PanelController.
    @ObservationIgnored var closePanel: () -> Void = {}
    @ObservationIgnored var pasteTarget: () -> NSRunningApplication? = { nil }

    @ObservationIgnored let appInfo: AppInfoCache
    @ObservationIgnored private let store: ClipStore
    @ObservationIgnored private let monitor: ClipboardMonitor
    @ObservationIgnored private let pasteService = PasteService()
    @ObservationIgnored private var hasPromptedForAccessibility = false
    @ObservationIgnored private var statsCache: [String: NumberStats?] = [:]
    @ObservationIgnored private var tableCache: [String: ParsedTable?] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var commandTargets: [Clip] = []
    /// Full clips recently needed (selected, multi-selected). Bounded; cleared on hide.
    @ObservationIgnored private var fullClips: [Int64: Clip] = [:]

    static let maxStatsLength = 200_000

    /// How many clips the panel lists. Search always runs over the whole history.
    static let fetchLimit = 300

    init(store: ClipStore, monitor: ClipboardMonitor, modes: ModeController, appInfo: AppInfoCache) {
        self.store = store
        self.monitor = monitor
        self.modes = modes
        self.appInfo = appInfo
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

    /// Frees everything the panel holds while hidden: rows, full clips, caches.
    func releaseMemory() {
        clips = []
        fullClips = [:]
        statsCache = [:]
        tableCache = [:]
        commandTargets = []
        multi.clear()
    }

    func reload(resetSelection: Bool = false) {
        fullClips = [:]   // pins/notes may have changed
        do {
            clips = try store.summaries(matching: isCommandMode ? "" : query, limit: Self.fetchLimit)
            selection.update(ids: ids, resetToFirst: resetSelection)
            if resetSelection { multi.clear() } else { multi.prune(to: ids) }
        } catch {
            errorMessage = "Couldn't load history: \(error.localizedDescription)"
        }
    }

    // MARK: - Selection

    /// ↑/↓: moves through clips, or through commands in the command bar.
    func moveSelection(by delta: Int) {
        if isCommandMode {
            let count = commands.count
            guard count > 0 else { return }
            commandIndex = max(0, min(count - 1, commandIndex + delta))
            return
        }
        multi.clear()   // arrow keys collapse a multi-selection, like in Finder
        selection.move(by: delta, in: ids)
    }

    func select(_ row: ClipSummary) {
        multi.clear()
        selection.select(row.id, in: ids)
    }

    /// Mouse click on a row: plain click selects; ⌘-click toggles it in a multi-selection;
    /// ⇧-click selects the range from the focused row.
    func click(_ row: ClipSummary) {
        let id = row.id
        // SwiftUI tap gestures don't report modifier keys; NSEvent knows which are held now.
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            multi.toggle(id, focused: selection.selectedID)
            if multi.contains(id) { selection.select(id, in: ids) }
        } else if modifiers.contains(.shift) {
            multi.extend(to: id, from: selection.selectedID, in: ids)
        } else {
            select(row)
        }
    }

    // MARK: - Actions

    /// Enter / double-click: put the clip on the clipboard, close, and paste into the app
    /// that was frontmost before the panel opened. In the command bar: run the command.
    func activate(_ row: ClipSummary? = nil, mode activation: ActivationMode = .paste) {
        if row == nil, isCommandMode {
            runCommand(at: commandIndex)
            return
        }
        guard let id = row?.id ?? selection.selectedID else { return }
        do {
            try monitor.copyToClipboard(clipID: id)
        } catch {
            errorMessage = "Couldn't copy: \(error.localizedDescription)"
            return
        }
        let target = pasteTarget()
        closePanel()

        guard activation == .paste else { return }
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

    func runCommand(at index: Int) {
        let list = commands
        guard list.indices.contains(index) else { return }
        let command = list[index]
        query = ""            // leave the command bar first…
        command.run()         // …so the command's own selection/toast stick
        onCommandRun?()
    }

    /// Click on a stat tile: copy its value (it also lands in history). The panel stays
    /// open with the original clip selected.
    func copyStat(_ item: NumberStats.Item) {
        do {
            try monitor.copyToClipboard(newText: item.copyText)
            reload()
            showToast("Copied \(item.label.lowercased()): \(item.display)")
            onStatCopied?()
        } catch {
            errorMessage = "Couldn't copy: \(error.localizedDescription)"
        }
    }

    /// ⌘1–⌘6: copy the Nth stat tile (in the mode's order; ⌘1 is its main stat).
    func copyStat(at index: Int) {
        let items = statItems
        guard items.indices.contains(index) else {
            return showToast(items.isEmpty ? "No numbers to copy" : "No stat \(index + 1)")
        }
        copyStat(items[index])
    }

    /// Transform button: run it on the selected clip(s), copy the result, add it to
    /// history and select it, so ↩ pastes it immediately.
    func applyTransform(_ transform: any Transform) {
        applyTransform(transform, to: selectedClips)
    }

    private func applyTransform(_ transform: any Transform, to chosen: [Clip]) {
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

    /// "Queue" chip: paste the selected clips one by one with ⌃⌥⌘V. Closes the panel so
    /// you can click into the target field.
    func queueSelection() {
        startQueue(with: selectedClips)
    }

    private func startQueue(with clips: [Clip]) {
        guard !clips.isEmpty, let pasteQueue else { return }
        pasteQueue.start(with: clips)
        closePanel()
    }

    /// "Add to series" chip: every selected clip, included even if it mixes text.
    func addSelectionToSeries() {
        addToSeries(selectedClips)
    }

    private func addToSeries(_ clips: [Clip]) {
        guard !clips.isEmpty, let series else { return }
        series.add(clips, format: format)
        showToast("Added to \(series.active?.name ?? "series")")
    }

    func togglePin(_ row: ClipSummary? = nil) {
        guard let row = row ?? selectedSummary else { return }
        perform { try store.setPinned(id: row.id, !row.isPinned) }
    }

    func delete(_ row: ClipSummary) {
        perform { try store.delete(id: row.id) }
    }

    func deleteSelected() {
        if let row = selectedSummary { delete(row) }
    }

    func enableAutoPaste() {
        // The prompt adds Parseley to the Accessibility list (so the user only has to
        // flip the switch), then we open that pane directly.
        AccessibilityPermission.requestWithSystemPrompt()
        AccessibilityPermission.openSystemSettings()
    }

    // MARK: - Commands

    /// Everything the command bar can do, given the clips it targets.
    private var allCommands: [PanelCommand] {
        let targets = commandTargets
        var list: [PanelCommand] = []

        // Transforms, in the mode's order.
        for transform in transforms {
            list.append(PanelCommand(
                id: "transform.\(transform.id)", title: transform.title,
                detail: transform.id.hasPrefix("recipe.") ? "Recipe" : "Transform",
                icon: Theme.icon(forTransformID: transform.id)
            ) { [weak self] in self?.applyTransform(transform, to: targets) })
        }

        // Stats of the targets: as soon as there's one number (the sum of "30" is 30).
        if mode.showsNumbers, let stats = combinedStats(of: targets) {
            let keywords = ["Sum": "total add", "Average": "mean avg", "Count": "how many number",
                            "Median": "middle", "Min": "minimum lowest smallest", "Max": "maximum highest largest"]
            // With a single number only "sum" means anything (count 1, min = max = it).
            let items = stats.items(format: format, primary: mode.primaryStat)
                .filter { stats.count >= 2 || $0.label == "Sum" }
            for item in items {
                list.append(PanelCommand(
                    id: "stat.\(item.label)", title: "Copy \(item.label.lowercased())", detail: item.display,
                    icon: "number", keywords: keywords[item.label] ?? ""
                ) { [weak self] in self?.copyStat(item) })
            }
        }

        // Columns of a copied spreadsheet range.
        if mode.showsNumbers, targets.count == 1, let target = targets.first,
           target.content.contains("\t"), target.content.utf16.count <= Self.maxStatsLength,
           let table = TableParser.parse(target.content, format: format) {
            for column in table.numericColumns {
                guard let sum = column.stats?.items(format: format).first(where: { $0.label == "Sum" }) else { continue }
                list.append(PanelCommand(
                    id: "column.\(column.index)", title: "Copy sum of \(column.name)", detail: sum.display, icon: "tablecells",
                    keywords: "total column"
                ) { [weak self] in self?.copyStat(sum) })
            }
        }

        // Paste queue.
        if targets.count >= 2 {
            list.append(PanelCommand(id: "queue.start", title: "Paste queue", detail: "\(targets.count) clips · ⌃⌥⌘V",
                                     icon: "list.number") { [weak self] in self?.startQueue(with: targets) })
        }

        // Series.
        if !targets.isEmpty {
            list.append(PanelCommand(id: "series.add", title: "Add to series", detail: "Series", icon: "sum",
                                     keywords: "sum tally running total") {
                [weak self] in self?.addToSeries(targets)
            })
        }
        if let series {
            if series.isActive {
                list.append(PanelCommand(id: "series.copy", title: "Copy series total",
                                         detail: series.sumItem?.display ?? "", icon: "sum", keywords: "sum tally") { series.copySum() })
                list.append(PanelCommand(id: "series.new", title: "New series", detail: "Series", icon: "plus",
                                         keywords: "tally reset start") {
                    series.startNew()
                })
                list.append(PanelCommand(id: "series.stop", title: "Stop series", detail: "Series", icon: "stop.fill",
                                         keywords: "tally end finish save total") {
                    series.stop()
                })
            } else {
                list.append(PanelCommand(id: "series.start", title: "Start series", detail: "Series", icon: "play.fill",
                                         keywords: "tally running total sum") {
                    series.toggle()
                })
            }
        }

        // Pin.
        if targets.count == 1, let clip = targets.first {
            list.append(PanelCommand(id: "clip.pin", title: clip.isPinned ? "Unpin" : "Pin", detail: "Clip", icon: "pin") {
                [weak self] in
                guard let self, let row = self.clips.first(where: { $0.id == clip.id }) else { return }
                self.togglePin(row)
            })
        }

        // Modes.
        let modes = self.modes
        list.append(PanelCommand(id: "mode.auto", title: "Mode: Automatic", detail: modes.isAutomatic ? "Current" : "Mode",
                                 icon: "wand.and.stars") { modes.manualModeID = nil })
        for m in modes.library.modes {
            list.append(PanelCommand(id: "mode.\(m.id)", title: "Mode: \(m.name)",
                                     detail: modes.manualModeID == m.id ? "Locked" : "Mode", icon: m.icon) {
                modes.manualModeID = m.id
            })
        }
        return list
    }

    // MARK: - Helpers

    private var ids: [Int64] { clips.map(\.id) }

    /// Full text for a clip, from a small cache or the database.
    private func fullClip(_ id: Int64) -> Clip? {
        if let cached = fullClips[id] { return cached }
        guard let clip = try? store.clip(id: id) else { return nil }
        if fullClips.count >= 32 { fullClips.removeAll() }
        fullClips[id] = clip
        return clip
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

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
