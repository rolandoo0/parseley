import AppKit
import SwiftUI

/// A small glass message that appears briefly at the top of the screen, for things that
/// happen while no Parseley window is open ("Recipe applied", "Queue: 2 of 5").
/// It never takes focus or activates Parseley.
@MainActor
final class ToastController {
    private let panel: NSPanel
    private let model = ToastModel()
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true   // purely informational; clicks pass through
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: ToastView(model: model))
    }

    func show(_ message: String, icon: String = "checkmark.circle.fill", duration: TimeInterval = 1.8) {
        model.message = message
        model.icon = icon
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - panel.frame.height - 10))
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.panel.animator().alphaValue = 1
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // Completion handlers run on the main thread.
                MainActor.assumeIsolated { self?.panel.orderOut(nil) }
            })
        }
    }
}

@MainActor
@Observable
final class ToastModel {
    var message = ""
    var icon = "checkmark.circle.fill"
}

private struct ToastView: View {
    let model: ToastModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.icon)
                .foregroundStyle(Theme.accentGradient)
            Text(verbatim: model.message)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CrystalBackground(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}
