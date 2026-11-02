import AppKit
import ParseleyCore
import SwiftUI

/// Contents of the menu-bar menu. With `.menuBarExtraStyle(.menu)`, each `Button`
/// becomes an NSMenuItem, `Divider` a separator, `Text` a grey label and `Menu` a submenu.
/// The main UI is the ⌘⇧V panel and the series bar; this menu is the fallback entry point.
struct MenuContent: View {
    // Plain `let` is enough: because AppEnvironment / SeriesController are @Observable,
    // SwiftUI tracks which properties this body reads and re-renders when they change.
    let env: AppEnvironment

    var body: some View {
        Button("Open Clipboard History    ⌘⇧V") { env.showPanel() }

        Divider()

        seriesSection

        Divider()

        if let error = env.storageError {
            Text(verbatim: error)
        }
        Text(verbatim: "\(env.totalClipCount) clips · \(env.lastEventDescription)")
        if !env.isAccessibilityTrusted {
            Button("Enable Auto-Paste…") { env.enableAutoPaste() }
        }

        Divider()

        // Opens the SwiftUI `Settings` scene (macOS 14+).
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Parseley") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var seriesSection: some View {
        let series = env.series
        if let active = series.active {
            Text(verbatim: "● \(active.name) · Σ \(series.sumItem?.display ?? "0") · \(series.stats?.count ?? 0) values")
            Button("Copy Total") { series.copySum() }
            Button("New Series    ⌃⌥⌘N") { series.startNew() }
            Button("Stop Series    ⌃⌥⌘T") { series.stop() }
        } else {
            Button("Start Series    ⌃⌥⌘T") { series.toggle() }
        }

        let past = series.recent.filter { $0.endedAt != nil }
        if !past.isEmpty {
            Menu("Recent Series") {
                ForEach(past) { item in
                    Button(recentTitle(item)) { series.copySum(of: item) }
                }
                Divider()
                Text("Click a series to copy its total")
            }
        }
    }

    private func recentTitle(_ series: Series) -> String {
        let total = series.stats?.items.first { $0.label == "Sum" }?.display ?? "0"
        let date = series.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(series.name) · Σ \(total) · \(date)"
    }
}
