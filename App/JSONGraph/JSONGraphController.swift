import AppKit
import ParseleyCore
import SwiftUI

/// Opens copied JSON as a graph in its own window (one window, reused).
@MainActor
final class JSONGraphController {
    private var window: NSWindow?
    private var model: JSONGraphModel?
    private var scrollMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private let copyText: (String) -> Void

    /// Documents bigger than this aren't drawn (they'd take seconds to lay out).
    static let maxLength = 5_000_000

    init(copyText: @escaping (String) -> Void) {
        self.copyText = copyText
    }

    /// Shows `text` as a graph. Invalid JSON opens the window with the parse error.
    func show(text: String, title: String) {
        guard text.utf8.count <= Self.maxLength else {
            let alert = NSAlert()
            alert.messageText = "This JSON is too large to draw"
            alert.informativeText = "It's \(text.utf8.count / 1_000_000) MB; the limit is \(Self.maxLength / 1_000_000) MB."
            alert.runModal()
            return
        }
        let model = JSONGraphModel(text: text, title: title)
        model.copyText = copyText
        self.model = model

        let window = self.window ?? makeWindow()
        window.title = "JSON · \(title)"
        window.contentView = NSHostingView(rootView: JSONGraphView(model: model))
        self.window = window
        installScrollMonitor()
        // A menu-bar app isn't active by default; bring the window forward.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("JSONGraphWindow")
        if !window.setFrameUsingName("JSONGraphWindow") { window.center() }
        // Release the document and the scroll monitor when the window closes.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.contentView = nil
                self?.model = nil
                if let monitor = self?.scrollMonitor { NSEvent.removeMonitor(monitor) }
                self?.scrollMonitor = nil
            }
        }
        return window
    }

    /// Trackpad/mouse-wheel scrolling pans the graph; pinch or ⌘-scroll zooms. SwiftUI's
    /// Canvas doesn't get scroll events on macOS, so we watch them for this window.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, let model = self.model,
                  let content = window.contentView else { return event }
            // SwiftUI coordinates start at the top-left; AppKit's at the bottom-left.
            let location = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            guard location.x < model.canvasMaxX else { return event }   // leave the inspector's scrolling alone
            let point = CGPoint(x: location.x, y: location.y - model.canvasTop)
            if event.type == .magnify {
                model.zoom(by: 1 + event.magnification, anchor: point)
            } else if event.modifierFlags.contains(.command) {
                model.zoom(by: event.scrollingDeltaY > 0 ? 1.08 : 1 / 1.08, anchor: point)
            } else {
                let scale = event.hasPreciseScrollingDeltas ? 1.0 : 8.0   // mouse wheels move in lines
                model.pan(by: CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale))
            }
            return nil
        }
    }
}
