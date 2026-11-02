import AppKit
import Observation
import ParseleyCapture
import ParseleyCore
import ParseleyPaste

/// Runs a paste queue: each "paste next" (⌃⌥⌘V by default) puts the next item on the
/// clipboard and pastes it into the app in front. When the queue is done, the clipboard
/// gets back what was on it before.
@MainActor
@Observable
final class PasteQueueController {
    private(set) var queue: PasteQueue?

    @ObservationIgnored private let monitor: ClipboardMonitor
    @ObservationIgnored private let pasteService = PasteService()
    @ObservationIgnored private let toast: ToastController
    @ObservationIgnored private var originalClipboard: String?

    init(monitor: ClipboardMonitor, toast: ToastController) {
        self.monitor = monitor
        self.toast = toast
    }

    var isActive: Bool { queue != nil }

    /// Menu/status text: "Queue: 2 of 5".
    var status: String? { queue.map { "Queue: \($0.progress)" } }

    func start(with clips: [Clip]) {
        let items = clips.map { PasteQueue.Item(clipID: $0.id, content: $0.content) }
        let newQueue = PasteQueue(items: items)
        guard !newQueue.isFinished else { return toast.show("Nothing to queue", icon: "tray") }
        if queue == nil { originalClipboard = monitor.currentText }
        queue = newQueue
        toast.show("Queued \(newQueue.count) · press ⌃⌥⌘V to paste each one", icon: "list.number")
    }

    /// Pastes the next item into the frontmost app and advances.
    func pasteNext() {
        guard var current = queue else { return toast.show("No paste queue · select clips, then Queue", icon: "tray") }
        guard let item = current.advance() else { return finish() }
        queue = current
        monitor.writeWithoutRecording(item.content)

        let finished = current.isFinished
        let outcome = pasteService.paste(into: NSWorkspace.shared.frontmostApplication) { [weak self] in
            // Give the app a moment to read the clipboard, then restore what was there.
            guard finished else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.finish(announce: false) }
        }
        if outcome == .needsAccessibility {
            toast.show("Item \(current.progress) on the clipboard · press ⌘V (enable Auto-Paste to skip this)", icon: "doc.on.clipboard")
        } else if let next = current.next {
            toast.show("Pasted \(current.progress) · next: \(next.preview)", icon: "list.number")
        } else {
            toast.show("Pasted \(current.progress) · queue done", icon: "checkmark.circle.fill")
        }
    }

    /// Pastes a single value (a series result) into the front app. The clipboard gets
    /// its previous contents back afterwards, and the value is never recorded in
    /// history or counted in the running series.
    func pasteOnce(_ text: String, label: String) {
        let previous = monitor.currentText
        monitor.writeWithoutRecording(text)
        let outcome = pasteService.paste(into: NSWorkspace.shared.frontmostApplication) { [weak self] in
            // Give the app a moment to read the clipboard, then restore what was there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self, let previous, self.queue == nil else { return }
                self.monitor.writeWithoutRecording(previous)
            }
        }
        if outcome == .needsAccessibility {
            // Leave it on the clipboard so a manual ⌘V works.
            return toast.show("\(label) on the clipboard · press ⌘V (enable Auto-Paste to skip this)", icon: "doc.on.clipboard")
        }
        toast.show("Pasted \(label)", icon: "sum")
    }

    func cancel() {
        guard queue != nil else { return }
        finish(announce: true, message: "Queue cancelled")
    }

    private func finish(announce: Bool = true, message: String = "Queue done") {
        queue = nil
        if let originalClipboard { monitor.writeWithoutRecording(originalClipboard) }
        originalClipboard = nil
        if announce { toast.show(message, icon: "checkmark.circle.fill") }
    }
}
