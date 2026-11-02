import AppKit
import Observation
import ParseleyCore
import SwiftUI

/// Knows which mode is active: follows the frontmost app (unless a mode is locked by
/// hand) and stores the user's mode library in UserDefaults as JSON.
@MainActor
@Observable
final class ModeController {
    private(set) var library: ModeLibrary { didSet { saveLibrary() } }
    /// A mode chosen by hand, overriding the automatic choice. Nil = automatic.
    var manualModeID: String? {
        didSet { UserDefaults.standard.set(manualModeID, forKey: Key.manual) }
    }
    /// The last app (other than Parseley) that came to the front.
    private(set) var frontmostBundleID: String?

    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    private enum Key {
        static let library = "modes.library"
        static let manual = "modes.manualModeID"
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Key.library),
           let saved = try? JSONDecoder().decode(ModeLibrary.self, from: data) {
            library = saved
        } else {
            library = ModeLibrary()
        }
        manualModeID = UserDefaults.standard.string(forKey: Key.manual)
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // NSWorkspace posts this whenever another app comes to the front.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            // `queue: .main` delivers on the main thread; tell the compiler so.
            MainActor.assumeIsolated {
                // Ignore Parseley itself (Settings window), so the mode stays that of
                // the app you were working in.
                guard let self, bundleID != Bundle.main.bundleIdentifier else { return }
                self.frontmostBundleID = bundleID
            }
        }
    }

    // MARK: - Resolving

    /// The mode in effect right now.
    var current: Mode {
        library.resolve(app: frontmostBundleID, manualModeID: manualModeID)
    }

    /// The mode for a copy made in `bundleID` (a manual lock applies to all apps).
    func mode(forSource bundleID: String?) -> Mode {
        library.resolve(app: bundleID, manualModeID: manualModeID)
    }

    var isAutomatic: Bool { manualModeID == nil }

    // MARK: - Editing

    func update(_ mode: Mode) { library.upsert(mode) }

    func remove(id: String) {
        library.remove(id: id)
        if manualModeID == id { manualModeID = nil }
    }

    func assign(app bundleID: String, to modeID: String) {
        library.assign(app: bundleID, to: modeID)
    }

    func resetBuiltIns() { library.resetBuiltIns() }

    /// Creates a new custom mode and returns it.
    @discardableResult
    func addCustomMode() -> Mode {
        let mode = Mode(id: UUID().uuidString, name: "New Mode", icon: "star")
        library.upsert(mode)
        return mode
    }

    /// A two-way binding to one mode, for editors in Settings.
    func binding(for id: String) -> Binding<Mode> {
        Binding(
            get: { [weak self] in self?.library.mode(id: id) ?? .general },
            set: { [weak self] in self?.library.upsert($0) }
        )
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: Key.library)
        }
    }
}
