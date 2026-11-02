import Foundation
import Testing
@testable import ParseleyCore

private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

/// A clock the test moves by hand.
final class ManualClock {
    var current = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval) { current += seconds }
}

@Suite struct SeriesTrackerTests {
    let clock = ManualClock()
    let store = InMemorySeriesStore()
    let tracker: SeriesTracker

    init() {
        let clock = self.clock
        var rules = SeriesRules()
        rules.idleGap = 10 * 60
        tracker = SeriesTracker(store: store, rules: rules, now: { clock.current })
    }

    @discardableResult
    func copy(_ text: String, clip: Int64? = nil, app: String? = "com.excel", after seconds: TimeInterval = 5) -> SeriesTracker.IngestResult {
        clock.advance(seconds)
        return tracker.ingest(content: text, clipID: clip, sourceBundleID: app)
    }

    // MARK: Basics

    @Test func ignoresCopiesWhenNoSeriesIsActive() {
        #expect(copy("42") == .ignored(.noActiveSeries))
    }

    @Test func startCreatesNamedSeriesAndPersistsIt() throws {
        let s = tracker.start()
        #expect(s.name == "Series 1")
        #expect(tracker.isActive)
        #expect(try store.activeSeries()?.id == s.id)
        tracker.start()
        #expect(tracker.active?.name == "Series 2")
    }

    @Test func numbersOnlyCopiesAreCountedOneEntryPerCopy() throws {
        tracker.start()
        copy("$50")
        copy("120\n80\n200")          // a spreadsheet column: one entry, three values
        let series = try #require(tracker.active)
        #expect(series.entries.count == 2)
        #expect(series.values == [50, 120, 80, 200])
        let stats = try #require(series.stats)
        #expect(stats.count == 4)          // hybrid: stats count every value…
        #expect(stats.sum == 450)
        #expect(series.entries[1].subtotal == 400)   // …while the entry keeps its subtotal
    }

    @Test func mixedTextIsSkippedUntilIncluded() throws {
        tracker.start()
        copy("10")
        let result = copy("Invoice #4512 total $1,200 (incl. 8% tax)")
        guard case .skipped(let entry) = result else { Issue.record("expected skipped, got \(result)"); return }
        #expect(tracker.active?.stats?.sum == 10)

        tracker.setIncluded(true, entryID: entry.id)
        #expect(tracker.active?.values == [10, 4512, 1200, 8])

        tracker.setIncluded(false, entryID: entry.id)
        #expect(tracker.active?.values == [10])
    }

    @Test func forceAddIncludesMixedCopies() {
        tracker.start()
        clock.advance(1)
        let result = tracker.ingest(content: "Total: 99", clipID: nil, sourceBundleID: nil, force: true)
        guard case .added = result else { Issue.record("expected added"); return }
        #expect(tracker.active?.values == [99])
    }

    @Test func copiesWithoutNumbersAreIgnored() {
        tracker.start()
        #expect(copy("hello world") == .ignored(.noNumbers))
        #expect(copy("2024-01-05") == .ignored(.noNumbers))
        #expect(tracker.active?.entries.isEmpty == true)
    }

    @Test func accidentalDoubleCopyIsIgnoredButDeliberateRepeatCounts() {
        tracker.start()
        copy("50", clip: 7)
        #expect(copy("50", clip: 7, after: 1) == .ignored(.repeatedCopy))
        guard case .added = copy("50", clip: 7, after: 10) else { Issue.record("expected added"); return }
        #expect(tracker.active?.values == [50, 50])
    }

    @Test func keepsOnlyTheLatestSkippedEntries() {
        tracker.start()
        for i in 0..<8 { copy("note \(i): 5 items") }
        #expect(tracker.active?.skippedEntries.map(\.preview) == ["note 3: 5 items", "note 4: 5 items", "note 5: 5 items", "note 6: 5 items", "note 7: 5 items"])
    }

    // MARK: Editing

    @Test func undoRemovesLastCountedCopyWithAllItsValues() {
        tracker.start()
        copy("1")
        copy("2\n3")
        tracker.undoLast()
        #expect(tracker.active?.values == [1])
        tracker.undoLast()
        tracker.undoLast()   // nothing left: no crash
        #expect(tracker.active?.values == [])
    }

    @Test func removeAndRename() {
        tracker.start()
        guard case .added(let e) = copy("5") else { Issue.record("expected added"); return }
        tracker.remove(entryID: e.id)
        #expect(tracker.active?.entries.isEmpty == true)
        tracker.rename("  Q3 expenses ")
        #expect(tracker.active?.name == "Q3 expenses")
        tracker.rename("   ")
        #expect(tracker.active?.name == "Q3 expenses")
    }

    @Test func stopEndsSeriesAndKeepsItAsHistory() throws {
        let s = tracker.start()
        copy("5")
        tracker.stop()
        #expect(!tracker.isActive)
        #expect(try store.activeSeries() == nil)
        let saved = try #require(tracker.recentSeries().first)
        #expect(saved.id == s.id)
        #expect(saved.endedAt != nil)
        #expect(saved.values == [5])
    }

    @Test func resumesActiveSeriesAfterRelaunch() {
        tracker.start(name: "Running")
        copy("5")
        let relaunched = SeriesTracker(store: store)
        #expect(relaunched.active?.name == "Running")
        #expect(relaunched.active?.values == [5])
    }

    // MARK: Prompts

    @Test func idleGapAsksInsteadOfSplitting() throws {
        tracker.start()
        copy("10")
        guard case .added(let late) = copy("20", after: 11 * 60) else { Issue.record("expected added"); return }
        #expect(tracker.prompt == .idleGap(minutes: 11, entryID: late.id))
        #expect(tracker.active?.values == [10, 20], "added to the current series until the user decides")
    }

    @Test func noIdlePromptWithinGapOrOnFirstEntryOrWhenOff() {
        tracker.start()
        copy("10", after: 60 * 60)          // first entry: nothing to compare with
        copy("20", after: 9 * 60)
        #expect(tracker.prompt == nil)
        tracker.rules.idleGap = nil
        copy("30", after: 60 * 60)
        #expect(tracker.prompt == nil)
    }

    @Test func acceptingPromptMovesTheCopyAndLaterOnesToANewSeries() throws {
        let first = tracker.start()
        copy("10")
        copy("20", after: 11 * 60)
        copy("30")                          // copied before answering the prompt
        tracker.acceptPrompt()

        let fresh = try #require(tracker.active)
        #expect(fresh.id != first.id)
        #expect(fresh.values == [20, 30])
        #expect(tracker.prompt == nil)
        let old = try #require(tracker.recentSeries().first { $0.id == first.id })
        #expect(old.values == [10])
        #expect(old.endedAt != nil)
    }

    @Test func dismissingPromptKeepsEverything() {
        tracker.start()
        copy("10")
        copy("20", after: 11 * 60)
        tracker.dismissPrompt()
        #expect(tracker.prompt == nil)
        #expect(tracker.active?.values == [10, 20])
    }

    @Test func appSwitchPromptWhenEnabled() {
        tracker.rules.askOnAppSwitch = true
        tracker.start()
        copy("10", app: "com.excel")
        copy("20", app: "com.excel")
        #expect(tracker.prompt == nil)
        guard case .added(let e) = copy("30", app: "com.chrome") else { Issue.record("expected added"); return }
        #expect(tracker.prompt == .appSwitch(from: "com.excel", to: "com.chrome", entryID: e.id))
    }

    @Test func skippedCopiesDoNotTriggerPrompts() {
        tracker.rules.askOnAppSwitch = true
        tracker.start()
        copy("10", app: "com.excel")
        copy("Order 5 shipped", app: "com.mail", after: 30 * 60)
        #expect(tracker.prompt == nil)
    }

    @Test func removingPromptedEntryClearsPrompt() {
        tracker.start()
        copy("10")
        guard case .added(let e) = copy("20", after: 11 * 60) else { Issue.record("expected added"); return }
        tracker.remove(entryID: e.id)
        #expect(tracker.prompt == nil)
    }

    @Test func onSeriesEndedReportsEveryWayASeriesEnds() {
        var ended: [String] = []
        tracker.onSeriesEnded = { ended.append("\($0.name):\($0.values)") }
        tracker.start(name: "A")
        copy("1")
        tracker.start(name: "B")            // replaces A
        copy("2")
        copy("3", after: 11 * 60)
        tracker.acceptPrompt()              // splits B
        tracker.stop()                      // ends the split-off series
        #expect(ended == ["A:[1]", "B:[2]", "Series 3:[3]"])
    }

    @Test func onChangeFires() {
        var count = 0
        tracker.onChange = { count += 1 }
        tracker.start()
        copy("1")
        tracker.stop()
        #expect(count == 3)
    }

    @Test func statsKeepDecimalPrecision() throws {
        tracker.start()
        copy("$1,204.50")
        copy("0.25")
        let stats = try #require(tracker.active?.stats)
        #expect(stats.sum == d("1204.75"))
        #expect(stats.items.first { $0.label == "Sum" }?.display == "1,204.75")
    }
}
