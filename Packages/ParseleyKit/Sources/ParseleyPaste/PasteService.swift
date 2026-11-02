// macOS-only: synthetic key events and the Accessibility permission. On Linux this
// module compiles to nothing, which keeps `swift test` working there.
#if canImport(AppKit)
import AppKit
import ApplicationServices

/// The Accessibility permission ("Privacy & Security → Accessibility").
///
/// macOS requires it before an app may post keyboard events into other apps, which is
/// how we "press ⌘V" for the user. Without it, posted events are silently dropped.
/// There's no callback when the user grants it, so callers re-check `isTrusted` when
/// it matters (e.g. each time the panel opens).
public enum AccessibilityPermission {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog that offers to open System Settings (only if not yet
    /// trusted). macOS shows it at most once per app launch, however often you call this.
    /// Returns the current trust state (still false right after prompting).
    @discardableResult
    public static func requestWithSystemPrompt() -> Bool {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
        // Spelled out because that C global isn't concurrency-safe in Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings directly at the Accessibility list.
    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Pastes the current clipboard into another app by simulating ⌘V.
public final class PasteService {
    public enum Outcome: Equatable {
        case posted
        /// Accessibility isn't granted, so nothing was posted. The text is still on
        /// the clipboard; the user can press ⌘V themselves.
        case needsAccessibility
    }

    /// Virtual key code of the "V" key on an ANSI (US) keyboard.
    ///
    /// Key codes are physical positions, not letters. On layouts where that key isn't
    /// V (e.g. plain Dvorak), apps still usually map ⌘ shortcuts by QWERTY position, so
    /// this works in practice. Revisit if users report otherwise.
    private static let vKeyCode: CGKeyCode = 9

    public init() {}

    /// - Parameters:
    ///   - target: The app to paste into. If it isn't frontmost anymore, it's activated first.
    ///   - delay: Time to let focus return to the target window before posting. Our
    ///     panel has to finish closing first, or the keystroke would go to the panel.
    @discardableResult
    public func paste(into target: NSRunningApplication?, delay: TimeInterval = 0.05) -> Outcome {
        guard AccessibilityPermission.isTrusted else { return .needsAccessibility }

        var wait = delay
        if let target, !target.isActive, !target.isTerminated {
            target.activate()
            wait += 0.1   // activating another app takes a moment
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            Self.postCommandV()
        }
        return .posted
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        // Set flags explicitly to exactly ⌘, so modifiers the user may still be holding
        // (e.g. ⇧ from the ⌘⇧V hotkey) don't turn this into ⌘⇧V.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        // .cghidEventTap = inject as if it came from the hardware keyboard.
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
#endif
