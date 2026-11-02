import KeyboardShortcuts

// KeyboardShortcuts (by Sindre Sorhus) registers system-wide hotkeys and stores the
// user's choice in UserDefaults. Each shortcut is a named slot with a default; M4 adds
// a recorder in Settings so users can rebind it.
extension KeyboardShortcuts.Name {
    /// Opens/closes the history panel. Default ⌘⇧V.
    ///
    /// Note: a global hotkey takes precedence over app shortcuts, so this replaces
    /// "Paste and Match Style" (also ⌘⇧V) in apps like Pages, Mail and Slack while
    /// Parseley is running. Users can rebind it in Settings (M4).
    static let togglePanel = Self("togglePanel", default: .init(.v, modifiers: [.command, .shift]))
}
