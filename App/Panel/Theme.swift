import AppKit
import ParseleyCore
import SwiftUI

/// Design tokens for the "crystal" look: dark frosted glass, a cyan→violet accent,
/// hairline light-catching edges, monospaced digits. Change the look here, not in views.
enum Theme {
    // Accent palette
    static let cyan = Color(red: 0.37, green: 0.91, blue: 1.00)
    static let violet = Color(red: 0.62, green: 0.55, blue: 1.00)
    static let mint = Color(red: 0.36, green: 1.00, blue: 0.70)
    static let amber = Color(red: 1.00, green: 0.77, blue: 0.36)
    static let rose = Color(red: 1.00, green: 0.46, blue: 0.56)

    // Text on glass. Checked for WCAG contrast over the glass on both a black and a
    // white wallpaper (with the dark base layer in CrystalBackground):
    // primary ≥ 11:1, secondary ≥ 8:1, tertiary ≥ 5.5:1, cyan ≥ 9:1, violet ≥ 4.9:1.
    // Numbers are always drawn in solid colors, never gradients.
    static let textPrimary = Color.white.opacity(0.93)
    static let textSecondary = Color.white.opacity(0.74)
    static let textTertiary = Color.white.opacity(0.58)
    /// The figure that matters most (Sum tile, series total): pure white.
    static let numberEmphasis = Color.white

    // Glass surfaces
    static let glassFill = Color.white.opacity(0.055)
    static let glassFillHover = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.11)

    static let accentGradient = LinearGradient(
        colors: [cyan, violet], startPoint: .leading, endPoint: .trailing
    )
    static let accentGradientSoft = LinearGradient(
        colors: [cyan.opacity(0.75), violet.opacity(0.75)], startPoint: .leading, endPoint: .trailing
    )
    /// Bright top-left edge fading out toward the bottom-right: light catching the glass.
    static let edgeGradient = LinearGradient(
        colors: [.white.opacity(0.75), .white.opacity(0.32), cyan.opacity(0.55)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    /// Faint inner rim just inside the edge: the thickness of the glass.
    static let innerRim = LinearGradient(
        colors: [.white.opacity(0.22), .white.opacity(0.06), .white.opacity(0.14)],
        startPoint: .top, endPoint: .bottom
    )
    /// A thin glowing line used as a section divider.
    static let glowLine = LinearGradient(
        colors: [.clear, cyan.opacity(0.55), violet.opacity(0.55), .clear],
        startPoint: .leading, endPoint: .trailing
    )

    static let panelSize = CGSize(width: 720, height: 620)
    static let panelRadius: CGFloat = 22
    static let tileRadius: CGFloat = 12
    static let rowRadius: CGFloat = 10

    static func color(for kind: ClipKind) -> Color {
        switch kind {
        case .number, .numberList: cyan
        case .seriesTotal: mint
        case .table: mint
        case .json: amber
        case .url, .email: violet
        case .text: Color.white.opacity(0.55)
        }
    }

    /// SF Symbol for each transform button, keyed by the transform's stable id.
    static func icon(forTransformID id: String) -> String {
        switch id {
        case "list.comma": "list.bullet"
        case "sql.in": "cylinder.split.1x2"
        case "json.array": "curlybraces"
        case "sort.asc": "arrow.up"
        case "sort.desc": "arrow.down"
        case "list.dedupe": "square.on.square"
        case "text.clean": "sparkles"
        case "number.plain": "number"
        case "paste.column": "arrow.down.to.line"
        case "paste.row": "arrow.right.to.line"
        case "table.transpose": "arrow.left.arrow.right"
        default: "wand.and.stars"
        }
    }
}

// MARK: - Reusable glass pieces

/// Frosted, see-through background. SwiftUI's own materials only blur *inside* the
/// window; NSVisualEffectView with `.behindWindow` blurs whatever is *behind* the window
/// (your desktop and other apps), which is what makes it look like glass.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // Our panel never activates the app, so by default the effect would render in
        // its dull "inactive window" state. Force it on.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The panel's crystal backdrop: blur, a faint cyan/violet tint, a soft light bloom in
/// the top-left corner, and a gradient edge.
struct CrystalBackground: View {
    var cornerRadius: CGFloat = Theme.panelRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            VisualEffectBackground()
            // Dark base: keeps text readable even over a white wallpaper, where the
            // blurred light would otherwise wash out the glass.
            Color(red: 10 / 255, green: 14 / 255, blue: 26 / 255).opacity(0.55)
            LinearGradient(
                colors: [Theme.cyan.opacity(0.10), .clear, Theme.violet.opacity(0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [.white.opacity(0.10), .clear],
                center: .topLeading, startRadius: 0, endRadius: 420
            )
        }
        .clipShape(shape)
        // A glass rim instead of a dark outline: bright outer edge + soft inner highlight.
        // (The windows have no system shadow; macOS draws that as a dark rim.)
        .overlay(shape.strokeBorder(Theme.edgeGradient, lineWidth: 1.25))
        .overlay(shape.inset(by: 1.25).strokeBorder(Theme.innerRim, lineWidth: 1))
    }
}

/// A small frosted card: faint fill plus hairline border (gradient when highlighted).
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.tileRadius
    var highlighted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(highlighted ? Theme.glassFillHover : Theme.glassFill))
            .overlay(
                shape.strokeBorder(
                    highlighted ? AnyShapeStyle(Theme.accentGradientSoft) : AnyShapeStyle(Theme.hairline),
                    lineWidth: 1
                )
            )
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.tileRadius, highlighted: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, highlighted: highlighted))
    }
}

/// Parseley's logo (the app icon artwork, from the asset catalog). Uses its own image
/// asset rather than the app's icon, which macOS caches and can show stale.
struct ParseleyLogo: View {
    var size: CGFloat = 32

    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            // The artwork has Apple's icon margin; scale it so the squircle fills `size`.
            .frame(width: size * 1024 / 824, height: size * 1024 / 824)
            .frame(width: size, height: size)
            .accessibilityLabel("Parseley")
    }
}

/// A keyboard key drawn as a tiny keycap: ⏎, ⌘P, esc…
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Colored capsule naming a clip's kind: NUMBERS, LINK, JSON…
struct KindBadge: View {
    let kind: ClipKind

    var body: some View {
        let color = Theme.color(for: kind)
        Text(verbatim: kind.displayName.uppercased())
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }
}
