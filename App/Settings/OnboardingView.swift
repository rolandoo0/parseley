import AppKit
import Combine
import KeyboardShortcuts
import Observation
import ParseleyCore
import ParseleyPaste
import ServiceManagement
import SwiftUI

// MARK: - Controllers

/// Live state of the interactive tour. AppEnvironment reports what the user does
/// (copies, opens the panel, starts a series…) via `record`; the view reacts.
@MainActor
@Observable
final class TourController {
    private(set) var tour = WelcomeTour()
    /// True for a moment after the step on screen was completed (the "done!" state).
    private(set) var celebrating = false
    @ObservationIgnored private var advanceTask: Task<Void, Never>?

    func record(_ event: WelcomeTour.Event) {
        guard tour.record(event) else { return }
        celebrating = true
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self.celebrating = false
                self.tour.advance()
            }
        }
    }

    func skip() { stopCelebrating(); tour.skip() }
    func next() { stopCelebrating(); tour.advance() }
    func back() { stopCelebrating(); tour.back() }
    func go(to step: WelcomeTour.Step) { stopCelebrating(); tour.go(to: step) }
    func finishEarly() { stopCelebrating(); tour.finish() }
    func reset() { stopCelebrating(); tour = WelcomeTour() }

    private func stopCelebrating() {
        advanceTask?.cancel()
        celebrating = false
    }
}

/// Opens the welcome tour on first launch, and from the menu ("Welcome Guide…").
@MainActor
final class OnboardingController {
    let guide = TourController()
    /// Set by AppEnvironment: the tour shows the live series total and can start one.
    weak var series: SeriesController?
    private var window: NSWindow?
    private static let completedKey = "onboarding.completed"

    var hasCompleted: Bool { UserDefaults.standard.bool(forKey: Self.completedKey) }
    /// AppEnvironment only reports tour events while the window is open.
    var isShowing: Bool { window?.isVisible ?? false }

    func showIfNeeded() {
        if !hasCompleted { show() }
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.title = "Parseley Tour"
            window.contentView = NSHostingView(rootView: GuideView(
                guide: guide, seriesProvider: { [weak self] in self?.series },
                onFinish: { [weak self] in self?.finish() }
            ))
            window.center()
            self.window = window
        }
        if !isShowing { guide.reset() }   // reopening starts the tour fresh
        // A menu-bar app isn't active by default; bring the window forward.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
    }
}

// MARK: - Guide window

private struct GuideView: View {
    let guide: TourController
    let seriesProvider: () -> SeriesController?
    let onFinish: () -> Void

    @State private var trusted = AccessibilityPermission.isTrusted
    /// macOS doesn't announce permission changes, so poll while the window is open.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            StepList(guide: guide)
                .frame(width: 236)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            Group {
                if let step = guide.tour.current {
                    StepPane(step: step, guide: guide, series: seriesProvider(), trusted: trusted)
                        .id(step)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity))
                } else {
                    FinishPane(guide: guide, onFinish: onFinish)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 540)
        .background(CrystalBackground(cornerRadius: 0))
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.3), value: guide.tour.current)
        .onAppear { checkPermission() }
        .onReceive(timer) { _ in checkPermission() }
    }

    private func checkPermission() {
        trusted = AccessibilityPermission.isTrusted
        if trusted { guide.record(.autoPasteEnabled) }
    }
}

// MARK: Sidebar

private struct StepList: View {
    let guide: TourController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parseley tour")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: "\(guide.tour.doneCount) of \(guide.tour.total) done")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.bottom, 10)

            ProgressBar(fraction: Double(guide.tour.doneCount) / Double(guide.tour.total))
                .padding(.bottom, 14)

            ForEach(WelcomeTour.Step.allCases, id: \.self) { step in
                StepRow(step: step, tour: guide.tour)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { guide.go(to: step) } }
            }
            Spacer()
            Button("Skip the tour") { withAnimation { guide.finishEarly() } }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 18)
        .background(Color.black.opacity(0.18))
    }
}

private struct StepRow: View {
    let step: WelcomeTour.Step
    let tour: WelcomeTour

    var body: some View {
        let isCurrent = tour.current == step
        HStack(spacing: 10) {
            ZStack {
                if tour.isDone(step) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                } else if tour.isSkipped(step) {
                    Image(systemName: "minus.circle").foregroundStyle(Theme.textTertiary)
                } else if isCurrent {
                    PulseDot(color: Theme.cyan)
                } else {
                    Text(verbatim: "\(step.rawValue + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 18)
            Text(step.title)
                .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Theme.textPrimary : (tour.isDone(step) ? Theme.textSecondary : Theme.textTertiary))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isCurrent ? Theme.glassFillHover : Color.clear))
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.glassFill)
                Capsule().fill(Theme.accentGradient)
                    .frame(width: max(6, geo.size.width * fraction))
                    .shadow(color: Theme.cyan.opacity(0.6), radius: 4)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

// MARK: Step pane

private struct StepPane: View {
    let step: WelcomeTour.Step
    let guide: TourController
    let series: SeriesController?
    let trusted: Bool

    private var done: Bool { guide.tour.isDone(step) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: "STEP \(step.rawValue + 1) OF \(guide.tour.total)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(Theme.cyan)
            Text(step.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(explanation)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            action
                .padding(.top, 4)

            Spacer(minLength: 0)
            status
            controls
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 24)
    }

    // MARK: Copy per step

    private var explanation: String {
        switch step {
        case .copyNumbers:
            "Parseley keeps everything you copy. Copy this little column, the way it would come out of a spreadsheet."
        case .openPanel:
            "Press your history shortcut from anywhere. Your copy is at the top, with its sum and stats already worked out."
        case .copyStat:
            "In the panel, click the Sum tile (or press ⌘1). The number is copied, ready to paste into a cell."
        case .startSeries:
            "A series adds up every number you copy, from any app. Press the shortcut: a small glass bar appears at the top of your screen."
        case .feedSeries:
            "Now copy a few numbers. Use the buttons below, or copy numbers from anywhere. Watch the total climb."
        case .commandBar:
            "Open the panel and type > followed by what you want: >sum, >sql, >new series… then press ⏎."
        case .saveTotal:
            "Press the series shortcut again to stop. The total is saved in your history as a Series total."
        case .autoPaste:
            "So ⏎ in the panel can paste straight into the app you're using, allow Parseley under Privacy & Security → Accessibility. It only uses this to press ⌘V for you."
        }
    }

    @ViewBuilder
    private var action: some View {
        switch step {
        case .copyNumbers:
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: WelcomeTour.sampleText)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(width: 220, alignment: .leading)
                    .glassCard(radius: 12)
                HStack(spacing: 10) {
                    Text("Select it and press ⌘C, or").foregroundStyle(Theme.textTertiary)
                    TourButton(title: "Copy it for me", icon: "doc.on.doc") { Self.copy(WelcomeTour.sampleText) }
                }
                .font(.system(size: 12.5))
            }
        case .openPanel:
            ShortcutDisplay(name: .togglePanel, fallback: "⌘⇧V")
        case .copyStat:
            HStack(spacing: 6) {
                ForEach(["Count", "Sum", "Average"], id: \.self) { label in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label.uppercased())
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded)).tracking(1.1)
                            .foregroundStyle(Theme.textTertiary)
                        Text(label == "Sum" ? "1,492.5" : (label == "Count" ? "3" : "497.5"))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(label == "Sum" ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textPrimary))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(width: 96, alignment: .leading)
                    .glassCard(radius: 10, highlighted: label == "Sum")
                }
                Text("← click Sum in the real panel")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 6)
            }
        case .startSeries:
            ShortcutDisplay(name: .toggleSeries, fallback: "⌃⌥⌘T")
        case .feedSeries:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(WelcomeTour.seriesSamples, id: \.self) { value in
                        TourButton(title: "Copy \(value)", icon: "plus") { Self.copy(value) }
                    }
                }
                if let series, series.isActive {
                    HStack(spacing: 10) {
                        PulseDot(color: Theme.cyan)
                        Text(verbatim: "Σ \(series.sumItem?.display ?? "0")")
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.accentGradient)
                        Text(verbatim: "\(series.stats?.count ?? 0) values")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentTransition(.numericText())
                    .animation(.easeOut, value: series.stats?.count)
                } else {
                    HStack(spacing: 10) {
                        Text("No series is running yet.").foregroundStyle(Theme.textTertiary)
                        TourButton(title: "Start one now", icon: "play.fill") { series?.toggle() }
                    }
                    .font(.system(size: 12.5))
                }
            }
        case .commandBar:
            HStack(spacing: 8) {
                ForEach([">sum", ">sql", ">new series", ">fin"], id: \.self) { example in
                    Text(verbatim: example)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.cyan)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassCard(radius: 8)
                }
            }
        case .saveTotal:
            VStack(alignment: .leading, spacing: 10) {
                ShortcutDisplay(name: .toggleSeries, fallback: "⌃⌥⌘T")
                if let series, !series.isActive, !done {
                    Text("No series is running. Start one (step 4), copy a number, then stop it here.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
        case .autoPaste:
            if !trusted {
                TourButton(title: "Open System Settings", icon: "gearshape") {
                    AccessibilityPermission.requestWithSystemPrompt()
                    AccessibilityPermission.openSystemSettings()
                }
            }
        }
    }

    // MARK: Status & controls

    private var status: some View {
        HStack(spacing: 10) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.mint)
                    .shadow(color: Theme.mint.opacity(0.7), radius: 8)
                Text(guide.celebrating ? "Nice, that's it!" : "Done")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.mint)
            } else {
                PulseDot(color: Theme.amber)
                Text(waitingText)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 12, highlighted: done)
        .animation(.spring(duration: 0.35), value: done)
    }

    private var waitingText: String {
        switch step {
        case .copyNumbers: "Waiting for you to copy…"
        case .openPanel: "Waiting for the panel to open…"
        case .copyStat: "Waiting for you to copy a stat…"
        case .startSeries: "Waiting for a series to start…"
        case .feedSeries: "Copy three numbers…"
        case .commandBar: "Waiting for a command…"
        case .saveTotal: "Waiting for the series to stop…"
        case .autoPaste: "Waiting for permission (this updates by itself)…"
        }
    }

    private var controls: some View {
        HStack {
            if step.rawValue > 0 {
                Button("Back") { withAnimation { guide.back() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !done {
                Button("Skip") { withAnimation { guide.skip() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.trailing, 8)
            }
            Button {
                withAnimation { guide.next() }
            } label: {
                Text(done ? "Continue" : "Next")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.accentGradient))
            }
            .buttonStyle(.plain)
            .opacity(done ? 1 : 0.55)
        }
        .font(.system(size: 13))
    }

    /// A real copy, exactly as if the user pressed ⌘C, so Parseley captures it.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: Finish

private struct FinishPane: View {
    let guide: TourController
    let onFinish: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accentGradient)
                .shadow(color: Theme.cyan.opacity(0.6), radius: 12)
            Text("You're all set")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(verbatim: "\(guide.tour.doneCount) of \(guide.tour.total) steps done. A few more things to explore when you're ready:")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                card("square.stack.3d.up", "Modes", "Adapts to the app you're in: Finance in Excel, SQL in your database tool.")
                card("wand.and.stars", "Recipes", "Save chains of transforms in Settings → Recipes.")
                card("list.number", "Paste queue", "⌘-click clips → Queue, then ⌃⌥⌘V pastes them one by one.")
                card("terminal", "Terminal & Claude", "`parseley sum`, `parseley sql`, and an MCP server for Claude.")
            }

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

            Spacer(minLength: 0)
            HStack {
                Button("Back") { withAnimation { guide.back() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("Reopen any time: menu bar → Welcome Guide…")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Button(action: onFinish) {
                    Text("Start using Parseley")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 24)
    }

    private func card(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(Theme.accentGradient)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .glassCard(radius: 12)
    }
}

// MARK: Pieces

/// The user's current shortcut, drawn as big keycaps (follows any rebinding).
private struct ShortcutDisplay: View {
    let name: KeyboardShortcuts.Name
    let fallback: String

    var body: some View {
        let text = KeyboardShortcuts.getShortcut(for: name)?.description ?? fallback
        HStack(spacing: 6) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.accentGradientSoft, lineWidth: 1))
                    .shadow(color: Theme.cyan.opacity(0.25), radius: 8)
            }
        }
    }
}

private struct TourButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(hovering ? Theme.glassFillHover : Theme.glassFill))
                .overlay(Capsule().strokeBorder(hovering ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.hairline), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
