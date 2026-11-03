import Foundation
import Observation
import ParseleyCore

/// User preferences, persisted in UserDefaults (a small key-value store macOS keeps per
/// app, in ~/Library/Preferences). Changing any property saves it and calls `onChange`,
/// which AppEnvironment uses to push new values into the running services.
@MainActor
@Observable
final class AppSettings {
    /// Max unpinned clips kept in history.
    var historyLimit: Int { didSet { changed() } }
    /// Bundle ids whose copies are never stored.
    var excludedBundleIDs: [String] { didSet { changed() } }
    /// Ask to start a new series after this many idle minutes. 0 = off.
    var idleGapMinutes: Int { didSet { changed() } }
    /// Ask to start a new series when numbers start coming from another app.
    var askOnAppSwitch: Bool { didSet { changed() } }
    /// Which result "paste series result" pastes: a stat label ("Sum", "Average"…) or
    /// `followMode` for the current mode's main stat.
    var seriesPasteStat: String { didSet { changed() } }
    /// Currency totals are converted to this one ("USD").
    var baseCurrency: String { didSet { changed() } }
    /// Manual exchange rates: 1 unit of the key currency = value × base currency, as typed.
    var exchangeRates: [String: String] { didSet { changed() } }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    static let historyLimitChoices = [100, 250, 500, 1_000, 2_500, 5_000, 10_000]
    static let idleGapChoices = [0, 5, 10, 15, 30, 60]
    static let followMode = "mode"
    static let seriesPasteChoices = [followMode, "Sum", "Average", "Median", "Count", "Min", "Max"]

    private enum Key {
        static let historyLimit = "historyLimit"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let idleGapMinutes = "series.idleGapMinutes"
        static let askOnAppSwitch = "series.askOnAppSwitch"
        static let seriesPasteStat = "series.pasteStat"
        static let baseCurrency = "currency.base"
        static let exchangeRates = "currency.rates"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        historyLimit = defaults.object(forKey: Key.historyLimit) as? Int ?? 1_000
        excludedBundleIDs = defaults.stringArray(forKey: Key.excludedBundleIDs) ?? []
        idleGapMinutes = defaults.object(forKey: Key.idleGapMinutes) as? Int ?? 10
        askOnAppSwitch = defaults.object(forKey: Key.askOnAppSwitch) as? Bool ?? false
        seriesPasteStat = defaults.string(forKey: Key.seriesPasteStat) ?? Self.followMode
        baseCurrency = defaults.string(forKey: Key.baseCurrency) ?? "USD"
        exchangeRates = defaults.dictionary(forKey: Key.exchangeRates) as? [String: String] ?? [:]
    }

    /// The rates that parse as positive numbers ("1.08" or "1,08").
    var parsedRates: [String: Decimal] {
        exchangeRates.compactMapValues { text in
            let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard let rate = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), rate > 0 else { return nil }
            return rate
        }
    }

    var privacyPolicy: PrivacyPolicy {
        PrivacyPolicy(excludedBundleIDs: Set(excludedBundleIDs))
    }

    var seriesRules: SeriesRules {
        var rules = SeriesRules()
        rules.idleGap = idleGapMinutes > 0 ? TimeInterval(idleGapMinutes * 60) : nil
        rules.askOnAppSwitch = askOnAppSwitch
        return rules
    }

    private func changed() {
        defaults.set(historyLimit, forKey: Key.historyLimit)
        defaults.set(excludedBundleIDs, forKey: Key.excludedBundleIDs)
        defaults.set(idleGapMinutes, forKey: Key.idleGapMinutes)
        defaults.set(askOnAppSwitch, forKey: Key.askOnAppSwitch)
        defaults.set(seriesPasteStat, forKey: Key.seriesPasteStat)
        defaults.set(baseCurrency, forKey: Key.baseCurrency)
        defaults.set(exchangeRates, forKey: Key.exchangeRates)
        onChange?()
    }
}
