/// The hands-on welcome tour: a list of steps, each completed by actually doing the thing
/// (copying numbers, opening the panel, starting a series…). The app reports what the
/// user did as `Event`s; the tour works out which steps are done and what comes next.
///
/// Steps can be completed in any order (pressing ⌘⇧V early still counts), skipped, or
/// revisited. Plain logic, so it's unit-tested.
public struct WelcomeTour: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        case copyNumbers, openPanel, copyStat, startSeries, feedSeries, commandBar, saveTotal, autoPaste

        public var title: String {
            switch self {
            case .copyNumbers: "Copy some numbers"
            case .openPanel: "Open your history"
            case .copyStat: "Get a number out"
            case .startSeries: "Start a running total"
            case .feedSeries: "Feed it numbers"
            case .commandBar: "Try the command bar"
            case .saveTotal: "Save the total"
            case .autoPaste: "Turn on auto-paste"
            }
        }
    }

    public enum Event: Sendable {
        /// A copy containing two or more numbers was captured.
        case copiedNumbers
        case openedPanel
        /// A stat tile was clicked or ⌘1–⌘6 pressed.
        case copiedStat
        case startedSeries
        /// The running series now holds three or more values.
        case seriesHasThreeValues
        case ranCommand
        /// A series ended and its total was saved to history.
        case savedSeriesTotal
        case autoPasteEnabled

        var step: Step {
            switch self {
            case .copiedNumbers: .copyNumbers
            case .openedPanel: .openPanel
            case .copiedStat: .copyStat
            case .startedSeries: .startSeries
            case .seriesHasThreeValues: .feedSeries
            case .ranCommand: .commandBar
            case .savedSeriesTotal: .saveTotal
            case .autoPasteEnabled: .autoPaste
            }
        }
    }

    /// The numbers offered on the first step: a column as it comes out of a spreadsheet.
    public static let sampleText = "1,204.50\n300\n(12)"
    /// Values offered as one-click copies on the "feed it numbers" step.
    public static let seriesSamples = ["10", "20", "30"]

    public private(set) var completed: Set<Step> = []
    public private(set) var skipped: Set<Step> = []
    /// The step on screen; nil once the tour reached the end.
    public private(set) var current: Step? = Step.allCases.first

    public init() {}

    public var isFinished: Bool { current == nil }
    public var doneCount: Int { completed.count }
    public var total: Int { Step.allCases.count }

    public func isDone(_ step: Step) -> Bool { completed.contains(step) }
    public func isSkipped(_ step: Step) -> Bool { skipped.contains(step) && !completed.contains(step) }

    /// Records something the user did. Returns true if it completed the step on screen
    /// (the UI then celebrates briefly and calls `advance()`).
    @discardableResult
    public mutating func record(_ event: Event) -> Bool {
        let step = event.step
        let isNew = completed.insert(step).inserted
        skipped.remove(step)
        return isNew && step == current
    }

    /// Moves to the next step that isn't done yet (wrapping past the end finishes).
    public mutating func advance() {
        guard let current else { return }
        let later = Step.allCases.filter { $0.rawValue > current.rawValue }
        self.current = later.first { !completed.contains($0) }
    }

    /// "Skip": leave this step undone and move on.
    public mutating func skip() {
        guard let current else { return }
        if !completed.contains(current) { skipped.insert(current) }
        advance()
    }

    /// One step back (also from the end screen).
    public mutating func back() {
        guard let current else {
            self.current = Step.allCases.last
            return
        }
        self.current = Step(rawValue: max(0, current.rawValue - 1))
    }

    /// Jump to any step (clicking it in the list).
    public mutating func go(to step: Step) {
        current = step
    }

    /// Straight to the end screen.
    public mutating func finish() {
        current = nil
    }
}
