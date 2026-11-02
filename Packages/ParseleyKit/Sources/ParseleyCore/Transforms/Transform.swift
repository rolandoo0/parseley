/// A one-click text transformation. Text in, text out, so transforms compose: a saved
/// "recipe" (v2) is just a `TransformChain` of these.
public protocol Transform: Sendable {
    /// Stable identifier, safe to store (e.g. in a saved recipe). Never rename one.
    var id: String { get }
    /// Short button label.
    var title: String { get }
    func apply(_ input: String) throws -> String
}

public enum TransformError: Error, Equatable, Sendable {
    /// The input had no items (empty or whitespace only).
    case noItems
    /// The transform works on numbers and the input has none.
    case noNumbers

    public var message: String {
        switch self {
        case .noItems: "Nothing to transform"
        case .noNumbers: "No numbers found"
        }
    }
}

/// Several transforms applied in order; itself a `Transform`, so chains can nest.
public struct TransformChain: Transform {
    public let steps: [any Transform]
    public init(steps: [any Transform]) { self.steps = steps }

    public var id: String { steps.map(\.id).joined(separator: ">") }
    public var title: String { steps.map(\.title).joined(separator: " → ") }

    public func apply(_ input: String) throws -> String {
        try steps.reduce(input) { text, step in try step.apply(text) }
    }
}

/// All built-in transforms, in the order the UI shows them.
public enum TransformRegistry {
    public static let all: [any Transform] = [
        CommaListTransform(),
        SQLInTransform(),
        JSONArrayTransform(),
        SortTransform(ascending: true),
        SortTransform(ascending: false),
        DedupeTransform(),
        CleanWhitespaceTransform(),
        RemoveNumberFormattingTransform(),
    ]

    public static func transform(id: String) -> (any Transform)? {
        all.first { $0.id == id }
    }
}
