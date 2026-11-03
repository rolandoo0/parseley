import AppKit
import ServiceManagement

/// Settings → General → "Uninstall Parseley…": removes everything Parseley put on this Mac
/// and quits. Mirrors scripts/uninstall.sh (for when the app won't open).
@MainActor
enum Uninstaller {
    /// Where the history database lives (the same folder the CLI reads).
    static var dataFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Parseley", isDirectory: true)
    }

    /// Asks for confirmation (with a "delete my history" checkbox), then uninstalls.
    static func confirmAndUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Parseley?"
        alert.informativeText = """
        This moves Parseley to the Trash and removes the parseley command, its settings, \
        the login item and its Accessibility permission. Parseley then quits.
        """
        let deleteData = NSButton(checkboxWithTitle: "Also delete my clipboard history", target: nil, action: nil)
        deleteData.state = .off
        alert.accessoryView = deleteData
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        uninstall(deleteHistory: deleteData.state == .on)
    }

    static func uninstall(deleteHistory: Bool) {
        let fm = FileManager.default
        var leftovers: [String] = []

        // Login item and Accessibility permission.
        try? SMAppService.mainApp.unregister()
        if let bundleID = Bundle.main.bundleIdentifier {
            run("/usr/bin/tccutil", ["reset", "Accessibility", bundleID])
        }

        // The command-line tool, wherever the installer put it.
        for path in ["/usr/local/bin/parseley", "\(NSHomeDirectory())/.local/bin/parseley"] where fm.fileExists(atPath: path) {
            if (try? fm.removeItem(atPath: path)) == nil { leftovers.append(path) }
        }

        // History (only if asked).
        if deleteHistory, fm.fileExists(atPath: dataFolder.path) {
            if (try? fm.removeItem(at: dataFolder)) == nil { leftovers.append(dataFolder.path) }
        }

        // Settings and caches. The preferences daemon caches defaults, so ask it to forget.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            run("/usr/bin/defaults", ["delete", bundleID])
            let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
            for relative in ["Caches/\(bundleID)", "HTTPStorages/\(bundleID)", "Saved Application State/\(bundleID).savedState"] {
                try? fm.removeItem(at: library.appendingPathComponent(relative))
            }
        }

        // The app itself: to the Trash, so it can be restored if this was a mistake.
        let appURL = Bundle.main.bundleURL
        let removedSoFar = leftovers
        NSWorkspace.shared.recycle([appURL]) { _, error in
            let failed = error != nil
            Task { @MainActor in
                finish(leftovers: removedSoFar + (failed ? [appURL.path] : []), keptHistory: !deleteHistory)
            }
        }
    }

    private static func finish(leftovers: [String], keptHistory: Bool) {
        let alert = NSAlert()
        if leftovers.isEmpty {
            alert.messageText = "Parseley is uninstalled"
            alert.informativeText = keptHistory
                ? "Your clipboard history is still in ~/Library/Application Support/Parseley. Delete that folder to remove it."
                : "Everything has been removed. Thanks for trying Parseley."
        } else {
            alert.messageText = "Parseley is mostly uninstalled"
            alert.informativeText = "These couldn't be removed (delete them in Finder):\n" + leftovers.joined(separator: "\n")
        }
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
