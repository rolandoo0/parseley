import ParseleyCore
import SwiftUI

/// The floating series bar. Collapsed: a glass pill with the live total. Expanded: the
/// "start a new series?" prompt, stats, every copy in the series, and actions.
struct SeriesBarView: View {
    let series: SeriesController

    var body: some View {
        VStack(spacing: 0) {
            pill
            if series.isExpanded, let active = series.active {
                expanded(active)
            }
        }
        .frame(width: SeriesBarController.width,
               height: series.isExpanded ? SeriesBarController.expandedHeight : SeriesBarController.collapsedHeight,
               alignment: .top)
        .background(CrystalBackground(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.18), value: series.toast)
    }

    // MARK: - Collapsed pill

    private var pill: some View {
        HStack(spacing: 10) {
            PulseDot(color: series.prompt == nil ? Theme.cyan : Theme.amber)

            Text(verbatim: series.active?.name ?? "Series")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let toast = series.toast {
                Text(verbatim: toast)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.mint)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                Text(verbatim: "\(series.stats?.count ?? 0) values")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Button {
                    series.copySum()
                } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: "Σ").foregroundStyle(Theme.cyan)
                        Text(verbatim: series.sumItem?.display ?? "0").foregroundStyle(Theme.numberEmphasis)
                    }
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
                .buttonStyle(.plain)
                .help("Copy the total")
            }

            IconButton(systemName: series.isExpanded ? "chevron.up" : "chevron.down",
                       help: series.isExpanded ? "Collapse" : "Show details") {
                series.isExpanded.toggle()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: SeriesBarController.collapsedHeight)
    }

    // MARK: - Expanded

    private func expanded(_ active: Series) -> some View {
        VStack(spacing: 10) {
            Rectangle().fill(Theme.glowLine).frame(height: 1).opacity(0.6)

            NameField(name: active.name) { series.rename($0) }
                .padding(.horizontal, 14)

            if let prompt = series.prompt {
                PromptBanner(prompt: prompt, appInfo: series.appInfo,
                             onNew: { series.acceptPrompt() }, onKeep: { series.dismissPrompt() })
                    .padding(.horizontal, 12)
            }

            if series.stats != nil {
                // Same tiles as the history panel; three per row fits the bar's width.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(series.statItems) { item in
                        StatTile(item: item, emphasized: item.label == "Sum") { series.copy(item) }
                    }
                }
                .padding(.horizontal, 12)
            }

            entryList(active)

            actions
        }
        .padding(.bottom, 10)
    }

    private func entryList(_ active: Series) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if active.entries.isEmpty {
                    Text("Copy numbers anywhere: they add up here.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.vertical, 18)
                }
                // Newest first.
                ForEach(Array(active.entries.reversed())) { entry in
                    SeriesEntryRow(entry: entry, app: series.appInfo.info(for: entry.sourceBundleID),
                                   format: series.format,
                                   onInclude: { series.include(entry) },
                                   onExclude: { series.exclude(entry) },
                                   onRemove: { series.remove(entry) })
                }
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            BarActionChip(title: "Undo", icon: "arrow.uturn.backward") { series.undoLast() }
            BarActionChip(title: "Copy values", icon: "list.number") { series.copyValues() }
            Spacer()
            BarActionChip(title: "New series", icon: "plus", accent: true) { series.startNew() }
            BarActionChip(title: "Stop", icon: "stop.fill") { series.stop() }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Pieces

/// Softly pulsing status light: "recording".
struct PulseDot: View {
    let color: Color
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color, radius: bright ? 6 : 2)
            .opacity(bright ? 1 : 0.55)
            .onAppear {
                // repeatForever: keeps animating between the two states.
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

/// The series name; click to edit, ⏎ to save.
struct NameField: View {
    let name: String
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("Series name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit { onCommit(draft); focused = false }
        }
        .onAppear { draft = name }
        .onChange(of: name) { _, newValue in draft = newValue }
        .onChange(of: focused) { _, isFocused in if !isFocused { onCommit(draft) } }
    }
}

struct PromptBanner: View {
    let prompt: SeriesPrompt
    let appInfo: AppInfoCache
    let onNew: () -> Void
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.amber)
                Text(verbatim: message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer()
                BarActionChip(title: "Keep in this series", icon: "checkmark", action: onKeep)
                BarActionChip(title: "Start new series", icon: "plus", accent: true, action: onNew)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.amber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.amber.opacity(0.35), lineWidth: 1))
    }

    private var message: String {
        switch prompt {
        case .idleGap(let minutes, _):
            return "\(minutes) min since your last number. New task? Start a new series with this copy."
        case .appSwitch(_, let to, _):
            let app = appInfo.info(for: to)?.name ?? "another app"
            return "Numbers are now coming from \(app). Start a new series?"
        }
    }
}

struct SeriesEntryRow: View {
    let entry: SeriesEntry
    let app: AppInfo?
    let format: NumberFormat
    let onInclude: () -> Void
    let onExclude: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app?.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "number").foregroundStyle(Theme.textTertiary) }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.preview)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(entry.isIncluded ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                Text(verbatim: detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)

            if entry.isIncluded {
                Text(verbatim: NumberFormatting.grouped(entry.subtotal, format: format))
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.cyan)
            } else {
                BarActionChip(title: "Add", icon: "plus", accent: true, action: onInclude)
                    .help("Include these numbers: \(entry.values.map { NumberFormatting.grouped($0, format: format) }.joined(separator: ", "))")
            }

            if hovering {
                IconButton(systemName: entry.isIncluded ? "minus.circle" : "xmark.circle",
                           help: entry.isIncluded ? "Leave out of the total" : "Remove") {
                    entry.isIncluded ? onExclude() : onRemove()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(hovering ? Theme.glassFill : Color.clear))
        .opacity(entry.isIncluded ? 1 : 0.8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if entry.isIncluded {
                Button("Leave Out of Total", action: onExclude)
            } else {
                Button("Add to Total", action: onInclude)
            }
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !entry.isIncluded { parts.append("Skipped: has text · click Add to include") }
        else if entry.values.count > 1 { parts.append("\(entry.values.count) values") }
        if let name = app?.name { parts.append(name) }
        parts.append(RelativeTime.string(for: entry.createdAt))
        return parts.joined(separator: " · ")
    }
}

/// Compact capsule button used in the bar.
struct BarActionChip: View {
    let title: String
    let icon: String
    var accent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(verbatim: title).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(accent ? Theme.cyan : (hovering ? Theme.textPrimary : Theme.textSecondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(accent ? Theme.cyan.opacity(hovering ? 0.22 : 0.13) : (hovering ? Theme.glassFillHover : Theme.glassFill)))
            .overlay(Capsule().strokeBorder(accent ? Theme.cyan.opacity(0.45) : Theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Small round icon-only button.
struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hovering ? Theme.glassFillHover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
