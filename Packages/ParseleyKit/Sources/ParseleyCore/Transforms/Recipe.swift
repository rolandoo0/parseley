/// A saved chain of transforms, e.g. Clean whitespace → Dedupe → Sort ↑ → SQL IN.
/// Stores transform ids (stable), so recipes survive app updates.
public struct Recipe: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    /// Transform ids, applied in order. Unknown ids are skipped.
    public var steps: [String]

    public init(id: String, name: String, steps: [String]) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    /// The recipe as a single transform, or nil if it has no valid steps.
    public func transform(format: NumberFormat = .us) -> RecipeTransform? {
        let transforms = steps.compactMap { TransformRegistry.transform(id: $0, format: format) }
        guard !transforms.isEmpty else { return nil }
        return RecipeTransform(recipe: self, chain: TransformChain(steps: transforms))
    }

    /// "Clean whitespace → Dedupe → SQL IN"
    public var summary: String {
        steps.compactMap { TransformRegistry.transform(id: $0)?.title }.joined(separator: " → ")
    }
}

/// A recipe wrapped as a `Transform`, so it fits anywhere a transform does (buttons,
/// command bar, auto-run).
public struct RecipeTransform: Transform {
    public let recipe: Recipe
    public let chain: TransformChain

    public var id: String { "recipe.\(recipe.id)" }
    public var title: String { recipe.name }

    public func apply(_ input: String) throws -> String {
        try chain.apply(input)
    }
}

/// The user's recipes. Codable so the app can store it as one JSON value.
public struct RecipeLibrary: Equatable, Codable, Sendable {
    public private(set) var recipes: [Recipe]

    public init(recipes: [Recipe] = RecipeLibrary.starters) {
        self.recipes = recipes
    }

    public func recipe(id: String) -> Recipe? {
        recipes.first { $0.id == id }
    }

    public mutating func upsert(_ recipe: Recipe) {
        if let i = recipes.firstIndex(where: { $0.id == recipe.id }) { recipes[i] = recipe } else { recipes.append(recipe) }
    }

    public mutating func remove(id: String) {
        recipes.removeAll { $0.id == id }
    }

    /// A few useful recipes to start from.
    public static let starters: [Recipe] = [
        Recipe(id: "sql-list", name: "Clean SQL list", steps: ["text.clean", "list.dedupe", "sort.asc", "sql.in"]),
        Recipe(id: "unique-sorted", name: "Unique & sorted", steps: ["text.clean", "list.dedupe", "sort.asc"]),
        Recipe(id: "plain-csv", name: "Plain numbers, comma list", steps: ["number.plain", "list.comma"]),
    ]
}
