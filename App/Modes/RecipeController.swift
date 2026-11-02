import Foundation
import Observation
import ParseleyCore
import SwiftUI

/// The user's recipes (saved transform chains), stored in UserDefaults as JSON.
@MainActor
@Observable
final class RecipeController {
    private(set) var library: RecipeLibrary { didSet { save() } }

    private static let key = "recipes.library"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(RecipeLibrary.self, from: data) {
            library = saved
        } else {
            library = RecipeLibrary()
        }
    }

    var recipes: [Recipe] { library.recipes }

    func recipe(id: String) -> Recipe? { library.recipe(id: id) }

    /// All recipes as transforms (recipes without valid steps are left out).
    func transforms(format: NumberFormat) -> [any Transform] {
        library.recipes.compactMap { $0.transform(format: format) }
    }

    func update(_ recipe: Recipe) { library.upsert(recipe) }
    func remove(id: String) { library.remove(id: id) }

    @discardableResult
    func addRecipe() -> Recipe {
        let recipe = Recipe(id: UUID().uuidString, name: "New Recipe", steps: ["text.clean"])
        library.upsert(recipe)
        return recipe
    }

    /// A two-way binding to one recipe, for the Settings editor.
    func binding(for id: String) -> Binding<Recipe> {
        Binding(
            get: { [weak self] in self?.library.recipe(id: id) ?? Recipe(id: id, name: "", steps: []) },
            set: { [weak self] in self?.library.upsert($0) }
        )
    }

    private func save() {
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
