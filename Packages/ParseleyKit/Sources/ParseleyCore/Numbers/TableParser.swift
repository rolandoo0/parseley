import Foundation

/// One column of a copied spreadsheet range.
public struct TableColumn: Identifiable, Equatable, Sendable {
    /// 0-based position.
    public var index: Int
    public var id: Int { index }
    /// Header text if the range has a header row.
    public var header: String?
    /// Numbers found in the column's data cells (one per numeric cell).
    public var values: [Decimal]
    /// Non-empty data cells, numeric or not.
    public var filledCells: Int

    /// "Q1", or a spreadsheet-style letter ("A", "B", … "AA") when there's no header.
    public var name: String {
        if let header, !header.isEmpty { return header }
        return Self.letters(for: index)
    }

    /// Mostly numbers: at least one, and at least half of the filled cells.
    public var isNumeric: Bool {
        !values.isEmpty && values.count * 2 >= filledCells
    }

    public var stats: NumberStats? { NumberStats(values: values) }

    static func letters(for index: Int) -> String {
        var n = index + 1
        var result = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            result = String(UnicodeScalar(UInt8(65 + remainder))) + result
            n = (n - 1) / 26
        }
        return result
    }
}

/// A tab-separated range (what Excel, Numbers and Google Sheets put on the clipboard),
/// split into columns.
public struct ParsedTable: Equatable, Sendable {
    public var columns: [TableColumn]
    public var hasHeader: Bool
    /// Data rows (excluding the header).
    public var rowCount: Int

    public var numericColumns: [TableColumn] { columns.filter(\.isNumeric) }
}

public enum TableParser {
    /// Parses tab-separated text with at least two rows and two columns. Returns nil for
    /// anything else (single lines, single columns, no tabs).
    ///
    /// The first row is a header when none of its cells is a number but a later row has
    /// numbers ("Region / Q1 / Q2" above the figures).
    public static func parse(_ text: String, format: NumberFormat = .us) -> ParsedTable? {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }
        let rows = lines.map { $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) } }
        let width = rows.map(\.count).max() ?? 0
        guard width >= 2 else { return nil }

        let parser = NumberParser(format: format)
        func number(_ cell: String) -> Decimal? { cell.isEmpty ? nil : parser.parseWhole(cell)?.value }

        let firstRowHasNumbers = rows[0].contains { number($0) != nil }
        let laterRowsHaveNumbers = rows.dropFirst().contains { row in row.contains { number($0) != nil } }
        let hasHeader = !firstRowHasNumbers && laterRowsHaveNumbers
        let dataRows = hasHeader ? Array(rows.dropFirst()) : rows

        let columns = (0..<width).map { index -> TableColumn in
            let cells = dataRows.map { index < $0.count ? $0[index] : "" }.filter { !$0.isEmpty }
            return TableColumn(
                index: index,
                header: hasHeader && index < rows[0].count ? rows[0][index] : nil,
                values: cells.compactMap(number),
                filledCells: cells.count
            )
        }
        return ParsedTable(columns: columns, hasHeader: hasHeader, rowCount: dataRows.count)
    }
}
