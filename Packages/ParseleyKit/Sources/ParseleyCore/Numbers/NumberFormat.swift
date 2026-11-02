/// How numbers are written: which character groups thousands and which marks decimals.
/// Chosen per mode, so Excel in a German setup and SQL work can use different formats.
public enum NumberFormat: String, Codable, CaseIterable, Sendable {
    /// 1,204.50 (US, UK, most of Asia)
    case us
    /// 1.204,50 (Germany, Spain, Italy, Brazil, …)
    case european

    public var decimalSeparator: String { self == .us ? "." : "," }
    public var groupingSeparator: String { self == .us ? "," : "." }

    public var displayName: String {
        switch self {
        case .us: "1,204.50"
        case .european: "1.204,50"
        }
    }
}
