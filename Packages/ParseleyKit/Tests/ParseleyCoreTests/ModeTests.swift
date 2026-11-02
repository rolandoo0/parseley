import Foundation
import Testing
import ParseleyCore

@Suite struct ModeLibraryTests {
    let library = ModeLibrary()

    @Test func builtInsInOrderWithGeneralFirst() {
        #expect(library.modes.map(\.id) == ["general", "finance", "sql", "dev", "writing"])
        #expect(library.general.name == "General")
    }

    @Test func generalIsAlwaysPresent() {
        let custom = ModeLibrary(modes: [Mode(id: "x", name: "X", icon: "star")])
        #expect(custom.modes.map(\.id) == ["general", "x"])
    }

    @Test func appDecidesTheMode() {
        #expect(library.mode(forApp: "com.microsoft.Excel").id == "finance")
        #expect(library.mode(forApp: "com.tinyapp.TablePlus").id == "sql")
        #expect(library.mode(forApp: "com.apple.Safari").id == "general")
        #expect(library.mode(forApp: nil).id == "general")
    }

    @Test func manualLockWinsOverApp() {
        #expect(library.resolve(app: "com.microsoft.Excel", manualModeID: "sql").id == "sql")
        #expect(library.resolve(app: "com.microsoft.Excel", manualModeID: nil).id == "finance")
        #expect(library.resolve(app: "com.microsoft.Excel", manualModeID: "deleted").id == "finance")
    }

    @Test func assignMovesAnAppBetweenModes() {
        var lib = library
        lib.assign(app: "com.microsoft.Excel", to: "sql")
        #expect(lib.mode(forApp: "com.microsoft.Excel").id == "sql")
        #expect(lib.mode(id: "finance")?.apps.contains("com.microsoft.Excel") == false)
        lib.assign(app: "com.microsoft.Excel", to: "general")
        #expect(lib.mode(forApp: "com.microsoft.Excel").id == "general")
    }

    @Test func upsertRemoveAndReset() {
        var lib = library
        var custom = Mode(id: "tax", name: "Taxes", icon: "doc.text", apps: ["com.example.tax"], numberFormat: .european)
        lib.upsert(custom)
        #expect(lib.mode(forApp: "com.example.tax").name == "Taxes")
        custom.name = "Tax Season"
        lib.upsert(custom)
        #expect(lib.modes.filter { $0.id == "tax" }.count == 1)
        #expect(lib.mode(id: "tax")?.name == "Tax Season")

        lib.remove(id: "general")
        #expect(lib.mode(id: "general") != nil, "General can't be removed")
        lib.remove(id: "finance")
        #expect(lib.mode(forApp: "com.microsoft.Excel").id == "general")
        lib.resetBuiltIns()
        #expect(lib.mode(forApp: "com.microsoft.Excel").id == "finance")
        #expect(lib.mode(id: "tax") != nil, "custom modes survive a reset")
    }

    @Test func roundTripsThroughJSON() throws {
        var lib = library
        lib.upsert(Mode(id: "tax", name: "Taxes", icon: "doc.text", numberFormat: .european, showsNumbers: false))
        let data = try JSONEncoder().encode(lib)
        #expect(try JSONDecoder().decode(ModeLibrary.self, from: data) == lib)
    }

    @Test func presetsLookRight() {
        #expect(Mode.writing.showsNumbers == false)
        #expect(Mode.writing.countsInSeries == false)
        #expect(Mode.finance.countsInSeries)
        #expect(Mode.sql.pinnedTransforms.first == "sql.in")
        // Every pinned id refers to a real transform.
        let ids = Set(TransformRegistry.all.map(\.id))
        for mode in Mode.builtIns { #expect(mode.pinnedTransforms.allSatisfy(ids.contains), "\(mode.name)") }
        for mode in Mode.builtIns { #expect(NumberStats.labels.contains(mode.primaryStat)) }
    }
}

@Suite struct FuzzyMatchTests {
    let commands = ["Comma list", "SQL IN", "JSON array", "Sort ↑", "Sort ↓", "Dedupe",
                    "Clean whitespace", "Plain numbers", "Copy sum", "Copy average", "Start series"]

    @Test func emptyQueryKeepsEverything() {
        #expect(FuzzyMatch.rank(commands, query: " ", key: { $0 }) == commands)
    }

    @Test func prefixBeatsEverything() {
        #expect(FuzzyMatch.rank(commands, query: "sql", key: { $0 }).first == "SQL IN")
        #expect(FuzzyMatch.rank(commands, query: "de", key: { $0 }).first == "Dedupe")
    }

    @Test func wordStartSubstring() {
        #expect(FuzzyMatch.rank(commands, query: "sum", key: { $0 }).first == "Copy sum")
        #expect(FuzzyMatch.rank(commands, query: "series", key: { $0 }) == ["Start series"])
    }

    @Test func scatteredCharacters() {
        #expect(FuzzyMatch.rank(commands, query: "sqin", key: { $0 }).first == "SQL IN")
        #expect(FuzzyMatch.rank(commands, query: "cav", key: { $0 }).first == "Copy average")
    }

    @Test func noMatchIsExcluded() {
        #expect(FuzzyMatch.rank(commands, query: "zzz", key: { $0 }).isEmpty)
        #expect(FuzzyMatch.score("abc", "acb") == nil)
    }

    @Test func caseInsensitiveAndIgnoresQuerySpaces() {
        #expect(FuzzyMatch.score("COPY SUM", "Copy sum") != nil)
        #expect(FuzzyMatch.rank(commands, query: "copysum", key: { $0 }).first == "Copy sum")
    }

    @Test func tiesKeepOriginalOrder() {
        #expect(FuzzyMatch.rank(["Sort ↑", "Sort ↓"], query: "sort", key: { $0 }) == ["Sort ↑", "Sort ↓"])
    }
}
