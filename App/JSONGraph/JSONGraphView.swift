import ParseleyCore
import SwiftUI

/// The JSON graph window: a toolbar, the canvas (pan, zoom, click a card to inspect it,
/// click its ± handle or double-click to collapse), and an inspector for the selection.
struct JSONGraphView: View {
    @Bindable var model: JSONGraphModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let error = model.parseError {
                ParseErrorView(error: error)
            } else {
                HStack(spacing: 0) {
                    GraphCanvas(model: model)
                    if let node = model.selectedNode {
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                        Inspector(model: model, node: node)
                            .frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: model.selectedPath == nil)
            }
        }
        .background(Color(red: 9 / 255, green: 12 / 255, blue: 24 / 255))
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.mint)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .background {
            // Keyboard shortcuts without visible buttons.
            Group {
                Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                Button("") { model.fit() }.keyboardShortcut("0", modifiers: .command)
                Button("") { model.zoom(by: 1.25) }.keyboardShortcut("=", modifiers: .command)
                Button("") { model.zoom(by: 0.8) }.keyboardShortcut("-", modifiers: .command)
                Button("") { model.select(nil); searchFocused = false }.keyboardShortcut(.cancelAction)
            }
            .opacity(0)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            ParseleyLogo(size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: 280, alignment: .leading)
            Spacer()
            if model.parseError == nil {
                searchField
                Divider().frame(height: 18)
                toolButton("arrow.down.right.and.arrow.up.left", help: "Collapse all") { model.collapseAll() }
                toolButton("arrow.up.left.and.arrow.down.right", help: "Expand all") { model.expandAll() }
                Divider().frame(height: 18)
                toolButton("minus.magnifyingglass", help: "Zoom out (⌘−)") { model.zoom(by: 0.8) }
                Text(verbatim: "\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40)
                toolButton("plus.magnifyingglass", help: "Zoom in (⌘=)") { model.zoom(by: 1.25) }
                toolButton("rectangle.dashed", help: "Fit to window (⌘0)") { model.fit() }
            }
        }
        // Leave room for the window's close/minimize/zoom buttons (transparent title bar).
        .padding(.leading, 80)
        .padding(.trailing, 14)
        .frame(height: 52)
    }

    private var subtitle: String {
        guard let graph = model.graph else { return "Invalid JSON" }
        var text = "\(graph.nodes.count) card\(graph.nodes.count == 1 ? "" : "s")"
        if !model.collapsed.isEmpty { text += " · \(model.collapsed.count) collapsed" }
        if graph.isTruncated { text += " · showing the first \(graph.nodes.count)" }
        return text
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
            TextField("", text: $model.query, prompt: Text("Search keys and values").foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { model.nextMatch() }
                .frame(width: 170)
            if !model.query.isEmpty {
                Text(verbatim: model.matches.isEmpty ? "0" : "\(model.matchIndex + 1)/\(model.matches.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(model.matches.isEmpty ? Theme.rose : Theme.textSecondary)
                Button { model.nextMatch(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
                Button { model.nextMatch() } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassCard(radius: 8)
    }

    private func toolButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Canvas

private struct GraphCanvas: View {
    let model: JSONGraphModel
    @State private var dragStart: CGSize?

    var body: some View {
        GeometryReader { proxy in
            Canvas(rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        let start = dragStart ?? model.offset
                        dragStart = start
                        model.offset = CGSize(width: start.width + value.translation.width,
                                              height: start.height + value.translation.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    if let hit = model.hit(at: value.location) { model.toggleCollapse(hit.id) }
                }
                .exclusively(before: SpatialTapGesture().onEnded { value in model.tap(at: value.location) })
            )
            .overlay(alignment: .bottomLeading) { Legend().padding(14) }
            .onAppear { report(proxy) }
            .onChange(of: proxy.size) { _, _ in report(proxy) }
        }
    }

    private func report(_ proxy: GeometryProxy) {
        let frame = proxy.frame(in: .global)
        model.canvasTop = frame.minY
        model.canvasMaxX = frame.maxX
        model.viewSize = proxy.size
    }

    // MARK: Drawing

    static let keyColor = Color(red: 0.78, green: 0.75, blue: 1.0)
    static let cardFill = Color(red: 18 / 255, green: 25 / 255, blue: 46 / 255)

    static func color(for kind: JSONGraph.Row.Kind) -> Color {
        switch kind {
        case .string: Theme.mint
        case .number: Theme.cyan
        case .bool: Theme.amber
        case .null: Theme.textTertiary
        case .object, .array: Theme.textSecondary
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        drawDots(in: &context, size: size)
        guard let graph = model.graph else { return }
        let zoom = model.zoom
        let offset = model.offset
        let visible = JSONGraph.Rect(x: -Double(offset.width) / zoom, y: -Double(offset.height) / zoom,
                                     width: Double(size.width) / zoom, height: Double(size.height) / zoom)
        let matches = Set(model.matches)
        let selected = model.selectedPath
        let detailed = zoom >= 0.35   // below this, cards are drawn without text (fast and readable)

        context.translateBy(x: offset.width, y: offset.height)
        context.scaleBy(x: zoom, y: zoom)

        // Edges: a soft S-curve from the parent's right side to the child's left side.
        for edge in graph.edges {
            let a = graph.nodes[edge.from].frame, b = graph.nodes[edge.to].frame
            let box = JSONGraph.Rect(x: a.maxX, y: min(a.midY, b.midY), width: b.x - a.maxX, height: abs(b.midY - a.midY) + 1)
            guard box.intersects(visible) else { continue }
            let start = CGPoint(x: a.maxX + JSONGraphModel.toggleRadius, y: a.midY)
            let end = CGPoint(x: b.x, y: b.midY)
            let midX = (start.x + end.x) / 2
            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
            context.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 1.5)
            if detailed, let label = edge.label {
                let text = context.resolve(Text(verbatim: label).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textSecondary))
                let at = CGPoint(x: midX, y: (start.y + end.y) / 2)
                let textSize = text.measure(in: CGSize(width: 200, height: 20))
                let bg = CGRect(x: at.x - textSize.width / 2 - 5, y: at.y - 8, width: textSize.width + 10, height: 16)
                context.fill(Path(roundedRect: bg, cornerRadius: 8), with: .color(Color(red: 9 / 255, green: 12 / 255, blue: 24 / 255)))
                context.draw(text, at: at, anchor: .center)
            }
        }

        // Cards.
        for node in graph.nodes where node.frame.intersects(visible) {
            let f = node.frame
            let rect = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
            let shape = Path(roundedRect: rect, cornerRadius: 10)
            let isSelected = node.path == selected
            context.fill(shape, with: .color(Self.cardFill))
            if isSelected { context.fill(shape, with: .color(Theme.cyan.opacity(0.14))) }
            let border: Color = isSelected ? Theme.cyan : matches.contains(node.id) ? Theme.amber : .white.opacity(0.16)
            if node.kind == .more {
                // "… N more": dashed, so it reads as a placeholder you can click.
                context.stroke(shape, with: .color(Theme.cyan.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            } else {
                context.stroke(shape, with: .color(border), lineWidth: isSelected || matches.contains(node.id) ? 2 : 1)
            }

            if detailed {
                context.drawLayer { layer in
                    layer.clip(to: shape)
                    var y = f.y + 6
                    if let title = node.title {
                        let text = Text(verbatim: title).font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                        layer.draw(text, at: CGPoint(x: f.x + 12, y: y + 11), anchor: .leading)
                        y += 28
                        var line = Path()
                        line.move(to: CGPoint(x: f.x, y: y - 4))
                        line.addLine(to: CGPoint(x: f.maxX, y: y - 4))
                        layer.stroke(line, with: .color(.white.opacity(0.10)), lineWidth: 1)
                    }
                    for row in node.rows {
                        var text = Text("")
                        if let key = row.key {
                            text = Text(verbatim: key).foregroundColor(Self.keyColor) + Text(verbatim: ": ").foregroundColor(Theme.textTertiary)
                        }
                        text = text + Text(verbatim: row.value).foregroundColor(Self.color(for: row.kind))
                        layer.draw(text.font(.system(size: 13, design: .monospaced)),
                                   at: CGPoint(x: f.x + 12, y: y + 11), anchor: .leading)
                        y += 22
                    }
                }
            } else {
                // Zoomed far out: a bar per row instead of text.
                for (i, row) in node.rows.prefix(12).enumerated() {
                    let bar = CGRect(x: f.x + 10, y: f.y + 10 + Double(i) * 22, width: (f.width - 20) * 0.7, height: 8)
                    context.fill(Path(roundedRect: bar, cornerRadius: 4), with: .color(Self.color(for: row.kind).opacity(0.45)))
                }
            }

            // Collapse handle on the right edge.
            if node.childCount > 0 {
                let r = JSONGraphModel.toggleRadius
                let label = node.isCollapsed ? "+\(node.childCount)" : "−"
                let width = node.isCollapsed ? max(2 * r, Double(label.count) * 7 + 10) : 2 * r
                let handle = CGRect(x: f.maxX - width / 2, y: f.midY - r, width: width, height: 2 * r)
                let pill = Path(roundedRect: handle, cornerRadius: r)
                context.fill(pill, with: .color(Self.cardFill))
                context.stroke(pill, with: .color(node.isCollapsed ? Theme.amber : Theme.cyan.opacity(0.8)), lineWidth: 1.2)
                if detailed {
                    context.draw(Text(verbatim: label).font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundColor(node.isCollapsed ? Theme.amber : Theme.cyan),
                                 at: CGPoint(x: handle.midX, y: handle.midY), anchor: .center)
                }
            }
        }
    }

    /// A faint dot grid that moves with the canvas, so panning feels anchored.
    private func drawDots(in context: inout GraphicsContext, size: CGSize) {
        let spacing = CGFloat(28 * model.zoom)
        guard spacing >= 8 else { return }
        let startX = model.offset.width.truncatingRemainder(dividingBy: spacing)
        let startY = model.offset.height.truncatingRemainder(dividingBy: spacing)
        var dots = Path()
        var x = startX
        while x < size.width {
            var y = startY
            while y < size.height {
                dots.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                y += spacing
            }
            x += spacing
        }
        context.fill(dots, with: .color(.white.opacity(0.06)))
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            item("string", Theme.mint)
            item("number", Theme.cyan)
            item("bool", Theme.amber)
            item("null", Theme.textTertiary)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .allowsHitTesting(false)
    }

    private func item(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Inspector

private struct Inspector: View {
    let model: JSONGraphModel
    let node: JSONGraph.Node

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(kindName)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(Theme.cyan)
                Spacer()
                Button { model.select(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Close (esc)")
            }
            Text(verbatim: node.path)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TransformChip(title: "Copy path", icon: "link") { model.copyPath() }
                TransformChip(title: "Copy JSON", icon: "curlybraces") { model.copyJSON() }
                if node.childCount > 0 {
                    TransformChip(title: node.isCollapsed ? "Expand" : "Collapse",
                                  icon: node.isCollapsed ? "plus.circle" : "minus.circle") { model.toggleCollapse(node.id) }
                }
            }
            if node.kind == .array, JSONGraph.isLong(node.childCount), !node.isCollapsed {
                if model.isShowingAll(node.path) {
                    TransformChip(title: "Show first & last \(JSONGraph.listEdge)", icon: "rectangle.compress.vertical") {
                        model.shorten(node.path)
                    }
                } else {
                    TransformChip(title: "Show all \(node.childCount)", icon: "rectangle.expand.vertical") {
                        model.showAll(node.path)
                    }
                }
            }

            Text("VALUE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
            ScrollView {
                Text(verbatim: preview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .glassCard(radius: 10)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.03))
    }

    private var kindName: String {
        switch node.kind {
        case .object: "OBJECT · \(node.rows.count) KEY\(node.rows.count == 1 ? "" : "S")"
        case .array: "ARRAY · \(node.childCount) ITEM\(node.childCount == 1 ? "" : "S")"
        case .value: "VALUE"
        case .more: "MORE"
        }
    }

    /// The full JSON for this card, capped so huge subtrees don't stall the inspector.
    private var preview: String {
        guard let json = model.selectedJSON else { return "" }
        let limit = 20_000
        return json.count > limit ? String(json.prefix(limit)) + "\n… (Copy JSON for the rest)" : json
    }
}

// MARK: - Errors

private struct ParseErrorView: View {
    let error: JSONParseError

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.amber)
            Text("This clip isn't valid JSON")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(verbatim: error.description)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Text("Common causes: single quotes instead of double quotes, a trailing comma, or comments.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
