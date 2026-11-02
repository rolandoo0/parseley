/// A task profile: how Parseley behaves while you work in certain apps.
/// "Finance" when you're in Excel, "SQL" in a database tool, and so on.
public struct Mode: Identifiable, Equatable, Codable, Sendable {
    /// Stable id; built-ins use fixed ids ("general", "finance", …), custom modes a UUID.
    public var id: String
    public var name: String
    /// SF Symbol shown in the menu bar and the panel's mode chip.
    public var icon: String
    /// Bundle ids of apps that switch to this mode when they're in front.
    public var apps: [String]
    public var numberFormat: NumberFormat
    /// Show the stats strip and inline sums (off for writing, where numbers are noise).
    public var showsNumbers: Bool
    /// Copies made in this mode's apps count toward a running series.
    public var countsInSeries: Bool
    /// Stat shown first and copied by ⌘1: "Sum", "Count", "Average", …
    public var primaryStat: String
    /// Transform ids shown first, in this order; the rest follow.
    public var pinnedTransforms: [String]
    public var isBuiltIn: Bool

    public init(
        id: String, name: String, icon: String, apps: [String] = [],
        numberFormat: NumberFormat = .us, showsNumbers: Bool = true, countsInSeries: Bool = true,
        primaryStat: String = "Sum", pinnedTransforms: [String] = [], isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.apps = apps
        self.numberFormat = numberFormat
        self.showsNumbers = showsNumbers
        self.countsInSeries = countsInSeries
        self.primaryStat = primaryStat
        self.pinnedTransforms = pinnedTransforms
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - Built-in presets

extension Mode {
    public static let generalID = "general"

    /// Used whenever no other mode claims the frontmost app.
    public static let general = Mode(
        id: generalID, name: "General", icon: "list.clipboard", isBuiltIn: true
    )

    public static let finance = Mode(
        id: "finance", name: "Finance", icon: "dollarsign.circle",
        apps: [
            "com.microsoft.Excel", "com.apple.iWork.Numbers",
            "com.intuit.QuickBooks", "com.xero.Xero",
        ],
        primaryStat: "Sum",
        pinnedTransforms: ["number.plain", "list.comma", "sort.desc"],
        isBuiltIn: true
    )

    public static let sql = Mode(
        id: "sql", name: "SQL", icon: "cylinder.split.1x2",
        apps: [
            "com.jetbrains.datagrip", "com.tinyapp.TablePlus", "at.eggerapps.Postico2",
            "com.sequel-ace.sequel-ace", "org.jkiss.dbeaver.core.product",
            "com.azuredatastudio.oss", "io.beekeeperstudio.desktop",
        ],
        primaryStat: "Count",
        pinnedTransforms: ["sql.in", "list.dedupe", "json.array", "list.comma"],
        isBuiltIn: true
    )

    public static let dev = Mode(
        id: "dev", name: "Dev", icon: "chevron.left.forwardslash.chevron.right",
        apps: [
            "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92",
            "dev.zed.Zed", "com.apple.Terminal", "com.googlecode.iterm2",
        ],
        countsInSeries: false,
        primaryStat: "Count",
        pinnedTransforms: ["json.array", "sql.in", "list.dedupe", "sort.asc", "text.clean"],
        isBuiltIn: true
    )

    public static let writing = Mode(
        id: "writing", name: "Writing", icon: "text.alignleft",
        apps: [
            "com.apple.iWork.Pages", "com.microsoft.Word", "notion.id", "md.obsidian",
            "net.shinyfrog.bear", "com.apple.Notes",
        ],
        showsNumbers: false,
        countsInSeries: false,
        pinnedTransforms: ["text.clean", "list.dedupe"],
        isBuiltIn: true
    )

    public static let builtIns: [Mode] = [.general, .finance, .sql, .dev, .writing]
}

// MARK: - Library

/// All modes (built-in and custom) plus the logic to pick one. Codable so the app can
/// store it as one JSON value.
public struct ModeLibrary: Equatable, Codable, Sendable {
    /// General is always first and can't be removed.
    public private(set) var modes: [Mode]

    public init(modes: [Mode] = Mode.builtIns) {
        var list = modes
        if !list.contains(where: { $0.id == Mode.generalID }) { list.insert(.general, at: 0) }
        self.modes = list
    }

    public var general: Mode { mode(id: Mode.generalID) ?? .general }

    public func mode(id: String) -> Mode? {
        modes.first { $0.id == id }
    }

    /// The mode that claims `bundleID` (first match wins), else General.
    public func mode(forApp bundleID: String?) -> Mode {
        guard let bundleID else { return general }
        return modes.first { $0.id != Mode.generalID && $0.apps.contains(bundleID) } ?? general
    }

    /// The effective mode: a manually locked mode wins; otherwise the frontmost app decides.
    public func resolve(app bundleID: String?, manualModeID: String?) -> Mode {
        if let manualModeID, let locked = mode(id: manualModeID) { return locked }
        return mode(forApp: bundleID)
    }

    /// Adds a new mode or replaces the one with the same id.
    public mutating func upsert(_ mode: Mode) {
        if let i = modes.firstIndex(where: { $0.id == mode.id }) { modes[i] = mode } else { modes.append(mode) }
    }

    /// Removes a custom mode. General can't be removed; built-ins can be (restore with
    /// `resetBuiltIns`).
    public mutating func remove(id: String) {
        guard id != Mode.generalID else { return }
        modes.removeAll { $0.id == id }
    }

    /// Makes `bundleID` switch to `modeID`, removing it from any other mode.
    /// Assigning to General just unassigns it.
    public mutating func assign(app bundleID: String, to modeID: String) {
        for i in modes.indices { modes[i].apps.removeAll { $0 == bundleID } }
        guard modeID != Mode.generalID, let i = modes.firstIndex(where: { $0.id == modeID }) else { return }
        modes[i].apps.append(bundleID)
    }

    /// Restores the built-in presets' settings (custom modes are kept).
    public mutating func resetBuiltIns() {
        for builtIn in Mode.builtIns { upsert(builtIn) }
    }
}
