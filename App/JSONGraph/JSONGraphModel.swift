import Foundation
import Observation
import ParseleyCore

/// State behind the JSON graph window: the parsed document, which cards are collapsed,
/// the selection, search, and the pan/zoom of the canvas.
@MainActor
@Observable
final class JSONGraphModel {
    let title: String
    /// Nil when the text isn't valid JSON (then `parseError` says why).
    let root: JSONValue?
    let parseError: JSONParseError?

    private(set) var graph: JSONGraph?
    private(set) var collapsed: Set<String> = []
    /// Long lists the user chose to see in full (others show their first and last 5).
    private(set) var expandedLists: Set<String> = []
    /// Long lists opened because the search matches something in their hidden middle.
    @ObservationIgnored private var searchExpandedLists: Set<String> = []
    /// The selected card, by path (paths survive collapsing/expanding; ids don't).
    private(set) var selectedPath: String?
    var query = "" {
        didSet { if query != oldValue { updateMatches(focusFirst: true) } }
    }
    private(set) var matches: [Int] = []
    private(set) var matchIndex = 0
    private(set) var toast: String?

    // Canvas transform: screen = content * zoom + offset.
    var zoom: Double = 1
    var offset = CGSize.zero
    /// Size of the canvas area, reported by the view (needed to fit and center).
    var viewSize = CGSize.zero {
        didSet { if oldValue == .zero, viewSize != .zero { fit() } }
    }

    /// Where the canvas sits in the window (top edge, right edge), for scroll events.
    @ObservationIgnored var canvasTop = 0.0
    @ObservationIgnored var canvasMaxX = Double.infinity
    @ObservationIgnored var copyText: (String) -> Void = { _ in }
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    static let minZoom = 0.15
    static let maxZoom = 2.5
    /// Above this many cards the first view collapses deeper levels, so it opens fast
    /// and readable; everything can still be expanded.
    static let autoCollapseThreshold = 300

    init(text: String, title: String) {
        self.title = title
        do {
            let value = try JSONValue.parse(text)
            root = value
            parseError = nil
            let full = JSONGraph(value)
            if full.nodes.count > Self.autoCollapseThreshold {
                collapsed = Set(full.nodes.filter { $0.depth == 2 && $0.childCount > 0 }.map(\.path))
            }
            rebuild()
        } catch let error as JSONParseError {
            root = nil
            parseError = error
        } catch {
            root = nil
            parseError = JSONParseError(message: "\(error)", line: 1, column: 1)
        }
    }

    var nodeCount: Int { graph?.nodes.count ?? 0 }

    var selectedNode: JSONGraph.Node? {
        guard let selectedPath else { return nil }
        return graph?.nodes.first { $0.path == selectedPath }
    }

    /// Full JSON of the selected card (pretty-printed), for the inspector and copying.
    var selectedJSON: String? {
        guard let root, let path = selectedPath, let value = JSONGraph.value(at: path, in: root) else { return nil }
        return value.serialized(pretty: true)
    }

    // MARK: - Actions

    func select(_ id: Int?) {
        selectedPath = id.flatMap { id in graph?.nodes.first { $0.id == id }?.path }
    }

    func toggleCollapse(_ id: Int) {
        guard let node = graph?.nodes.first(where: { $0.id == id }), node.childCount > 0 else { return }
        if collapsed.contains(node.path) {
            // Expanding always starts from the default view: long lists show their first 5.
            collapsed.remove(node.path)
            resetLists(under: node.path)
        } else {
            collapsed.insert(node.path)
        }
        rebuild()
    }

    /// Clicking a "… N more" card shows the whole list.
    func showAll(_ listPath: String) {
        expandedLists.insert(listPath)
        rebuild()
    }

    /// Back to first and last 5 for a long list.
    func shorten(_ listPath: String) {
        expandedLists.remove(listPath)
        searchExpandedLists.remove(listPath)
        rebuild()
    }

    func isShowingAll(_ listPath: String) -> Bool {
        expandedLists.contains(listPath) || searchExpandedLists.contains(listPath)
    }

    /// A click on the canvas: "… N more" shows the list, the ± handle collapses, anything
    /// else selects (or clears the selection on empty space).
    func tap(at point: CGPoint) {
        guard let hit = hit(at: point) else { return select(nil) }
        if hit.onToggle { return toggleCollapse(hit.id) }
        if let node = graph?.nodes.first(where: { $0.id == hit.id }), let list = node.expands {
            return showAll(list)
        }
        select(hit.id)
    }

    func expandAll() {
        collapsed = []
        expandedLists = []
        rebuild()
        fit()
    }

    /// Collapses everything below the top level.
    func collapseAll() {
        guard let root else { return }
        let full = JSONGraph(root)
        collapsed = Set(full.nodes.filter { $0.depth == 1 && $0.childCount > 0 }.map(\.path))
        if full.nodes.first?.kind == .array { collapsed.insert("$") }
        expandedLists = []   // the next expand shows the default view (first 5)
        rebuild()
        fit()
    }

    /// Back to the default for this card and everything inside it: long lists show their
    /// first 5 again.
    private func resetLists(under path: String) {
        expandedLists = expandedLists.filter { list in
            !(list == path || list.hasPrefix(path + ".") || list.hasPrefix(path + "["))
        }
    }

    func nextMatch(_ step: Int = 1) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + step + matches.count) % matches.count
        focus(on: matches[matchIndex])
    }

    func copyPath() {
        guard let path = selectedPath else { return }
        copyText(path)
        show("Copied path \(path)")
    }

    func copyJSON() {
        guard let json = selectedJSON else { return }
        copyText(json)
        show("Copied JSON (\(json.count) characters)")
    }

    // MARK: - Zoom & pan

    func fit() {
        guard let size = graph?.size, size.width > 0, viewSize.width > 0 else { return }
        let margin = 40.0
        let viewWidth = Double(viewSize.width), viewHeight = Double(viewSize.height)
        let scale = min((viewWidth - margin * 2) / size.width, (viewHeight - margin * 2) / size.height)
        zoom = min(1, max(Self.minZoom, scale))
        offset = CGSize(width: (viewWidth - size.width * zoom) / 2,
                        height: max(margin, (viewHeight - size.height * zoom) / 2))
    }

    /// Zooms keeping the content point under `anchor` (a view point) in place.
    func zoom(by factor: Double, anchor: CGPoint? = nil) {
        let anchor = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newZoom = min(Self.maxZoom, max(Self.minZoom, zoom * factor))
        let ax = Double(anchor.x), ay = Double(anchor.y)
        let contentX = (ax - Double(offset.width)) / zoom
        let contentY = (ay - Double(offset.height)) / zoom
        zoom = newZoom
        offset = CGSize(width: ax - contentX * newZoom, height: ay - contentY * newZoom)
    }

    func pan(by delta: CGSize) {
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
    }

    /// The card at a view point, and whether the point is on its collapse toggle.
    func hit(at point: CGPoint) -> (id: Int, onToggle: Bool)? {
        guard let graph else { return nil }
        let x = (Double(point.x) - Double(offset.width)) / zoom
        let y = (Double(point.y) - Double(offset.height)) / zoom
        for node in graph.nodes.reversed() {
            let f = node.frame
            if node.childCount > 0 {
                let dx = x - f.maxX, dy = y - f.midY
                if dx * dx + dy * dy <= Self.toggleRadius * Self.toggleRadius * 2 { return (node.id, true) }
            }
            if x >= f.x, x <= f.maxX, y >= f.y, y <= f.maxY { return (node.id, false) }
        }
        return nil
    }

    static let toggleRadius = 9.0

    // MARK: - Private

    private func rebuild() {
        layoutGraph()
        updateMatches(focusFirst: false)
    }

    private func layoutGraph() {
        guard let root else { return }
        graph = JSONGraph(root, collapsed: collapsed, expanded: expandedLists.union(searchExpandedLists))
    }

    private func updateMatches(focusFirst: Bool) {
        // Open long lists whose hidden middle has a match, so search finds everything.
        if let root {
            let needed = query.trimmingCharacters(in: .whitespaces).count >= 2
                ? JSONGraph.listsHidingMatches(query, in: root, expanded: expandedLists) : []
            if needed != searchExpandedLists {
                searchExpandedLists = needed
                layoutGraph()
            }
        }
        matches = graph?.search(query) ?? []
        matchIndex = 0
        if focusFirst, let first = matches.first { focus(on: first) }
    }

    /// Selects a card and pans so it's in the middle of the canvas.
    private func focus(on id: Int) {
        guard let node = graph?.nodes.first(where: { $0.id == id }) else { return }
        selectedPath = node.path
        if zoom < 0.6 { zoom = 0.9 }
        let centerX = Double(viewSize.width) / 2, centerY = Double(viewSize.height) / 2
        offset = CGSize(width: centerX - (node.frame.x + node.frame.width / 2) * zoom,
                        height: centerY - node.frame.midY * zoom)
    }

    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
