import Foundation

/// JSON drawn as a graph, read left to right:
/// - an object is a card listing its plain values (`name: "Ana"`, `age: 31`);
/// - each nested object or array is its own card, linked from its parent by an edge
///   labelled with the key;
/// - an array is a small card (`items [3]`) whose elements hang off it.
///
/// Positions are computed here (pure, testable); the app only draws them.
public struct JSONGraph: Sendable {
    public struct Row: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case string, number, bool, null, object, array }
        /// Nil for a bare value (an array element that's a string, say).
        public let key: String?
        /// Display text, shortened if very long (strings keep their quotes).
        public let value: String
        public let kind: Kind
    }

    public struct Node: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case object, array, value, more }
        public let id: Int
        public let kind: Kind
        /// Where it sits in the document: `$`, `$.users[0]`, `$.users[0].address`.
        public let path: String
        /// Header text for arrays ("items") and for objects reached through a key.
        public let title: String?
        public let rows: [Row]
        /// Members/elements under it that are drawn as their own cards.
        public let childCount: Int
        public let isCollapsed: Bool
        public let parent: Int?
        public let depth: Int
        public var frame: Rect = .zero
    }

    public struct Edge: Equatable, Sendable {
        public let from: Int
        public let to: Int
        public let label: String?
    }

    /// CoreGraphics-free rectangle so the core stays portable (and testable on Linux).
    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double
        public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
        public var midY: Double { y + height / 2 }
        public func intersects(_ other: Rect) -> Bool {
            x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
        }
    }

    public struct Metrics: Sendable {
        public var charWidth = 7.8          // 13 pt monospaced
        public var rowHeight = 22.0
        public var headerHeight = 28.0
        public var padding = 12.0
        public var minWidth = 120.0
        public var maxWidth = 380.0
        public var columnGap = 90.0
        public var rowGap = 18.0
        public init() {}
    }

    public private(set) var nodes: [Node] = []
    public private(set) var edges: [Edge] = []
    public private(set) var size = Rect.zero
    /// True when the document had more nodes than `maxNodes` and was cut short.
    public private(set) var isTruncated = false

    /// Longest value shown on a card; the inspector shows the full value.
    public static let maxValueLength = 48

    /// - Parameters:
    ///   - collapsed: paths of cards whose children are hidden.
    ///   - maxNodes: stop adding cards after this many (huge documents stay responsive).
    public init(_ root: JSONValue, collapsed: Set<String> = [], maxNodes: Int = 2_000,
                metrics: Metrics = Metrics()) {
        var builder = Builder(collapsed: collapsed, maxNodes: maxNodes)
        builder.add(root, path: "$", title: nil, parent: nil, edgeLabel: nil, depth: 0)
        nodes = builder.nodes
        edges = builder.edges
        isTruncated = builder.truncated
        layout(metrics)
    }

    /// Cards whose path or text contains `query` (case-insensitive), in document order.
    public func search(_ query: String) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return nodes.filter { node in
            if (node.title ?? "").lowercased().contains(q) { return true }
            return node.rows.contains { ($0.key ?? "").lowercased().contains(q) || $0.value.lowercased().contains(q) }
        }.map(\.id)
    }

    /// The value at a path built by this graph (`$`, `$.a[0].b`), for copying.
    public static func value(at path: String, in root: JSONValue) -> JSONValue? {
        var current = root
        for step in Self.steps(of: path) {
            switch (step, current) {
            case (.key(let key), .object(let members)):
                guard let member = members.last(where: { $0.key == key }) else { return nil }
                current = member.value
            case (.index(let i), .array(let elements)):
                guard elements.indices.contains(i) else { return nil }
                current = elements[i]
            default:
                return nil
            }
        }
        return current
    }

    // MARK: Paths

    enum Step: Equatable { case key(String), index(Int) }

    /// `.name` for identifier-like keys, `["odd key"]` otherwise (JSONPath style).
    static func appending(_ key: String, to path: String) -> String {
        let simple = !key.isEmpty && key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$"
        } && !(key.first?.isNumber ?? false)
        return simple ? "\(path).\(key)" : "\(path)[\(JSONValue.quoted(key))]"
    }

    static func steps(of path: String) -> [Step] {
        var steps: [Step] = []
        var rest = Substring(path.hasPrefix("$") ? String(path.dropFirst()) : path)
        while let first = rest.first {
            if first == "." {
                rest = rest.dropFirst()
                let end = rest.firstIndex(where: { $0 == "." || $0 == "[" }) ?? rest.endIndex
                steps.append(.key(String(rest[..<end])))
                rest = rest[end...]
            } else if first == "[" {
                rest = rest.dropFirst()
                if rest.first == "\"" {
                    // Quoted key: scan to the closing quote that isn't escaped.
                    var i = rest.index(after: rest.startIndex)
                    var escaped = false
                    while i < rest.endIndex {
                        if escaped { escaped = false } else if rest[i] == "\\" { escaped = true } else if rest[i] == "\"" { break }
                        i = rest.index(after: i)
                    }
                    let literal = String(rest[rest.startIndex...min(i, rest.index(before: rest.endIndex))])
                    if case .string(let key)? = try? JSONValue.parse(literal) { steps.append(.key(key)) }
                    rest = i < rest.endIndex ? rest[rest.index(after: i)...] : ""
                    if rest.first == "]" { rest = rest.dropFirst() }
                } else {
                    let end = rest.firstIndex(of: "]") ?? rest.endIndex
                    steps.append(.index(Int(rest[..<end]) ?? -1))
                    rest = end < rest.endIndex ? rest[rest.index(after: end)...] : ""
                }
            } else {
                break
            }
        }
        return steps
    }

    // MARK: Building

    private struct Builder {
        let collapsed: Set<String>
        let maxNodes: Int
        var nodes: [Node] = []
        var edges: [Edge] = []
        var truncated = false

        mutating func add(_ value: JSONValue, path: String, title: String?, parent: Int?,
                          edgeLabel: String?, depth: Int) {
            guard nodes.count < maxNodes else { truncated = true; return }
            let id = nodes.count
            let isCollapsed = collapsed.contains(path)
            switch value {
            case .object(let members):
                var rows: [Row] = []
                var children: [(JSONMember, String)] = []
                for member in members {
                    let childPath = JSONGraph.appending(member.key, to: path)
                    if member.value.isContainer {
                        children.append((member, childPath))
                        rows.append(Row(key: member.key, value: JSONGraph.summary(member.value), kind: JSONGraph.kind(member.value)))
                    } else {
                        rows.append(Row(key: member.key, value: JSONGraph.display(member.value), kind: JSONGraph.kind(member.value)))
                    }
                }
                if members.isEmpty { rows.append(Row(key: nil, value: "{ }", kind: .object)) }
                append(Node(id: id, kind: .object, path: path, title: title, rows: rows, childCount: children.count,
                            isCollapsed: isCollapsed, parent: parent, depth: depth), edgeLabel: edgeLabel)
                guard !isCollapsed else { return }
                for (member, childPath) in children {
                    add(member.value, path: childPath, title: nil, parent: id, edgeLabel: member.key, depth: depth + 1)
                }

            case .array(let elements):
                let rows = [Row(key: nil, value: "\(elements.count) item\(elements.count == 1 ? "" : "s")", kind: .array)]
                append(Node(id: id, kind: .array, path: path, title: title ?? (parent == nil ? "[ ]" : nil), rows: rows,
                            childCount: elements.count, isCollapsed: isCollapsed, parent: parent, depth: depth),
                       edgeLabel: edgeLabel)
                guard !isCollapsed else { return }
                for (i, element) in elements.enumerated() {
                    guard nodes.count < maxNodes else {
                        truncated = true
                        let rest = elements.count - i
                        let more = nodes.count
                        nodes.append(Node(id: more, kind: .more, path: "\(path)[\(i)…]", title: nil,
                                          rows: [Row(key: nil, value: "… \(rest) more", kind: .null)], childCount: 0,
                                          isCollapsed: false, parent: id, depth: depth + 1))
                        edges.append(Edge(from: id, to: more, label: nil))
                        return
                    }
                    add(element, path: "\(path)[\(i)]", title: nil, parent: id, edgeLabel: "\(i)", depth: depth + 1)
                }

            default:
                append(Node(id: id, kind: .value, path: path, title: title, rows: [Row(key: nil, value: JSONGraph.display(value),
                            kind: JSONGraph.kind(value))], childCount: 0, isCollapsed: false, parent: parent, depth: depth),
                       edgeLabel: edgeLabel)
            }
        }

        private mutating func append(_ node: Node, edgeLabel: String?) {
            nodes.append(node)
            if let parent = node.parent { edges.append(Edge(from: parent, to: node.id, label: edgeLabel)) }
        }
    }

    static func kind(_ value: JSONValue) -> Row.Kind {
        switch value {
        case .string: .string
        case .number: .number
        case .bool: .bool
        case .null: .null
        case .object: .object
        case .array: .array
        }
    }

    static func display(_ value: JSONValue) -> String {
        let text: String
        switch value {
        case .string(let s): text = JSONValue.quoted(s)
        case .number(let n): text = n
        case .bool(let b): text = b ? "true" : "false"
        case .null: text = "null"
        case .object, .array: text = summary(value)
        }
        return text.count > maxValueLength ? String(text.prefix(maxValueLength - 1)) + "…" : text
    }

    /// `{3 keys}` / `[5 items]` for containers listed inside their parent card.
    static func summary(_ value: JSONValue) -> String {
        switch value {
        case .object(let m): "{\(m.count) key\(m.count == 1 ? "" : "s")}"
        case .array(let e): "[\(e.count) item\(e.count == 1 ? "" : "s")]"
        default: display(value)
        }
    }

    // MARK: Layout

    /// Columns by depth (each as wide as its widest card), and each subtree stacked in its
    /// own horizontal band with the parent centered on its children. Bands never overlap,
    /// so cards never do.
    private mutating func layout(_ m: Metrics) {
        guard !nodes.isEmpty else { return }
        // Card sizes.
        for i in nodes.indices {
            let node = nodes[i]
            let longest = node.rows.map { row in (row.key.map { $0.count + 2 } ?? 0) + row.value.count }.max() ?? 0
            let titleLength = (node.title?.count ?? 0) + 4
            let width = min(m.maxWidth, max(m.minWidth, Double(max(longest, titleLength)) * m.charWidth + m.padding * 2))
            let height = (node.title != nil ? m.headerHeight : 0) + Double(node.rows.count) * m.rowHeight + m.padding
            nodes[i].frame = Rect(x: 0, y: 0, width: width, height: height)
        }
        // Column x positions.
        let maxDepth = nodes.map(\.depth).max() ?? 0
        var columnWidth = Array(repeating: 0.0, count: maxDepth + 1)
        for node in nodes { columnWidth[node.depth] = max(columnWidth[node.depth], node.frame.width) }
        var columnX = Array(repeating: 0.0, count: maxDepth + 1)
        for d in 1..<(maxDepth + 1) where maxDepth > 0 { columnX[d] = columnX[d - 1] + columnWidth[d - 1] + m.columnGap }

        var children = Array(repeating: [Int](), count: nodes.count)
        for edge in edges { children[edge.from].append(edge.to) }

        // Band height of each subtree (post-order: children have higher ids).
        var band = Array(repeating: 0.0, count: nodes.count)
        for id in nodes.indices.reversed() {
            let kids = children[id]
            let kidsHeight = kids.reduce(0) { $0 + band[$1] } + Double(max(0, kids.count - 1)) * m.rowGap
            band[id] = max(nodes[id].frame.height, kidsHeight)
        }

        // Place: walk down, giving each child its band within the parent's band.
        var top = Array(repeating: 0.0, count: nodes.count)
        var y = 0.0
        for id in nodes.indices where nodes[id].parent == nil {
            top[id] = y
            y += band[id] + m.rowGap
        }
        for id in nodes.indices {
            let kids = children[id]
            let kidsHeight = kids.reduce(0) { $0 + band[$1] } + Double(max(0, kids.count - 1)) * m.rowGap
            var cursor = top[id] + (band[id] - kidsHeight) / 2
            for kid in kids {
                top[kid] = cursor
                cursor += band[kid] + m.rowGap
            }
            nodes[id].frame.x = columnX[nodes[id].depth]
            nodes[id].frame.y = top[id] + (band[id] - nodes[id].frame.height) / 2
        }
        let width = nodes.map(\.frame.maxX).max() ?? 0
        let height = nodes.map(\.frame.maxY).max() ?? 0
        size = Rect(x: 0, y: 0, width: width, height: height)
    }
}
