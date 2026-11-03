import AppKit
import AVFoundation
import AVKit

/// Plays the feature tour (Resources/ParseleyTour.mp4) in its own window, using AppKit's
/// AVPlayerView: the same player as QuickTime, with play/pause, scrubbing, volume and
/// full screen. If the file can't be played for any reason, it opens in the default
/// video app instead, so the tour is always watchable.
@MainActor
final class TourVideoController: NSObject, NSWindowDelegate {
    static let shared = TourVideoController()

    static var videoURL: URL? { Bundle.main.url(forResource: "ParseleyTour", withExtension: "mp4") }

    private var window: NSWindow?
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?

    func show() {
        guard let url = Self.videoURL else {
            let alert = NSAlert()
            alert.messageText = "The tour video is missing from this copy of Parseley"
            alert.informativeText = "Reinstall Parseley, or watch it in the repository: App/Resources/ParseleyTour.mp4."
            alert.runModal()
            return
        }

        let window = self.window ?? makeWindow()
        self.window = window

        let player = AVPlayer(url: url)
        self.player = player
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        window.contentView = view

        // If AVFoundation can't load the item, hand the file to QuickTime (or whatever
        // the default video app is).
        statusObservation = player.currentItem?.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in TourVideoController.shared.openInDefaultPlayer(url) }
        }

        // A menu-bar app isn't active by default; bring the window forward.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        player.play()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Parseley Tour"
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)   // the video is 1280×720
        window.collectionBehavior = [.fullScreenPrimary]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.delegate = self
        window.center()
        return window
    }

    private func openInDefaultPlayer(_ url: URL) {
        stop()
        window?.close()
        NSWorkspace.shared.open(url)
    }

    private func stop() {
        player?.pause()
        statusObservation = nil
        window?.contentView = nil   // releases the player and its decoder
        player = nil
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }
}
