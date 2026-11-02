// macOS-only: synthetic key events and the Accessibility permission. On Linux this
// module compiles to nothing, which keeps `swift test` working there.
#if canImport(AppKit)
import AppKit
import ApplicationServices
import Carbon.HIToolbox   // IsSecureEventInputEnabled, kVK_ANSI_V
import os

/// Log messages show up in Xcode's console and in Console.app (filter: "parseley").
let pasteLog = Logger(subsystem: "parseley", category: "paste")

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

    /// Time for our panel to finish closing and for keyboard focus to return to the
    /// target window before we "press" ⌘V. Too short and the keystroke can be lost.
    private static let focusDelay: TimeInterval = 0.15
    /// Extra time allowed for the target app to become active, if it wasn't already.
    private static let activationTimeout: TimeInterval = 0.6

    public init() {}

    /// - Parameter target: The app to paste into (the one that was frontmost when the
    ///   panel opened). If it isn't active anymore, it's activated first.
    @discardableResult
    public func paste(into target: NSRunningApplication?) -> Outcome {
        guard AccessibilityPermission.isTrusted else {
            pasteLog.notice("Not pasting: Accessibility permission not granted")
            return .needsAccessibility
        }

        let name = target?.localizedName ?? "nil"
        pasteLog.notice("Paste requested → target: \(name, privacy: .public), active: \(target?.isActive ?? false)")

        if let target, !target.isActive, !target.isTerminated {
            target.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusDelay) {
            Self.postWhenActive(target, deadline: Date().addingTimeInterval(Self.activationTimeout))
        }
        return .posted
    }

    /// Waits (briefly) until the target app is frontmost, then posts ⌘V.
    private static func postWhenActive(_ target: NSRunningApplication?, deadline: Date) {
        if let target, !target.isActive, Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                postWhenActive(target, deadline: deadline)
            }
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
        if IsSecureEventInputEnabled() {
            // Some app has "secure input" on (a focused password field, or Terminal's
            // "Secure Keyboard Entry"). macOS then blocks synthetic keystrokes.
            pasteLog.error("Secure Event Input is ON: macOS will block the simulated ⌘V. Frontmost: \(frontmost, privacy: .public)")
        }
        pasteLog.notice("Posting ⌘V. Frontmost app: \(frontmost, privacy: .public)")
        postCommandV()
    }

    private static func postCommandV() {
        let vKey = CGKeyCode(kVK_ANSI_V)
        // Device-independent ⌘ flag plus the "left ⌘ key" device bit (0x08). Some apps
        // (notably Electron-based ones like Slack/VS Code) ignore ⌘ without the device bit.
        let commandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)

        let source = CGEventSource(stateID: .combinedSessionState)
        // While our synthetic keys are delivered, ignore keys the user is physically
        // still holding (e.g. ↩ from selecting the clip), so they don't mix in.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            pasteLog.error("Couldn't create keyboard events")
            return
        }
        // Set flags explicitly to exactly ⌘, so modifiers the user may still be holding
        // (e.g. ⇧ from the ⌘⇧V hotkey) don't turn this into ⌘⇧V.
        down.flags = commandFlags
        up.flags = commandFlags
        // Session tap = deliver to the frontmost app as if typed by the user.
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
#endif
