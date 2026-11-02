import ParseleyCore
import SwiftUI

/// The panel's SwiftUI content: search, clip list, the selected clip's preview + stats +
/// transforms, and a footer of keyboard hints. Styling tokens live in Theme.swift.
struct HistoryView: View {
    // `@Bindable` lets us derive two-way bindings (`$model.query`) from an @Observable
    // object, which TextField needs.
    @Bindable var model: HistoryPanelModel
    // `@FocusState` is SwiftUI's handle on keyboard focus; setting it to true focuses
    // the field it's attached to via `.focused(...)`.
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            glowDivider
            if !model.isAccessibilityTrusted {
                accessibilityBanner
            }
            if let error = model.errorMessage {
                Text(verbatim: error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.rose)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
            }
            clipList
            if let clip = model.selectedClip {
                detail(for: clip)
            }
            footer
        }
        .frame(width: Theme.panelSize.width, height: Theme.panelSize.height)
        .background(CrystalBackground())
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        // The crystal look is designed for dark glass; force dark controls/context menus.
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.15), value: model.selection.selectedID)
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { searchFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            TextField(
                "", text: $model.query,
                prompt: Text("Search your clipboard").foregroundStyle(Theme.textTertiary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 19, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
            .focused($searchFocused)

            Text(verbatim: "\(model.clips.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassCard(radius: 8)
                .help("Clips shown")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 13)
    }

    private var glowDivider: some View {
        Rectangle().fill(Theme.glowLine).frame(height: 1).opacity(0.8)
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(Theme.amber)
            Text("Auto-paste is off. ↩ copies; press ⌘V yourself.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button {
                model.enableAutoPaste()
            } label: {
                Text("Enable")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.amber.opacity(0.15)))
                    .overlay(Capsule().strokeBorder(Theme.amber.opacity(0.4), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassCard(radius: 10)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: - List

    private var clipList: some View {
        // ScrollViewReader gives us `proxy.scrollTo(id)` to keep the keyboard selection visible.
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: only rows on screen are built, so hundreds of clips stay cheap.
                LazyVStack(spacing: 2) {
                    ForEach(model.clips) { clip in
                        ClipRow(
                            clip: clip,
                            isSelected: clip.id == model.selection.selectedID,
                            app: model.appInfo.info(for: clip.sourceBundleID),
                            stats: model.stats(for: clip)
                        )
                        .id(clip.id)
                        // Order matters: the double-tap gesture must come first or the
                        // single tap would always win.
                        .onTapGesture(count: 2) { model.activate(clip) }
                        .onTapGesture { model.select(clip) }
                        .contextMenu { contextMenu(for: clip) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .overlay { if model.clips.isEmpty { emptyState } }
            .onChange(of: model.selection.selectedID) { _, newID in
                proxy.scrollTo(newID)   // nil anchor = scroll just enough to reveal it
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for clip: Clip) -> some View {
        Button("Paste") { model.activate(clip) }
        Button("Copy") { model.activate(clip, mode: .copyOnly) }
        Button(clip.isPinned ? "Unpin" : "Pin") { model.togglePin(clip) }
        Divider()
        Button("Delete", role: .destructive) { model.delete(clip) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.query.isEmpty ? "sparkles" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accentGradient)
                .shadow(color: Theme.cyan.opacity(0.5), radius: 12)
            Text(model.query.isEmpty ? "Copy something to get started" : "No matches")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Detail (preview, stats, transforms)

    private func detail(for clip: Clip) -> some View {
        VStack(spacing: 10) {
            ScrollView {
                Text(verbatim: String(clip.content.prefix(5_000)))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            .scrollIndicators(.hidden)
            .frame(height: 74)
            .glassCard(radius: Theme.tileRadius)

            if let stats = model.selectedStats {
                StatsStripView(stats: stats) { model.copyStat($0) }
                    // Fade/slide in when moving onto a clip that has numbers.
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            TransformBarView { model.applyTransform($0) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        // A slightly darker "console" zone separates actions from the list.
        .background(Color.black.opacity(0.14))
        .overlay(alignment: .top) { glowDivider.opacity(0.5) }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if let toast = model.toast {
                // Short confirmation after copying a stat or running a transform.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(verbatim: toast).lineLimit(1)
                }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.mint)
                .shadow(color: Theme.mint.opacity(0.6), radius: 6)
                .transition(.opacity)
            } else {
                hint("⏎", "Paste")
                hint("⌘⏎", "Copy")
                hint("⌘P", "Pin")
                hint("⌘⌫", "Delete")
            }
            Spacer()
            hint("esc", "Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key: key)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Row

/// One row in the history list.
struct ClipRow: View {
    let clip: Clip
    let isSelected: Bool
    let app: AppInfo?
    /// Present when the clip has 2+ numbers: the row then shows its sum inline.
    let stats: NumberStats?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = app?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 20, height: 20)
            .opacity(isSelected ? 1 : 0.85)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: ClipPreview.title(clip.content, maxLength: 200))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 7) {
                    KindBadge(kind: clip.kind)
                    if let stats, let sum = stats.items.first(where: { $0.label == "Sum" }) {
                        Text(verbatim: "Σ \(sum.display)  ·  \(stats.count) values")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.cyan.opacity(0.9))
                            .lineLimit(1)
                    }
                    Text(verbatim: metadata)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                    .shadow(color: Theme.violet.opacity(0.6), radius: 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { rowBackground }
        // Without this, only the text and icon would be clickable, not the blank space.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
        if isSelected {
            ZStack(alignment: .leading) {
                shape.fill(LinearGradient(
                    colors: [Theme.cyan.opacity(0.20), Theme.violet.opacity(0.14)],
                    startPoint: .leading, endPoint: .trailing
                ))
                shape.strokeBorder(Theme.cyan.opacity(0.35), lineWidth: 1)
                // Glowing selection marker on the left edge.
                Capsule()
                    .fill(Theme.cyan)
                    .frame(width: 3, height: 20)
                    .shadow(color: Theme.cyan, radius: 6)
                    .padding(.leading, 3)
            }
        } else if hovering {
            shape.fill(Theme.glassFill)
        }
    }

    private var metadata: String {
        var parts: [String] = []
        let lines = ClipPreview.lineCount(clip.content)
        if lines > 1 && stats == nil { parts.append("\(lines) lines") }
        if let name = app?.name { parts.append(name) }
        parts.append(RelativeTime.string(for: clip.lastUsedAt))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Stats

/// Count · Sum · Average · Median · Min · Max. Click a tile to copy its value.
struct StatsStripView: View {
    let stats: NumberStats
    let onCopy: (NumberStats.Item) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(stats.items) { item in
                StatTile(item: item, emphasized: item.label == "Sum") { onCopy(item) }
            }
        }
    }
}

struct StatTile: View {
    let item: NumberStats.Item
    /// The Sum tile gets the accent gradient: it's what people copy most.
    let emphasized: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.label.uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(Theme.textTertiary)
                Text(verbatim: item.display)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(emphasized ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textPrimary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)   // shrink long numbers instead of truncating
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassCard(radius: Theme.tileRadius, highlighted: hovering || emphasized)
            .shadow(color: hovering ? Theme.cyan.opacity(0.35) : .clear, radius: 8)
            .contentShape(Rectangle())
        }
        // `.plain` drops the default bordered button look so our tile styling shows.
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Copy \(item.label.lowercased()): \(item.copyText)")   // tooltip
    }
}

// MARK: - Transforms

/// One chip per transform. The result is copied, added to history and selected, so ⏎
/// pastes it right away.
struct TransformBarView: View {
    let onApply: (any Transform) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                // Iterate indices: `any Transform` isn't Identifiable/Hashable itself.
                ForEach(TransformRegistry.all.indices, id: \.self) { index in
                    let transform = TransformRegistry.all[index]
                    TransformChip(title: transform.title, icon: Theme.icon(forTransformID: transform.id)) {
                        onApply(transform)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }
}

struct TransformChip: View {
    let title: String
    let icon: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(hovering ? Theme.glassFillHover : Theme.glassFill))
            .overlay(
                Capsule().strokeBorder(
                    hovering ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.hairline),
                    lineWidth: 1
                )
            )
            .shadow(color: hovering ? Theme.violet.opacity(0.4) : .clear, radius: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Helpers

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func string(for date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 10 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
