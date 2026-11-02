/// Keyboard selection in the history list, kept as plain logic so it's unit-testable.
///
/// Tracks the selected clip by *id* (so the selection survives the list reloading when
/// a new clip arrives) and remembers its index (so after deleting the selected clip, the
/// one that slides into its place becomes selected).
public struct ListSelection: Equatable, Sendable {
    public private(set) var selectedID: Int64?
    private var lastIndex: Int = 0

    public init() {}

    /// Call whenever the visible list changes.
    /// - Parameter resetToFirst: true when the list changed because the search query
    ///   changed. The best match should then be selected.
    public mutating func update(ids: [Int64], resetToFirst: Bool = false) {
        guard !ids.isEmpty else {
            selectedID = nil
            lastIndex = 0
            return
        }
        if !resetToFirst, let id = selectedID, let index = ids.firstIndex(of: id) {
            lastIndex = index
            return
        }
        let index = resetToFirst || selectedID == nil ? 0 : min(lastIndex, ids.count - 1)
        lastIndex = index
        selectedID = ids[index]
    }

    /// Moves up (negative) or down (positive), stopping at the ends (no wrap-around).
    public mutating func move(by delta: Int, in ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let current = selectedID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        let index = max(0, min(ids.count - 1, current + delta))
        lastIndex = index
        selectedID = ids[index]
    }

    /// Selects a specific clip (e.g. on mouse click). Ignored if it isn't in the list.
    public mutating func select(_ id: Int64, in ids: [Int64]) {
        guard let index = ids.firstIndex(of: id) else { return }
        lastIndex = index
        selectedID = id
    }
}
