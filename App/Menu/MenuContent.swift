import AppKit
import ParseleyCore
import SwiftUI

/// Contents of the menu-bar menu. With `.menuBarExtraStyle(.menu)`, each `Button`
/// becomes an NSMenuItem, `Divider` a separator, and disabled `Text` a grey label.
struct MenuContent: View {
    // Plain `let` is enough: because AppEnvironment is @Observable, SwiftUI tracks which
    // of its properties this body reads and re-renders when they change.
    let env: AppEnvironment

    var body: some View {
        if let error = env.storageError {
            Text(verbatim: error)
        }
        Text(verbatim: env.lastEventDescription)

        Divider()

        if env.recentClips.isEmpty {
            Text("No clips yet. Copy some text.")
        } else {
            Text("Recent (\(env.totalClipCount) total), click to copy")
            ForEach(env.recentClips) { clip in
                Button {
                    env.copy(clip)
                } label: {
                    // `verbatim:` shows clip text as-is (no Markdown or localization lookup).
                    Text(verbatim: "\(clip.isPinned ? "📌 " : "")\(Self.preview(clip.content))  ·  \(clip.kind.displayName)")
                }
            }
        }

        Divider()

        Button("Clear History (keeps pinned)") { env.clearHistory() }
        Button("Quit Parseley") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// First non-blank line, whitespace-collapsed, truncated to fit a menu item.
    static func preview(_ content: String, maxLength: Int = 60) -> String {
        let firstLine = content
            .split(whereSeparator: \.isNewline)
            .first { !$0.allSatisfy(\.isWhitespace) }
            .map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lineCount = content.split(whereSeparator: \.isNewline).count
        var result = collapsed.count > maxLength ? String(collapsed.prefix(maxLength)) + "…" : collapsed
        if lineCount > 1 { result += "  (+\(lineCount - 1) lines)" }
        return result
    }
}
