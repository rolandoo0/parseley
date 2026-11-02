/// What kind of content a clip holds. Stored in the database as its raw string, so
/// adding cases later needs no migration. Unknown values read back as `.text`.
public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text
    case url
    case email
    case json
    /// Tab-separated rows with a consistent column count (e.g. a range copied from a spreadsheet).
    case table
    /// Exactly one number. (Detected from M3 on, once the number parser exists.)
    case number
    /// Two or more numbers: the stats strip applies. (Detected from M3 on.)
    case numberList

    public init(storedValue: String) {
        self = ClipKind(rawValue: storedValue) ?? .text
    }

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .url: "Link"
        case .email: "Email"
        case .json: "JSON"
        case .table: "Table"
        case .number: "Number"
        case .numberList: "Numbers"
        }
    }
}
