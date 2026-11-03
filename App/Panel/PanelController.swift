import AppKit
import Carbon.HIToolbox   // kVK_* virtual key code constants
import ParseleyCore
import SwiftUI

/// Owns the history panel: showing it near the cursor, hiding it, and routing keys.
@MainActor
final class PanelController {
    private let panel: FloatingPanel
    private let model: HistoryPanelModel
    private var keyMonitor: Any?
    private var isShown = false
    /// Called each time the panel opens (the welcome tour listens).
    var onShow: (() -> Void)?
    /// The app that was frontmost when the panel opened: where Enter will paste.
    private var previousApp: NSRunningApplication?

    init(model: HistoryPanelModel) {
        self.model = model
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Theme.panelSize))
        // NSHostingView is the bridge that puts a SwiftUI view tree inside an AppKit window.
        panel.contentView = NSHostingView(rootView: HistoryView(model: model))

        panel.onResignKey = { [weak self] in
            // Quick Look takes focus while previewing; keep the panel open behind it.
            guard !QuickLookController.shared.isVisible else { return }
            self?.hide()
        }
        model.closePanel = { [weak self] in self?.hide() }
        model.pasteTarget = { [weak self] in self?.previousApp }
    }

    var isVisible: Bool { isShown }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        guard !isShown else { return }
        isShown = true

        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        model.prepareForShow()
        positionNearCursor()
        // Becomes key (gets keyboard input) without activating Parseley. See FloatingPanel.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // Quick fade-in. `animator()` is AppKit's way of animating a property change.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            self.panel.animator().alphaValue = 1
        }
        installKeyMonitor()
        onShow?()
    }

    func hide() {
        // Guard against re-entry: orderOut triggers resignKey, which calls hide() again.
        guard isShown else { return }
        isShown = false
        removeKeyMonitor()
        QuickLookController.shared.close()
        panel.orderOut(nil)
        model.releaseMemory()   // don't hold rows or clip text while hidden
    }

    // MARK: - Placement

    private func positionNearCursor() {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = PanelPlacement.frame(size: panel.frame.size, cursor: cursor, visibleFrame: visible)
        panel.setFrame(frame, display: false)
    }

    // MARK: - Keyboard

    /// A *local* event monitor sees key presses aimed at our own windows before the
    /// focused control does. We use it so ↑/↓/↩/esc drive the list even though the
    /// search field has focus. (A text field would otherwise swallow ↑/↓ to move its
    /// caret.) Returning nil consumes the event; returning it lets it through to the
    /// text field (normal typing).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // The handler runs on the main thread, like the rest of this class.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Number-row keys 1–6 → stat tile index. (Virtual key codes aren't in order.)
    private static let statKeys: [Int: Int] = [
        kVK_ANSI_1: 0, kVK_ANSI_2: 1, kVK_ANSI_3: 2, kVK_ANSI_4: 3, kVK_ANSI_5: 4, kVK_ANSI_6: 5,
    ]

    /// Returns true if the key was handled (and should not reach the text field).
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            model.moveSelection(by: 1)
        case kVK_UpArrow:
            model.moveSelection(by: -1)
        case kVK_PageDown:
            model.moveSelection(by: 10)
        case kVK_PageUp:
            model.moveSelection(by: -10)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.activate(mode: modifiers == .command ? .copyOnly : .paste)
        case kVK_Escape:
            // Esc closes Quick Look or the snippet form first; then clears the search /
            // leaves the command bar; the next one closes the panel.
            if QuickLookController.shared.isVisible { QuickLookController.shared.close() }
            else if model.pendingSnippet != nil { model.cancelSnippet() }
            else if model.query.isEmpty { hide() } else { model.query = "" }
        case kVK_Space where modifiers.isEmpty && model.query.isEmpty && model.pendingSnippet == nil:
            // Space with nothing typed: Quick Look, like in Finder.
            QuickLookController.shared.isVisible ? QuickLookController.shared.close() : model.quickLookSelection()
        case kVK_ANSI_Y where modifiers == .command && model.pendingSnippet == nil:   // ⌘Y
            QuickLookController.shared.isVisible ? QuickLookController.shared.close() : model.quickLookSelection()
        case kVK_ANSI_T where modifiers == .command && !model.isCommandMode && model.pendingSnippet == nil:   // ⌘T
            model.openTableSelection()
        case kVK_Delete where modifiers == .command && !model.isCommandMode:   // ⌘⌫
            model.deleteSelected()
        case kVK_ANSI_P where modifiers == .command && !model.isCommandMode:   // ⌘P
            model.togglePin()
        case kVK_ANSI_J where modifiers == .command && !model.isCommandMode:   // ⌘J
            model.visualizeSelection()
        case let code where modifiers == .command && Self.statKeys.keys.contains(code):  // ⌘1–⌘6
            model.copyStat(at: Self.statKeys[code] ?? 0)
        default:
            return false
        }
        return true
    }
}
