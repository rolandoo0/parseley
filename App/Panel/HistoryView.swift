import ParseleyCore
import SwiftUI

/// The panel's SwiftUI content: search field, clip list, preview of the selected clip,
/// and a footer of keyboard hints.
struct HistoryView: View {
    // `@Bindable` lets us derive two-way bindings (`$model.query`) from an @Observable
    // object, which TextField needs.
    @Bindable var model: HistoryPanelModel
    // `@FocusState` is SwiftUI's handle on keyboard focus; setting it to true focuses
    // the field it's attached to via `.focused(...)`.
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if !model.isAccessibilityTrusted {
                accessibilityBanner
                Divider()
            }
            if let error = model.errorMessage {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
            }
            clipList
            if let clip = model.selectedClip {
                Divider()
                ClipDetailView(clip: clip)
                if let stats = model.selectedStats {
                    StatsStripView(stats: stats) { model.copyStat($0) }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                Divider()
                TransformBarView { model.applyTransform($0) }
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search clipboard history", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text("Auto-paste is off. ↩ copies the clip; press ⌘V yourself.")
                .font(.callout)
            Spacer()
            Button("Enable Auto-Paste…") { model.enableAutoPaste() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.1))
    }

    private var clipList: some View {
        // ScrollViewReader gives us `proxy.scrollTo(id)` to keep the keyboard selection visible.
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: only rows on screen are built, so hundreds of clips stay cheap.
                LazyVStack(spacing: 1) {
                    ForEach(model.clips) { clip in
                        ClipRow(
                            clip: clip,
                            isSelected: clip.id == model.selection.selectedID,
                            app: model.appInfo.info(for: clip.sourceBundleID)
                        )
                        .id(clip.id)
                        // Order matters: the double-tap gesture must come first or the
                        // single tap would always win.
                        .onTapGesture(count: 2) { model.activate(clip) }
                        .onTapGesture { model.select(clip) }
                        .contextMenu { contextMenu(for: clip) }
                    }
                }
                .padding(6)
            }
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
        VStack(spacing: 6) {
            Image(systemName: "clipboard").font(.largeTitle).foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let toast = model.toast {
                // Short confirmation after copying a stat or running a transform.
                Label { Text(verbatim: toast) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else {
                hint("↩", "Paste")
                hint("⌘↩", "Copy")
                hint("⌘P", "Pin")
                hint("⌘⌫", "Delete")
            }
            Spacer()
            hint("esc", "Close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
            Text(label)
        }
    }
}

/// One row in the history list.
struct ClipRow: View {
    let clip: Clip
    let isSelected: Bool
    let app: AppInfo?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ClipPreview.title(clip.content, maxLength: 200))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        // Without this, only the text and icon would be clickable, not the blank space.
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [clip.kind.displayName]
        let lines = ClipPreview.lineCount(clip.content)
        if lines > 1 { parts.append("\(lines) lines") }
        if let name = app?.name { parts.append(name) }
        parts.append(RelativeTime.string(for: clip.lastUsedAt))
        return parts.joined(separator: " · ")
    }
}

/// Larger preview of the selected clip.
struct ClipDetailView: View {
    let clip: Clip

    var body: some View {
        ScrollView {
            Text(verbatim: String(clip.content.prefix(5_000)))
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(height: 84)
    }
}

/// Count · Sum · Average · Median · Min · Max. Click a tile to copy its value.
struct StatsStripView: View {
    let stats: NumberStats
    let onCopy: (NumberStats.Item) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(stats.items) { item in
                Button {
                    onCopy(item)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(verbatim: item.display)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)   // shrink long numbers instead of truncating
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    .contentShape(Rectangle())
                }
                // `.plain` drops the default bordered button look so our tile styling shows.
                .buttonStyle(.plain)
                .help("Copy \(item.label.lowercased()): \(item.copyText)")   // tooltip
            }
        }
    }
}

/// One button per transform. The result is copied, added to history, and selected,
/// so ↩ pastes it right away.
struct TransformBarView: View {
    let onApply: (any Transform) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Iterate indices: `any Transform` isn't Identifiable/Hashable itself.
                ForEach(TransformRegistry.all.indices, id: \.self) { index in
                    let transform = TransformRegistry.all[index]
                    Button(transform.title) { onApply(transform) }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

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
