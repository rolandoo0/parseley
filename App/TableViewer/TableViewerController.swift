import AppKit
import ParseleyCore
import SwiftUI

/// Opens a copied table (CSV/TSV…) in its own window (one window, reused).
@MainActor
final class TableViewerController {
    private var window: NSWindow?
    private var model: TableViewerModel?
    private var closeObserver: NSObjectProtocol?
    private let copyText: (String) -> Void

    init(copyText: @escaping (String) -> Void) {
        self.copyText = copyText
    }

    func show(text: String, title: String, format: NumberFormat) {
        let model = TableViewerModel(text: text, title: title, format: format)
        model.copyText = copyText
        self.model = model
        let window = self.window ?? makeWindow()
        window.title = "Table · \(title)"
        window.contentView = NSHostingView(rootView: TableViewerView(model: model))
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 560, height: 360)
        window.setFrameAutosaveName("TableViewerWindow")
        if !window.setFrameUsingName("TableViewerWindow") { window.center() }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.contentView = nil   // release the table
                self?.model = nil
            }
        }
        return window
    }
}
