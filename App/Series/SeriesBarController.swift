import AppKit
import SwiftUI

/// Small floating glass window for the running series. Like the history panel it never
/// activates Parseley, so clicking it doesn't pull focus from the app you're copying from.
final class SeriesBarPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        isMovableByWindowBackground = true   // drag it anywhere by its background
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Only take keyboard focus when a control needs it (the rename field). Plain
        // button clicks leave focus where it was.
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows/hides the series bar, sizes it for collapsed/expanded, and remembers where
/// the user dragged it.
@MainActor
final class SeriesBarController {
    static let width: CGFloat = 400
    static let collapsedHeight: CGFloat = 50
    static let expandedHeight: CGFloat = 470

    private let panel: SeriesBarPanel
    private let series: SeriesController
    private var moveObserver: NSObjectProtocol?
    private static let positionKey = "seriesBar.topLeft"

    init(series: SeriesController) {
        self.series = series
        panel = SeriesBarPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.collapsedHeight))
        panel.contentView = NSHostingView(rootView: SeriesBarView(series: series))

        series.onExpandedChanged = { [weak self] expanded in self?.resize(expanded: expanded) }

        // Remember the position after the user drags the bar.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // `queue: .main` delivers on the main thread; tell the compiler so.
            MainActor.assumeIsolated { self?.savePosition() }
        }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            guard !panel.isVisible else { return }
            resize(expanded: series.isExpanded, animate: false)
            placeTopLeft(savedPosition() ?? defaultTopLeft())
            panel.alphaValue = 0
            panel.orderFrontRegardless()   // show without activating Parseley
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self.panel.animator().alphaValue = 1
            }
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Size & position

    /// Grows/shrinks downward from the top edge (window origins are bottom-left, so we
    /// keep the top fixed by moving the origin).
    private func resize(expanded: Bool, animate: Bool = true) {
        let height = expanded ? Self.expandedHeight : Self.collapsedHeight
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: Self.width, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: true, animate: animate && panel.isVisible)
        panel.invalidateShadow()
    }

    private func placeTopLeft(_ point: NSPoint) {
        var frame = panel.frame
        frame.origin = NSPoint(x: point.x, y: point.y - frame.height)
        // Keep it on a screen even if displays changed since last time.
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
    }

    /// Top-center of the main screen, just under the menu bar.
    private func defaultTopLeft() -> NSPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return NSPoint(x: 200, y: 800) }
        return NSPoint(x: visible.midX - Self.width / 2, y: visible.maxY - 8)
    }

    private func savePosition() {
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.positionKey)
    }

    private func savedPosition() -> NSPoint? {
        UserDefaults.standard.string(forKey: Self.positionKey).map(NSPointFromString)
    }
}
