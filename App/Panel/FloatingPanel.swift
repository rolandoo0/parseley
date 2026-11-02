import AppKit

/// A Spotlight-style floating window.
///
/// Why an `NSPanel` subclass rather than a SwiftUI `Window` scene:
/// - `.nonactivatingPanel` lets the panel take keyboard focus *without* activating
///   Parseley. The app you were typing in stays the active app, so after we close the
///   panel, a simulated ⌘V lands right back in it. A normal window would steal
///   activation and we'd have to hand it back.
/// - Panels can float above other apps' windows, appear over full-screen apps, and
///   aren't listed in ⌘Tab or the Window menu.
final class FloatingPanel: NSPanel {
    /// Called when the panel stops being the key window (e.g. you clicked elsewhere).
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // Show on whichever Space is current, including over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // `.titled` gives us rounded corners and a shadow; then we hide the title bar.
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false     // we reuse one panel for the app's lifetime
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 420, height: 320)
    }

    // Borderless/non-activating panels refuse key status by default, which would mean no
    // typing in the search field. Opt in.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
