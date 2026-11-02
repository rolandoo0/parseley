import KeyboardShortcuts

// KeyboardShortcuts (by Sindre Sorhus) registers system-wide hotkeys and stores the
// user's choice in UserDefaults. Each shortcut is a named slot with a default; users
// can rebind them in Settings (KeyboardShortcuts.Recorder).
extension KeyboardShortcuts.Name {
    /// Opens/closes the history panel. Default ⌘⇧V.
    ///
    /// Note: a global hotkey takes precedence over app shortcuts, so this replaces
    /// "Paste and Match Style" (also ⌘⇧V) in apps like Pages, Mail and Slack while
    /// Parseley is running. Users can rebind it in Settings.
    static let togglePanel = Self("togglePanel", default: .init(.v, modifiers: [.command, .shift]))

    /// Starts a series, or stops the running one. Default ⌃⌥⌘T ("tally").
    static let toggleSeries = Self("toggleSeries", default: .init(.t, modifiers: [.control, .option, .command]))

    /// Ends the running series and starts a fresh one. Default ⌃⌥⌘N.
    static let newSeries = Self("newSeries", default: .init(.n, modifiers: [.control, .option, .command]))

    /// Copies the running series' total (or the last series' total). Default ⌃⌥⌘C.
    static let copySeriesTotal = Self("copySeriesTotal", default: .init(.c, modifiers: [.control, .option, .command]))
}
