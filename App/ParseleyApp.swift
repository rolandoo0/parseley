import SwiftUI

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
        MenuBarExtra("Parseley", systemImage: "list.clipboard") {
            MenuContent(env: env)
        }
        // `.menu` renders the content as a native NSMenu (Buttons become menu items).
        // In M2 the real UI is the floating panel; this menu stays as a lightweight entry point.
        .menuBarExtraStyle(.menu)
    }
}
