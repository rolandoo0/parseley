/// An ordered list of texts to paste one after another (fill a form, a column of cells).
/// The texts are copied in when the queue starts, so later history changes don't affect it.
public struct PasteQueue: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var clipID: Int64?
        public var content: String
        public init(clipID: Int64?, content: String) {
            self.clipID = clipID
            self.content = content
        }
        public var preview: String { ClipPreview.title(content, maxLength: 40) }
    }

    public private(set) var items: [Item]
    /// Index of the next item to paste.
    public private(set) var position = 0

    public init(items: [Item]) {
        self.items = items.filter { !$0.content.isEmpty }
    }

    public var count: Int { items.count }
    public var isFinished: Bool { position >= items.count }
    public var remaining: Int { max(0, items.count - position) }
    /// The item the next "paste next" will use.
    public var next: Item? { isFinished ? nil : items[position] }

    /// Returns the next item and moves past it.
    public mutating func advance() -> Item? {
        guard let item = next else { return nil }
        position += 1
        return item
    }

    /// Steps back one item (e.g. to paste the previous one again).
    public mutating func stepBack() {
        position = max(0, position - 1)
    }

    /// "2 of 5"
    public var progress: String { "\(min(position, count)) of \(count)" }
}
