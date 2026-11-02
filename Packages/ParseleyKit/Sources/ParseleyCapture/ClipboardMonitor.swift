import Foundation
import ParseleyCore

/// What happened on one poll where the clipboard had changed.
public enum CaptureEvent: Equatable {
    case stored(InsertResult)
    case skipped(SkipReason)
    case failed(String)
}

public enum SkipReason: Equatable {
    case privacy(PrivacyPolicy.Decision)
    /// The clipboard holds no plain text (e.g. only an image or files).
    case noText
    case whitespaceOnly
    case tooLong(characters: Int)
}

/// Watches the clipboard and feeds new text into the store:
///
///     poll changeCount → privacy check → read text → detect kind → store.insert → trim
///
/// Also the single place where Parseley itself writes to the clipboard, so it can
/// recognise and skip its own writes.
///
/// Threading: call everything from the main thread. `start()` schedules the timer on
/// the main run loop.
public final class ClipboardMonitor {
    public struct Configuration: Equatable {
        public var pollInterval: TimeInterval = 0.5
        /// Max unpinned clips kept. Older ones are evicted after each insert.
        public var historyLimit: Int = 1_000
        /// Clips longer than this (in characters) are ignored, to keep the DB and UI snappy.
        public var maxCharacters: Int = 500_000
        public var privacy = PrivacyPolicy()

        public init() {}
    }

    public var configuration: Configuration
    /// Called on the main thread after each handled clipboard change (stored or skipped).
    /// The UI uses it to refresh.
    public var onEvent: ((CaptureEvent) -> Void)?

    private let pasteboard: Pasteboard
    private let frontmostApp: FrontmostAppProvider
    private let store: ClipStore
    /// Number format to use for a copy from a given app (the app's mode decides).
    /// Defaults to US for everything.
    public var numberFormatForSource: (String?) -> NumberFormat = { _ in .us }
    private var lastChangeCount: Int
    private var timer: Timer?

    public init(
        pasteboard: Pasteboard,
        frontmostApp: FrontmostAppProvider,
        store: ClipStore,
        configuration: Configuration = Configuration()
    ) {
        self.pasteboard = pasteboard
        self.frontmostApp = frontmostApp
        self.store = store
        self.configuration = configuration
        // Don't import whatever was on the clipboard before launch. Only new copies.
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit { timer?.invalidate() }

    // MARK: - Lifecycle

    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: configuration.pollInterval, repeats: true) { [weak self] _ in
            _ = self?.poll()
        }
        // Tolerance lets macOS batch timer wake-ups to save battery; ±0.1 s is invisible here.
        timer.tolerance = 0.1
        // `.common` mode keeps the timer firing while a menu is open or a window is
        // being dragged (the default mode pauses during those "tracking" loops).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public var isRunning: Bool { timer != nil }

    // MARK: - Polling

    /// Checks the clipboard once. Returns nil if nothing changed. Public so tests (and a
    /// future "capture now" command) can drive it without a timer.
    @discardableResult
    public func poll() -> CaptureEvent? {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return nil }
        lastChangeCount = current

        let event = capture()
        onEvent?(event)
        return event
    }

    private func capture() -> CaptureEvent {
        let source = frontmostApp.frontmostBundleID
        // Check types before reading the text, so secrets are never even read into memory.
        let decision = configuration.privacy.evaluate(pasteboardTypes: pasteboard.types, sourceBundleID: source)
        guard decision == .allow else { return .skipped(.privacy(decision)) }

        guard let text = pasteboard.readString() else { return .skipped(.noText) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .skipped(.whitespaceOnly)
        }
        // utf16.count is O(1) for native strings, unlike count (grapheme clusters).
        guard text.utf16.count <= configuration.maxCharacters else {
            return .skipped(.tooLong(characters: text.utf16.count))
        }

        do {
            let result = try store.insert(NewClip(content: text, kind: kind(of: text, from: source), sourceBundleID: source))
            if case .inserted = result {
                try store.trim(toUnpinnedLimit: configuration.historyLimit)
            }
            return .stored(result)
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - Parseley's own clipboard writes

    /// Puts an existing history clip back on the clipboard and moves it to the top of
    /// history, without creating a duplicate entry.
    public func copyToClipboard(clipID: Int64) throws {
        guard let clip = try store.clip(id: clipID) else { return }
        writeOwn(clip.content)
        try store.touch(id: clipID)
    }

    /// Puts new text (e.g. a transform result) on the clipboard and records it in history.
    @discardableResult
    public func copyToClipboard(newText text: String, sourceBundleID: String? = nil) throws -> InsertResult {
        writeOwn(text)
        let result = try store.insert(NewClip(content: text, kind: kind(of: text, from: sourceBundleID), sourceBundleID: sourceBundleID))
        if case .inserted = result {
            try store.trim(toUnpinnedLimit: configuration.historyLimit)
        }
        return result
    }

    private func kind(of text: String, from source: String?) -> ClipKind {
        TypeDetector(format: numberFormatForSource(source)).detect(text)
    }

    /// Writes to the clipboard and marks that change as already seen, so the next poll
    /// doesn't capture it a second time.
    private func writeOwn(_ text: String) {
        pasteboard.writeString(text)
        lastChangeCount = pasteboard.changeCount
    }
}
