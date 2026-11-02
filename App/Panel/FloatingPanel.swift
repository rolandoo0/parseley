import AppKit

/// A Spotlight-style floating window with a transparent, frosted "crystal" body.
///
/// Why an `NSPanel` subclass rather than a SwiftUI `Window` scene:
/// - `.nonactivatingPanel` lets the panel take keyboard focus *without* activating
///   Parseley. The app you were typing in stays the active app, so after we close the
///   panel, a simulated ⌘V lands right back in it. A normal window would steal
///   activation and we'd have to hand it back.
/// - Panels can float above other apps' windows, appear over full-screen apps, and
///   aren't listed in ⌘Tab or the Window menu.
///
/// The window itself is borderless and fully transparent; the rounded glass shape, blur
/// and glass rim are drawn by SwiftUI (CrystalBackground in Theme.swift). There's no
/// system shadow: on a transparent rounded window macOS renders it as a dark outline.
final class FloatingPanel: NSPanel {
    /// Called when the panel stops being the key window (e.g. you clicked elsewhere).
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // Show on whichever Space is current, including over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Transparent window: only what SwiftUI draws is visible.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // the system shadow shows as a dark outline; the glass rim replaces it
        // The crystal design is dark glass regardless of the system appearance.
        appearance = NSAppearance(named: .darkAqua)
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false     // we reuse one panel for the app's lifetime
        animationBehavior = .none        // we fade in ourselves (PanelController)
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
