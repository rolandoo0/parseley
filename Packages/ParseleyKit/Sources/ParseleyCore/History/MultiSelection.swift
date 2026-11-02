/// ⌘-click / ⇧-click selection of several clips in the history list, as plain logic.
/// Works alongside `ListSelection` (the focused row): it only becomes "active" once two
/// or more clips are selected.
public struct MultiSelection: Equatable, Sendable {
    public private(set) var ids: Set<Int64> = []

    public init() {}

    /// Two or more clips selected.
    public var isActive: Bool { ids.count >= 2 }

    /// ⌘-click: add or remove `id`. The first ⌘-click also includes the row that was
    /// already focused, so ⌘-clicking one more row selects two.
    public mutating func toggle(_ id: Int64, focused: Int64?) {
        if ids.isEmpty, let focused, focused != id { ids.insert(focused) }
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        if ids.count < 2 { ids.removeAll() }
    }

    /// ⇧-click: everything between `anchor` (the focused row) and `id`, in list order.
    public mutating func extend(to id: Int64, from anchor: Int64?, in list: [Int64]) {
        guard let anchor, let a = list.firstIndex(of: anchor), let b = list.firstIndex(of: id) else {
            ids.removeAll()
            return
        }
        ids = Set(list[min(a, b)...max(a, b)])
        if ids.count < 2 { ids.removeAll() }
    }

    /// Drops ids no longer in the list (after a delete or reload).
    public mutating func prune(to list: [Int64]) {
        ids.formIntersection(list)
        if ids.count < 2 { ids.removeAll() }
    }

    public mutating func clear() { ids.removeAll() }

    public func contains(_ id: Int64?) -> Bool {
        guard let id else { return false }
        return ids.contains(id)
    }

    /// Selected ids in list order.
    public func ordered(in list: [Int64]) -> [Int64] {
        list.filter(ids.contains)
    }
}
