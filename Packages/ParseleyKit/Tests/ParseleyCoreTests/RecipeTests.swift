import Foundation
import Testing
import ParseleyCore

@Suite struct RecipeTests {
    @Test func runsStepsInOrder() throws {
        let recipe = Recipe(id: "r", name: "Clean SQL list", steps: ["text.clean", "list.dedupe", "sort.asc", "sql.in"])
        let t = try #require(recipe.transform())
        #expect(try t.apply("  3\n1\n\n3\n 2 ") == "IN (1, 2, 3)")
        #expect(t.id == "recipe.r")
        #expect(t.title == "Clean SQL list")
    }

    @Test func skipsUnknownStepsAndRejectsEmpty() throws {
        let partial = Recipe(id: "p", name: "P", steps: ["nope", "list.comma"])
        #expect(try partial.transform()?.apply("a\nb") == "a, b")
        #expect(Recipe(id: "e", name: "E", steps: ["nope"]).transform() == nil)
        #expect(Recipe(id: "e", name: "E", steps: []).transform() == nil)
    }

    @Test func usesNumberFormat() throws {
        let r = Recipe(id: "s", name: "S", steps: ["sort.asc", "json.array"])
        #expect(try r.transform(format: .european)?.apply("2,5\n1.000\n3") == "[2.5, 3, 1000]")
    }

    @Test func summaryListsStepTitles() {
        #expect(Recipe(id: "x", name: "X", steps: ["text.clean", "sql.in"]).summary == "Clean whitespace → SQL IN")
    }

    @Test func libraryEditsAndCodable() throws {
        var lib = RecipeLibrary()
        #expect(lib.recipes.map(\.id) == ["sql-list", "unique-sorted", "plain-csv"])
        lib.upsert(Recipe(id: "mine", name: "Mine", steps: ["list.comma"]))
        lib.upsert(Recipe(id: "mine", name: "Mine 2", steps: ["list.comma"]))
        #expect(lib.recipe(id: "mine")?.name == "Mine 2")
        lib.remove(id: "sql-list")
        #expect(lib.recipe(id: "sql-list") == nil)
        let data = try JSONEncoder().encode(lib)
        #expect(try JSONDecoder().decode(RecipeLibrary.self, from: data) == lib)
    }

    @Test func modesSavedBeforeAutoRecipeExistedStillDecode() throws {
        // JSON from the previous version has no "autoRecipeID" key.
        let old = #"{"modes":[{"id":"general","name":"General","icon":"list.clipboard","apps":[],"numberFormat":"us","showsNumbers":true,"countsInSeries":true,"primaryStat":"Sum","pinnedTransforms":[],"isBuiltIn":true}]}"#
        let lib = try JSONDecoder().decode(ModeLibrary.self, from: Data(old.utf8))
        #expect(lib.general.autoRecipeID == nil)
    }
}
