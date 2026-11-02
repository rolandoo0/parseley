import Foundation
import Testing
import ParseleyCore
@testable import ParseleyCapture

/// In-memory stand-in for NSPasteboard.
final class FakePasteboard: Pasteboard {
    private(set) var changeCount = 0
    private(set) var types: [String] = []
    private var string: String?

    /// Simulates another app copying something.
    func simulateCopy(_ text: String?, extraTypes: [String] = []) {
        string = text
        types = (text == nil ? [] : ["public.utf8-plain-text"]) + extraTypes
        changeCount += 1
    }

    func readString() -> String? { string }

    func writeString(_ string: String) {
        simulateCopy(string)
    }
}

final class FakeFrontmostApp: FrontmostAppProvider {
    var frontmostBundleID: String? = "com.example.editor"
}

@Suite struct ClipboardMonitorTests {
    let pasteboard = FakePasteboard()
    let frontmost = FakeFrontmostApp()
    let store: InMemoryClipStore
    let monitor: ClipboardMonitor

    init() {
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        store = InMemoryClipStore(now: { t += 1; return t })
        monitor = ClipboardMonitor(pasteboard: pasteboard, frontmostApp: frontmost, store: store)
    }

    func history() throws -> [String] {
        try store.fetch(matching: nil, limit: 100).map(\.content)
    }

    @Test func noChangeMeansNoEvent() {
        #expect(monitor.poll() == nil)
    }

    @Test func ignoresClipboardContentPresentAtLaunch() throws {
        let pb = FakePasteboard()
        pb.simulateCopy("was here before launch")
        let m = ClipboardMonitor(pasteboard: pb, frontmostApp: frontmost, store: store)
        #expect(m.poll() == nil)
        #expect(try store.count() == 0)
    }

    @Test func capturesTextWithSourceAppAndKind() throws {
        pasteboard.simulateCopy("https://example.com")
        let event = try #require(monitor.poll())
        guard case .stored(.inserted(let clip)) = event else {
            Issue.record("unexpected \(event)"); return
        }
        #expect(clip.content == "https://example.com")
        #expect(clip.kind == .url)
        #expect(clip.sourceBundleID == "com.example.editor")
    }

    @Test func eachChangeIsHandledOnce() throws {
        pasteboard.simulateCopy("a")
        #expect(monitor.poll() != nil)
        #expect(monitor.poll() == nil)
        #expect(try history() == ["a"])
    }

    @Test func consecutiveIdenticalCopiesAreDeduped() throws {
        pasteboard.simulateCopy("same"); monitor.poll()
        pasteboard.simulateCopy("same")
        guard case .stored(.duplicateOfLatest) = monitor.poll() else {
            Issue.record("expected duplicate"); return
        }
        #expect(try history() == ["same"])
    }

    @Test func skipsConcealedAndTransientTypes() throws {
        pasteboard.simulateCopy("hunter2", extraTypes: ["org.nspasteboard.ConcealedType"])
        #expect(monitor.poll() == .skipped(.privacy(.blockedPasteboardType("org.nspasteboard.ConcealedType"))))
        pasteboard.simulateCopy("otp 123456", extraTypes: ["org.nspasteboard.TransientType"])
        #expect(monitor.poll() == .skipped(.privacy(.blockedPasteboardType("org.nspasteboard.TransientType"))))
        #expect(try store.count() == 0)
    }

    @Test func skipsExcludedApps() throws {
        monitor.configuration.privacy.excludedBundleIDs = ["com.example.bank"]
        frontmost.frontmostBundleID = "com.example.bank"
        pasteboard.simulateCopy("account 12345")
        #expect(monitor.poll() == .skipped(.privacy(.excludedApp("com.example.bank"))))
        #expect(try store.count() == 0)
    }

    @Test func skipsNonTextAndBlankAndHugeContent() throws {
        pasteboard.simulateCopy(nil)
        #expect(monitor.poll() == .skipped(.noText))
        pasteboard.simulateCopy("  \n\t ")
        #expect(monitor.poll() == .skipped(.whitespaceOnly))
        monitor.configuration.maxCharacters = 10
        pasteboard.simulateCopy(String(repeating: "x", count: 11))
        #expect(monitor.poll() == .skipped(.tooLong(characters: 11)))
        #expect(try store.count() == 0)
    }

    @Test func keepsWhitespaceInStoredContent() throws {
        pasteboard.simulateCopy("  padded\n")
        monitor.poll()
        #expect(try history() == ["  padded\n"])
    }

    @Test func enforcesHistoryLimitButKeepsPinned() throws {
        monitor.configuration.historyLimit = 3
        pasteboard.simulateCopy("pinned"); monitor.poll()
        try store.setPinned(id: try #require(try store.fetch(matching: nil, limit: 1).first?.id), true)
        for i in 0..<5 { pasteboard.simulateCopy("c\(i)"); monitor.poll() }
        #expect(try history() == ["pinned", "c4", "c3", "c2"])
    }

    @Test func onEventIsCalledForEveryHandledChange() {
        var events: [CaptureEvent] = []
        monitor.onEvent = { events.append($0) }
        pasteboard.simulateCopy("a"); monitor.poll()
        monitor.poll()
        pasteboard.simulateCopy(nil); monitor.poll()
        #expect(events.count == 2)
    }

    @Test func copyingExistingClipMovesItToTopWithoutRecapture() throws {
        pasteboard.simulateCopy("first"); monitor.poll()
        pasteboard.simulateCopy("second"); monitor.poll()
        let first = try #require(try store.fetch(matching: "first", limit: 1).first)

        try monitor.copyToClipboard(clipID: first.id!)

        #expect(pasteboard.readString() == "first")
        #expect(monitor.poll() == nil, "our own write must not be captured again")
        #expect(try history() == ["first", "second"])
    }

    @Test func copyingNewTextRecordsItOnce() throws {
        let result = try monitor.copyToClipboard(newText: "1, 2, 3")
        #expect(result.clip.content == "1, 2, 3")
        #expect(pasteboard.readString() == "1, 2, 3")
        #expect(monitor.poll() == nil)
        #expect(try history() == ["1, 2, 3"])
    }

    @Test func externalCopyAfterOwnWriteIsStillCaptured() throws {
        try monitor.copyToClipboard(newText: "mine")
        pasteboard.simulateCopy("theirs")
        #expect(monitor.poll() != nil)
        #expect(try history() == ["theirs", "mine"])
    }
}

@Suite struct ClipboardMonitorQuietWriteTests {
    @Test func writeWithoutRecordingIsNotCapturedOrStored() throws {
        let pasteboard = FakePasteboard()
        let store = InMemoryClipStore()
        let monitor = ClipboardMonitor(pasteboard: pasteboard, frontmostApp: FakeFrontmostApp(), store: store)
        monitor.writeWithoutRecording("queued item")
        #expect(monitor.currentText == "queued item")
        #expect(monitor.poll() == nil)
        #expect(try store.count() == 0)
    }
}
