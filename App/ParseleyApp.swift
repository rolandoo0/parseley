import SwiftUI
import ParseleyCore

/// App entry point.
///
/// SwiftUI pattern notes:
/// - `@main` + `App` replaces the old AppDelegate/main.swift boilerplate.
/// - `MenuBarExtra` is the SwiftUI way to put an item in the menu bar (macOS 13+).
///   Combined with `LSUIElement = YES` in Info.plist (set in project.yml) the app has
///   no Dock icon and no main window: it lives only in the menu bar.
/// - `@State` on the App struct creates `AppEnvironment` exactly once at launch and keeps
///   it alive for the app's lifetime, so clipboard capture starts immediately rather
///   than when the menu is first opened.
@main
struct ParseleyApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(env: env)
        } label: {
            // The icon follows the active mode (Finance shows $, SQL a database…). The
            // General mode shows Parseley's own glyph, the clipboard with a sprout
            // (a template image, so macOS colors it for light/dark menu bars).
            if env.modes.current.id == Mode.generalID {
                Image("MenuBarIcon")
            } else {
                Image(systemName: env.modes.current.icon)
            }
        }
        // `.menu` renders the content as a native NSMenu (Buttons become menu items).
        .menuBarExtraStyle(.menu)

        // The Settings window (opened from the menu's "Settings…").
        Settings {
            SettingsView(settings: env.settings, env: env)
        }
    }
}
