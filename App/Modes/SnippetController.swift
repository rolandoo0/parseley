import Foundation
import Observation
import ParseleyCore
import SwiftUI

/// The user's snippets (templates with fields), stored in UserDefaults as JSON.
@MainActor
@Observable
final class SnippetController {
    private(set) var library: SnippetLibrary { didSet { save() } }

    private static let key = "snippets.library"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(SnippetLibrary.self, from: data) {
            library = saved
        } else {
            library = SnippetLibrary()
        }
    }

    var snippets: [Snippet] { library.snippets }

    func snippet(id: String) -> Snippet? { library.snippets.first { $0.id == id } }

    @discardableResult
    func addSnippet() -> Snippet {
        let snippet = Snippet(name: "New Snippet", body: "{clipboard}")
        library.upsert(snippet)
        return snippet
    }

    func remove(id: String) { library.remove(id: id) }

    /// A two-way binding to one snippet, for the Settings editor.
    func binding(for id: String) -> Binding<Snippet> {
        Binding(
            get: { [weak self] in self?.snippet(id: id) ?? Snippet(id: id, name: "", body: "") },
            set: { [weak self] in self?.library.upsert($0) }
        )
    }

    private func save() {
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
