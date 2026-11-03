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
    /// A number (sum, average…): ⏎ pastes it, ⌘⏎ copies it, shown prominently.
    var isValue = false
    /// What ⌘⏎ does instead of `run` (nil = same as ⏎).
    var copy: (() -> Void)? = nil
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
            .filter { !TransformRegistry.pasteShapes.contains($0.id) || mode.pinnedTransforms.contains($0.id) }
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

    /// Every number in the selection (in order), with units. Empty when numbers are hidden.
    var selectionNumbers: [ParsedNumber] {
        guard mode.showsNumbers else { return [] }
        if multi.isActive { return selectedClips.flatMap { numbers(in: $0) } }
        if let column = selectedColumn, let table = selectedTable, table.columns.indices.contains(column),
           let clip = selectedClip, let data = DataTable.parse(clip.content, format: format), column < data.columnCount {
            return data.numbers(in: column, format: format)
        }
        return selectedClip.map { numbers(in: $0) } ?? []
    }

    /// Mixed units ("$1,204.50 + €380"), and the total in the base currency when rates
    /// allow. Nil when everything shares one unit (or has none) and needs no conversion.
    var unitSummary: (sums: String, converted: String?)? {
        let numbers = selectionNumbers
        guard numbers.count >= 2 else { return nil }
        let breakdown = UnitBreakdown(numbers)
        let (base, rates) = currencyRates()
        let converted = breakdown.converted(to: base, rates: rates).map {
            UnitBreakdown.display($0, unit: base, fractionDigits: 2, format: format)
        }
        if breakdown.isMixed { return (breakdown.summary(format: format), converted) }
        // One foreign currency with a rate: offer the total in the base currency too.
        if let unit = breakdown.units.first, unit != base, let converted, breakdown.groups.count == 1 {
            return (breakdown.summary(format: format), converted)
        }
        return nil
    }

    /// Outliers and gaps in the selection's numbers.
    var insights: NumberInsights? {
        let values = selectionNumbers.map(\.value)
        guard values.count >= NumberInsights.minimumForGaps else { return nil }
        let insights = NumberInsights(values: values)
        return insights.isEmpty ? nil : insights
    }

    /// The selection's numbers for the sparkline (at most 2,000), or empty below 3.
    var sparklineValues: [Double] {
        let numbers = selectionNumbers
        guard numbers.count >= 3 else { return [] }
        return numbers.prefix(2_000).map { NSDecimalNumber(decimal: $0.value).doubleValue }
    }

    func formatNumber(_ value: Decimal) -> String {
        NumberFormatting.grouped(value, maxFractionDigits: 6, format: format)
    }

    private func numbers(in clip: Clip) -> [ParsedNumber] {
        guard let id = clip.id, clip.content.utf16.count <= Self.maxStatsLength else { return [] }
        let key = "\(id)|\(format.rawValue)"
        if let cached = numbersCache[key] { return cached }
        let found = NumberParser(format: format).parse(clip.content)
        if numbersCache.count > 16 { numbersCache.removeAll() }
        numbersCache[key] = found
        return found
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
        // Numbers first, so ">" alone shows the answers at the top.
        let all = allCommands
        let ordered = all.filter(\.isValue) + all.filter { !$0.isValue }
        return FuzzyMatch.rank(ordered, query: String(query.dropFirst()), key: \.searchText)
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

    /// Opens JSON text as a graph (text, title); set by AppEnvironment.
    @ObservationIgnored var onVisualizeJSON: ((String, String) -> Void)?
    /// Opens CSV/TSV text in the table viewer (text, title).
    @ObservationIgnored var onOpenTable: ((String, String) -> Void)?
    /// Quick Look on a clip (text, kind).
    @ObservationIgnored var onQuickLook: ((String, ClipKind) -> Void)?
    /// The user's base currency and manual exchange rates (Settings → General).
    @ObservationIgnored var currencyRates: () -> (base: String, rates: [String: Decimal]) = { ("USD", [:]) }
    /// Saved snippets (Settings → Snippets).
    @ObservationIgnored var snippets: () -> [Snippet] = { [] }

    /// A snippet waiting for its fields to be filled in (shown as a small form).
    private(set) var pendingSnippet: PendingSnippet?
    var snippetValues: [String: String] = [:]

    struct PendingSnippet: Equatable {
        let snippet: Snippet
        let clipboard: String
    }

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
    @ObservationIgnored private var numbersCache: [String: [ParsedNumber]] = [:]
    @ObservationIgnored private var tableViewCache: [Int64: Bool] = [:]
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
        numbersCache = [:]
        tableViewCache = [:]
        commandTargets = []
        pendingSnippet = nil
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
        if row == nil, pendingSnippet != nil {
            submitSnippet(copyOnly: activation == .copyOnly)
            return
        }
        if row == nil, isCommandMode {
            runCommand(at: commandIndex, copyOnly: activation == .copyOnly)
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

    /// ⏎ runs the command (for a number: pastes it); ⌘⏎ copies a number instead.
    func runCommand(at index: Int, copyOnly: Bool = false) {
        let list = commands
        guard list.indices.contains(index) else { return }
        let command = list[index]
        query = ""            // leave the command bar first…
        if copyOnly, let copy = command.copy { copy() } else { command.run() }   // …so its toast sticks
        onCommandRun?()
    }

    /// True when the focused clip is JSON (shows the Visualize button, enables ⌘J).
    var canVisualizeJSON: Bool { !multi.isActive && selectedSummary?.kind == .json }

    /// Visualize button / ⌘J: open the focused JSON clip as a graph.
    func visualizeSelection() {
        guard canVisualizeJSON, let clip = selectedClip else { return }
        visualize(clip)
    }

    private func visualize(_ clip: Clip) {
        closePanel()
        onVisualizeJSON?(clip.content, ClipPreview.title(clip.content, maxLength: 60))
    }

    /// Command bar ⏎ on a number: close the panel and paste it into the app you were in.
    /// The value is not added to history (or counted in a running series).
    func pasteValue(_ item: NumberStats.Item) {
        pasteText(item.copyText)
    }

    /// Closes the panel and pastes `text` into the app you were in, without adding it to
    /// history (or counting it in a running series).
    func pasteText(_ text: String) {
        monitor.writeWithoutRecording(text)
        let target = pasteTarget()
        closePanel()
        if pasteService.paste(into: target) == .needsAccessibility, !hasPromptedForAccessibility {
            // It's on the clipboard; ⌘V works. Explain the permission once per launch.
            hasPromptedForAccessibility = true
            AccessibilityPermission.requestWithSystemPrompt()
        }
    }

    /// Copies a result into history and selects it, so ↩ pastes it.
    func copyResult(_ text: String, message: String) {
        do {
            let result = try monitor.copyToClipboard(newText: text)
            multi.clear()
            reload()
            if let id = result.clip.id { selection.select(id, in: ids) }
            showToast(message)
        } catch {
            errorMessage = "Couldn't copy: \(error.localizedDescription)"
        }
    }

    /// Joined text of clips (several clips one per line), for commands.
    private func joinedText(of clips: [Clip]) -> String {
        clips.map { $0.content.trimmingCharacters(in: .newlines) }.joined(separator: "\n")
    }

    // MARK: Snippets

    /// Runs a snippet on the given clips: pastes right away, or asks for its fields first.
    func useSnippet(_ snippet: Snippet, on clips: [Clip]) {
        let clipboard = joinedText(of: clips)
        if snippet.fields.isEmpty {
            finishSnippet(snippet, clipboard: clipboard, values: [:])
        } else {
            snippetValues = Dictionary(uniqueKeysWithValues: snippet.fields.map { ($0, "") })
            pendingSnippet = PendingSnippet(snippet: snippet, clipboard: clipboard)
        }
    }

    /// ↩ in the snippet form.
    func submitSnippet(copyOnly: Bool = false) {
        guard let pending = pendingSnippet else { return }
        pendingSnippet = nil
        finishSnippet(pending.snippet, clipboard: pending.clipboard, values: snippetValues, copyOnly: copyOnly)
    }

    func cancelSnippet() {
        pendingSnippet = nil
    }

    private func finishSnippet(_ snippet: Snippet, clipboard: String, values: [String: String], copyOnly: Bool = false) {
        do {
            let text = try snippet.render(clipboard: clipboard, values: values, format: format)
            if copyOnly { copyResult(text, message: "\(snippet.name) copied · ↩ to paste") } else { pasteText(text) }
        } catch let error as Snippet.RenderError {
            showToast(error.message)
        } catch {
            showToast("\(snippet.name): \(error.localizedDescription)")
        }
    }

    // MARK: Table viewer, Quick Look, drag

    private func unitSummaryFor(_ clips: [Clip]) -> (sums: String, converted: String?)? {
        let numbers = clips.flatMap { numbers(in: $0) }
        guard numbers.count >= 2 else { return nil }
        let breakdown = UnitBreakdown(numbers)
        let (base, rates) = currencyRates()
        let converted = breakdown.converted(to: base, rates: rates).map { UnitBreakdown.display($0, unit: base, format: format) }
        guard breakdown.isMixed || (converted != nil && breakdown.units != [base]) else { return nil }
        return (breakdown.summary(format: format), converted)
    }

    private func insightsFor(_ clips: [Clip]) -> NumberInsights? {
        let values = clips.flatMap { numbers(in: $0) }.map(\.value)
        guard values.count >= NumberInsights.minimumForGaps else { return nil }
        let insights = NumberInsights(values: values)
        return insights.isEmpty ? nil : insights
    }

    /// True when the focused clip is a table (TSV/CSV…) that the table viewer can open.
    var canOpenTable: Bool {
        guard !multi.isActive, let row = selectedSummary, row.lineCount >= 2 else { return false }
        if row.kind == .table { return true }
        if let cached = tableViewCache[row.id] { return cached }
        let ok = selectedClip.map { $0.content.utf16.count <= 2_000_000 && DataTable.parse($0.content, format: format) != nil } ?? false
        if tableViewCache.count > 32 { tableViewCache.removeAll() }
        tableViewCache[row.id] = ok
        return ok
    }

    /// Table button / ⌘T.
    func openTableSelection() {
        guard canOpenTable, let clip = selectedClip else { return }
        closePanel()
        onOpenTable?(clip.content, ClipPreview.title(clip.content, maxLength: 60))
    }

    /// Space (with an empty search) / ⌘Y: preview the focused clip with Quick Look.
    func quickLookSelection() {
        guard let clip = selectedClip else { return }
        onQuickLook?(clip.content, clip.kind)
    }

    /// Dragging a row out of the panel drops its text into the other app.
    func dragProvider(for row: ClipSummary) -> NSItemProvider {
        let text = fullClip(row.id)?.content ?? row.preview
        return NSItemProvider(object: text as NSString)
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
        let typed = String(query.dropFirst())
        let targetText = joinedText(of: targets)

        // Quick math: "> × 1.2", "> + 15%", "> round 2".
        if let operation = NumberMath.parse(typed, format: format), !targets.isEmpty,
           let result = try? NumberMath.apply(operation, to: targetText, format: format) {
            let preview = ClipPreview.title(result, maxLength: 40)
            list.append(PanelCommand(
                id: "math", title: operation.title(format: format), detail: preview, icon: "function",
                keywords: typed, isValue: true,
                copy: { [weak self] in self?.copyResult(result, message: "Result copied · ↩ to paste") }
            ) { [weak self] in self?.pasteText(result) })
        }

        // Transforms, in the mode's order.
        for transform in transforms {
            list.append(PanelCommand(
                id: "transform.\(transform.id)", title: transform.title,
                detail: transform.id.hasPrefix("recipe.") ? "Recipe" : "Transform",
                icon: Theme.icon(forTransformID: transform.id)
            ) { [weak self] in self?.applyTransform(transform, to: targets) })
        }

        // Stats of the targets: as soon as there's one number (the sum of "30" is 30).
        // Shown in every mode: typing >sum is an explicit ask.
        if let stats = combinedStats(of: targets) {
            let keywords = ["Sum": "total add Σ", "Average": "mean avg", "Count": "how many number",
                            "Median": "middle", "Min": "minimum lowest smallest", "Max": "maximum highest largest"]
            // With a single number only "sum" means anything (count 1, min = max = it).
            let items = stats.items(format: format, primary: mode.primaryStat)
                .filter { stats.count >= 2 || $0.label == "Sum" }
            for item in items {
                list.append(PanelCommand(
                    id: "stat.\(item.label)", title: item.label, detail: item.display,
                    icon: item.label == "Sum" ? "sum" : "number",
                    keywords: "\(keywords[item.label] ?? "") paste copy", isValue: true,
                    copy: { [weak self] in self?.copyStat(item) }
                ) { [weak self] in self?.pasteValue(item) })
            }
        }

        // Columns of a copied spreadsheet range.
        if targets.count == 1, let target = targets.first,
           target.content.contains("\t"), target.content.utf16.count <= Self.maxStatsLength,
           let table = TableParser.parse(target.content, format: format) {
            for column in table.numericColumns {
                guard let sum = column.stats?.items(format: format).first(where: { $0.label == "Sum" }) else { continue }
                list.append(PanelCommand(
                    id: "column.\(column.index)", title: "Sum of \(column.name)", detail: sum.display, icon: "tablecells",
                    keywords: "total column paste copy", isValue: true,
                    copy: { [weak self] in self?.copyStat(sum) }
                ) { [weak self] in self?.pasteValue(sum) })
            }
        }

        // Spreadsheet shapes: paste down a column, across a row, or transposed.
        if !targets.isEmpty {
            let shapes: [(any Transform, String, String)] = [
                (AsColumnTransform(format: format), "Paste as column", "arrow.down.to.line"),
                (AsRowTransform(format: format), "Paste as row", "arrow.right.to.line"),
                (TransposeTransform(format: format), "Paste transposed", "arrow.left.arrow.right"),
            ]
            for (transform, title, icon) in shapes {
                guard let output = try? transform.apply(targetText) else { continue }
                list.append(PanelCommand(
                    id: "shape.\(transform.id)", title: title, detail: "Spreadsheet", icon: icon,
                    keywords: "excel sheets numbers spreadsheet cells \(transform.title)",
                    copy: { [weak self] in self?.copyResult(output, message: "\(title) copied · ↩ to paste") }
                ) { [weak self] in self?.pasteText(output) })
            }
        }

        // Units: sums per unit, and the converted total.
        if let units = unitSummaryFor(targets) {
            list.append(PanelCommand(id: "units.sums", title: "Copy sums by unit", detail: units.sums, icon: "dollarsign.circle",
                                     keywords: "currency units mixed sum total") { [weak self] in
                self?.copyResult(units.sums, message: "Copied sums by unit")
            })
            if let converted = units.converted {
                let base = currencyRates().base
                list.append(PanelCommand(id: "units.converted", title: "Total in \(base)", detail: converted, icon: "dollarsign.circle",
                                         keywords: "currency convert exchange rate sum total", isValue: true,
                                         copy: { [weak self] in self?.copyResult(converted, message: "Copied total in \(base)") }
                ) { [weak self] in self?.pasteText(converted) })
            }
        }

        // Outliers and gaps.
        if let insights = insightsFor(targets) {
            if !insights.outliers.isEmpty {
                let text = insights.outliers.map(formatNumber).joined(separator: "\n")
                list.append(PanelCommand(id: "insights.outliers", title: "Copy outliers",
                                         detail: insights.outliers.prefix(3).map(formatNumber).joined(separator: ", "), icon: "exclamationmark.triangle",
                                         keywords: "outlier unusual anomaly") { [weak self] in
                    self?.copyResult(text, message: "Copied \(insights.outliers.count) outlier\(insights.outliers.count == 1 ? "" : "s")")
                })
            }
            if !insights.gaps.isEmpty {
                let text = insights.gaps.map(formatNumber).joined(separator: "\n")
                list.append(PanelCommand(id: "insights.gaps", title: "Copy missing numbers",
                                         detail: insights.gaps.prefix(4).map(formatNumber).joined(separator: ", "), icon: "number.square",
                                         keywords: "gaps missing sequence skipped") { [weak self] in
                    self?.copyResult(text, message: "Copied \(insights.gaps.count) missing number\(insights.gaps.count == 1 ? "" : "s")")
                })
            }
        }

        // Snippets.
        for snippet in snippets() {
            list.append(PanelCommand(id: "snippet.\(snippet.id)", title: "Snippet: \(snippet.name)",
                                     detail: snippet.fields.isEmpty ? "Snippet" : "Snippet · \(snippet.fields.count) field\(snippet.fields.count == 1 ? "" : "s")",
                                     icon: "text.badge.plus", keywords: "snippet template \(snippet.name)") { [weak self] in
                self?.useSnippet(snippet, on: targets)
            })
        }

        // Table viewer.
        if targets.count == 1, let target = targets.first, target.content.utf16.count <= 2_000_000,
           target.kind == .table || DataTable.parse(target.content, format: format) != nil {
            list.append(PanelCommand(id: "table.view", title: "Open as table", detail: "Table · ⌘T", icon: "tablecells",
                                     keywords: "csv tsv grid sort filter spreadsheet view") { [weak self] in
                guard let self else { return }
                self.closePanel()
                self.onOpenTable?(target.content, ClipPreview.title(target.content, maxLength: 60))
            })
        }

        // JSON graph.
        if targets.count == 1, let target = targets.first, target.kind == .json {
            list.append(PanelCommand(id: "json.graph", title: "Visualize JSON", detail: "Graph · ⌘J",
                                     icon: "point.3.connected.trianglepath.dotted",
                                     keywords: "graph tree view diagram crack open") { [weak self] in
                self?.visualize(target)
            })
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
