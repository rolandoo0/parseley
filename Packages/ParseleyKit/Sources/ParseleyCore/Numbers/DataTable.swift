import Foundation

/// A copied table (CSV, TSV, semicolon- or pipe-separated) for the table viewer: parsed
/// with quoting rules, with a header row when there is one, numeric columns detected,
/// and sorting, filtering, stats and export.
public struct DataTable: Equatable, Sendable {
    public enum Delimiter: Character, Sendable, CaseIterable {
        case tab = "\t", comma = ",", semicolon = ";", pipe = "|"

        public var name: String {
            switch self {
            case .tab: "TSV"
            case .comma: "CSV"
            case .semicolon: "semicolon-separated"
            case .pipe: "pipe-separated"
            }
        }
    }

    public enum ExportFormat: Sendable { case tsv, csv }

    /// Column names (generated "Column 1"… when the text has no header row).
    public var header: [String]
    public var hasHeader: Bool
    public var rows: [[String]]
    public var delimiter: Delimiter

    public var columnCount: Int { header.count }
    /// Header (if any) and rows, as in the source.
    public var allRows: [[String]] { hasHeader ? [header] + rows : rows }

    /// Parses `text` if it has at least 2 rows and 2 columns; nil otherwise.
    /// - Parameter detectHeader: false treats every line as data.
    public static func parse(_ text: String, format: NumberFormat = .us, detectHeader: Bool = true) -> DataTable? {
        guard let delimiter = detectDelimiter(text, format: format) else { return nil }
        let records = split(text, delimiter: delimiter.rawValue).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard records.count >= 2 else { return nil }
        let width = records.map(\.count).max() ?? 0
        guard width >= 2 else { return nil }
        let padded = records.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } + Array(repeating: "", count: width - $0.count) }

        let parser = NumberParser(format: format)
        let firstHasNumbers = padded[0].contains { !$0.isEmpty && parser.parseWhole($0) != nil }
        let header = detectHeader && !firstHasNumbers
        return DataTable(
            header: header ? padded[0] : (1...width).map { "Column \($0)" },
            hasHeader: header,
            rows: header ? Array(padded.dropFirst()) : padded,
            delimiter: delimiter
        )
    }

    /// Tabs win; then commas, semicolons, pipes (semicolons before commas with decimal
    /// commas). A delimiter counts if the first row and most rows have 2+ fields with it.
    static func detectDelimiter(_ text: String, format: NumberFormat) -> Delimiter? {
        let sample = String(text.prefix(20_000))
        let order: [Delimiter] = format == .european ? [.tab, .semicolon, .pipe, .comma] : [.tab, .comma, .semicolon, .pipe]
        for delimiter in order {
            // Quote-aware records, so a quoted field with a line break doesn't confuse it.
            let records = split(sample, delimiter: delimiter.rawValue)
                .filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
                .prefix(50)
            guard records.count >= 2, let first = records.first, first.count >= 2 else { continue }
            let wide = records.filter { $0.count >= 2 }.count
            if wide * 4 >= records.count * 3 { return delimiter }   // 75% of rows
        }
        return nil
    }

    /// RFC 4180 splitting: quoted fields may contain the delimiter, newlines and "" for a quote.
    static func split(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let ch = next() {
            if inQuotes {
                if ch == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && field.trimmingCharacters(in: .whitespaces).isEmpty {
                field = ""
                inQuotes = true
            } else if ch == delimiter {
                record.append(field)
                field = ""
            } else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                record.append(field)
                records.append(record)
                record = []
                field = ""
            } else {
                field.append(ch)
            }
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    // MARK: - Columns

    /// True when most non-empty cells in the column are numbers.
    public func isNumeric(_ column: Int, format: NumberFormat = .us) -> Bool {
        let parser = NumberParser(format: format)
        let cells = rows.map { $0[column] }.filter { !$0.isEmpty }
        guard !cells.isEmpty else { return false }
        let numeric = cells.filter { parser.parseWhole($0) != nil }.count
        return numeric * 5 >= cells.count * 4   // 80%
    }

    /// The column's numbers (cells that aren't numbers are skipped).
    public func numbers(in column: Int, format: NumberFormat = .us) -> [ParsedNumber] {
        let parser = NumberParser(format: format)
        return rows.compactMap { parser.parseWhole($0[column]) }
    }

    public func stats(for column: Int, format: NumberFormat = .us) -> NumberStats? {
        let numbers = numbers(in: column, format: format)
        return NumberStats(values: numbers.map(\.value), inputFractionDigits: numbers.map(\.fractionDigits).max() ?? 0)
    }

    // MARK: - Sorting, filtering, exporting

    /// Rows sorted by a column: numerically for numeric columns, otherwise alphabetically
    /// (case- and accent-insensitive, "item 2" before "item 10"). Empty cells go last.
    public func sorted(by column: Int, ascending: Bool, format: NumberFormat = .us) -> DataTable {
        var copy = self
        let parser = NumberParser(format: format)
        let numeric = isNumeric(column, format: format)
        copy.rows = rows.enumerated().sorted { a, b in
            let x = a.element[column], y = b.element[column]
            if x.isEmpty != y.isEmpty { return !x.isEmpty }   // empties last
            if numeric, let nx = parser.parseWhole(x)?.value, let ny = parser.parseWhole(y)?.value, nx != ny {
                return ascending ? nx < ny : nx > ny
            }
            let order = x.compare(y, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
            if order == .orderedSame { return a.offset < b.offset }   // stable
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.element)
        return copy
    }

    /// Rows with a cell containing `query` (case-insensitive). Empty query keeps all.
    public func filtered(_ query: String) -> DataTable {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return self }
        var copy = self
        copy.rows = rows.filter { row in row.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        return copy
    }

    /// The chosen columns (all if nil) as TSV or CSV, with the header row if there is one.
    public func export(columns: [Int]? = nil, as format: ExportFormat, includeHeader: Bool = true) -> String {
        let picked = columns ?? Array(0..<columnCount)
        var lines: [[String]] = []
        if includeHeader && hasHeader { lines.append(picked.map { header[$0] }) }
        lines += rows.map { row in picked.map { row[$0] } }
        switch format {
        case .tsv:
            return lines.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }.joined(separator: "\n")
        case .csv:
            return lines.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\n")
        }
    }

    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
