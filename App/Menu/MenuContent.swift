import AppKit
import SwiftUI

/// Contents of the menu-bar menu. With `.menuBarExtraStyle(.menu)`, each `Button`
/// becomes an NSMenuItem, `Divider` a separator, and `Text` a grey label.
/// The main UI is the ⌘⇧V panel; this menu is the fallback entry point.
struct MenuContent: View {
    // Plain `let` is enough: because AppEnvironment is @Observable, SwiftUI tracks which
    // of its properties this body reads and re-renders when they change.
    let env: AppEnvironment

    var body: some View {
        Button("Open Clipboard History    ⌘⇧V") { env.showPanel() }

        Divider()

        if let error = env.storageError {
            Text(verbatim: error)
        }
        Text(verbatim: "\(env.totalClipCount) clips · \(env.lastEventDescription)")
        if !env.isAccessibilityTrusted {
            Button("Enable Auto-Paste…") { env.enableAutoPaste() }
        }

        Divider()

        Button("Clear History (keeps pinned)") { env.clearHistory() }
        Button("Quit Parseley") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
