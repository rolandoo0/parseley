import Foundation

// Shapes for pasting into a spreadsheet: one cell per line goes down a column, tabs go
// across a row, and a transposed range swaps rows and columns.

/// Items one per line: pastes down a column.
public struct AsColumnTransform: Transform {
    public let id = "paste.column"
    public let title = "As column"
    public var format: NumberFormat
    public init(format: NumberFormat = .us) { self.format = format }

    public func apply(_ input: String) throws -> String {
        let items = Self.cells(input, format: format)
        guard !items.isEmpty else { throw TransformError.noItems }
        return items.joined(separator: "\n")
    }

    /// Every cell of a table, or every item of a list, in reading order.
    static func cells(_ input: String, format: NumberFormat) -> [String] {
        if let table = DataTable.parse(input, format: format, detectHeader: false) {
            return table.allRows.flatMap { $0 }.filter { !$0.isEmpty }
        }
        return ItemSplitter.split(input, format: format).items
    }
}

/// Items separated by tabs: pastes across a row.
public struct AsRowTransform: Transform {
    public let id = "paste.row"
    public let title = "As row"
    public var format: NumberFormat
    public init(format: NumberFormat = .us) { self.format = format }

    public func apply(_ input: String) throws -> String {
        let items = AsColumnTransform.cells(input, format: format)
        guard !items.isEmpty else { throw TransformError.noItems }
        return items.joined(separator: "\t")
    }
}

/// Rows become columns (tab-separated, ready to paste into a sheet). A single row turns
/// into a column and vice versa.
public struct TransposeTransform: Transform {
    public let id = "table.transpose"
    public let title = "Transposed"
    public var format: NumberFormat
    public init(format: NumberFormat = .us) { self.format = format }

    public func apply(_ input: String) throws -> String {
        let rows: [[String]]
        if let table = DataTable.parse(input, format: format, detectHeader: false) {
            rows = table.allRows
        } else {
            let items = ItemSplitter.split(input, format: format)
            guard !items.items.isEmpty else { throw TransformError.noItems }
            // A list one per line is a column (it becomes a row); a list across a line is a
            // row (it becomes a column).
            rows = items.separator == .newline ? items.items.map { [$0] } : [items.items]
        }
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { throw TransformError.noItems }
        return (0..<width).map { column in
            rows.map { column < $0.count ? $0[column] : "" }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
