import AppKit
import Combine
import KeyboardShortcuts
import ParseleyPaste
import ServiceManagement
import SwiftUI

/// Shows the welcome guide on first launch (and from the menu: "Welcome Guide…").
@MainActor
final class OnboardingController {
    private var window: NSWindow?
    private static let completedKey = "onboarding.completed"

    var hasCompleted: Bool { UserDefaults.standard.bool(forKey: Self.completedKey) }

    func showIfNeeded() {
        if !hasCompleted { show() }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in self?.finish() })
        window.center()
        self.window = window
        // A menu-bar app isn't active by default; bring the window forward.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
        window = nil
    }
}

private struct OnboardingView: View {
    let onDone: () -> Void
    @State private var page = 0
    @State private var trusted = AccessibilityPermission.isTrusted
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Polls the permission while this window is open (macOS doesn't notify us).
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: autoPaste
                default: finishPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule()
                            .fill(i == page ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.hairline))
                            .frame(width: i == page ? 22 : 8, height: 6)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                }
                Button {
                    if page < 2 { withAnimation { page += 1 } } else { onDone() }
                } label: {
                    Text(page < 2 ? "Continue" : "Start using Parseley")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(width: 560, height: 470)
        .background(CrystalBackground(cornerRadius: 0))
        .environment(\.colorScheme, .dark)
        .onReceive(timer) { _ in trusted = AccessibilityPermission.isTrusted }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
            Text("Welcome to Parseley")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Copy as usual. Parseley keeps your clipboard history and does the math on anything with numbers. Everything stays on this Mac.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            row("magnifyingglass", "Open your history anywhere", "Search, then ⏎ pastes into the app you're in.")
            HStack {
                Text("Shortcut:").foregroundStyle(Theme.textSecondary)
                KeyboardShortcuts.Recorder(for: .togglePanel)
            }
            Spacer()
        }
    }

    private var autoPaste: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: trusted ? "checkmark.seal.fill" : "hand.raised.fill")
                .font(.system(size: 44))
                .foregroundStyle(trusted ? AnyShapeStyle(Theme.mint) : AnyShapeStyle(Theme.accentGradient))
            Text(trusted ? "Auto-paste is on" : "Let Parseley paste for you")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("To paste a clip straight into the app you're using, macOS needs you to allow Parseley under Privacy & Security → Accessibility. Parseley only uses it to press ⌘V for you.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !trusted {
                Button {
                    AccessibilityPermission.requestWithSystemPrompt()
                    AccessibilityPermission.openSystemSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.glassFillHover))
                        .overlay(Capsule().strokeBorder(Theme.accentGradientSoft, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                Text("Switch Parseley on in the list; this page updates by itself. You can also skip this: ⏎ then just copies, and you press ⌘V.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Numbers, handled")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            row("sum", "Series", "⌃⌥⌘T starts a running total of every number you copy. Totals are kept in your history.")
            row("square.stack.3d.up", "Modes", "Parseley adapts to the app you're in: Finance in Excel, SQL in your database tool.")
            row("command", "Command bar", "Type > in the history panel: >sql, >sum, >new series…")
            row("list.number", "Paste queue", "Select several clips, Queue, then ⌃⌥⌘V pastes them one by one.")
            Toggle("Launch Parseley at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .foregroundStyle(Theme.textSecondary)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
        }
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
