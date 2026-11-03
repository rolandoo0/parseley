import Foundation
import Observation
import ParseleyCore

/// State behind the table viewer: the parsed table, filter, sort, which columns to copy.
@MainActor
@Observable
final class TableViewerModel {
    let title: String
    let format: NumberFormat
    /// Nil when the text isn't a table.
    let source: DataTable?

    var filter = "" { didSet { if filter != oldValue { refresh() } } }
    private(set) var sortColumn: Int?
    private(set) var ascending = true
    /// Columns included when copying (all by default).
    private(set) var selectedColumns: Set<Int>
    var includeHeader = true
    private(set) var toast: String?

    /// Filtered and sorted rows (what the grid shows).
    private(set) var visible: DataTable?
    /// Per-column stats of the visible rows (nil for text columns).
    private(set) var columnStats: [NumberStats?] = []
    let numericColumns: [Bool]
    let columnWidths: [Double]

    /// Rows drawn at most (the copy buttons always use every visible row).
    static let maxDrawnRows = 5_000

    @ObservationIgnored var copyText: (String) -> Void = { _ in }
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(text: String, title: String, format: NumberFormat) {
        self.title = title
        self.format = format
        let table = DataTable.parse(text, format: format)
        source = table
        selectedColumns = Set(0..<(table?.columnCount ?? 0))
        numericColumns = table.map { t in (0..<t.columnCount).map { t.isNumeric($0, format: format) } } ?? []
        columnWidths = table.map { t in
            (0..<t.columnCount).map { column in
                let longest = ([t.header[column]] + t.rows.prefix(300).map { $0[column] }).map(\.count).max() ?? 0
                return min(320, max(70, Double(longest) * 7.6 + 30))
            }
        } ?? []
        refresh()
    }

    var rowCountText: String {
        guard let source, let visible else { return "" }
        let kind = source.delimiter.name
        return visible.rows.count == source.rows.count
            ? "\(source.rows.count) rows · \(source.columnCount) columns · \(kind)"
            : "\(visible.rows.count) of \(source.rows.count) rows · \(kind)"
    }

    // MARK: - Actions

    /// Click a header: sort by it; click again to reverse; a third time to unsort.
    func toggleSort(_ column: Int) {
        if sortColumn != column {
            sortColumn = column
            ascending = !numericColumns[column]   // numbers: biggest first
        } else if ascending == !numericColumns[column] {
            ascending.toggle()
        } else {
            sortColumn = nil
        }
        refresh()
    }

    func toggleColumn(_ column: Int) {
        if selectedColumns.contains(column) {
            guard selectedColumns.count > 1 else { return show("Keep at least one column") }
            selectedColumns.remove(column)
        } else {
            selectedColumns.insert(column)
        }
    }

    func selectAllColumns() {
        selectedColumns = Set(0..<(source?.columnCount ?? 0))
    }

    func copy(as exportFormat: DataTable.ExportFormat) {
        guard let visible else { return }
        let columns = selectedColumns.sorted()
        copyText(visible.export(columns: columns, as: exportFormat, includeHeader: includeHeader))
        let what = columns.count == visible.columnCount ? "table" : "\(columns.count) column\(columns.count == 1 ? "" : "s")"
        show("Copied \(what) as \(exportFormat == .csv ? "CSV" : "TSV") (\(visible.rows.count) rows)")
    }

    func copySum(of column: Int) {
        guard let stats = columnStats[column], let sum = stats.items(format: format).first(where: { $0.label == "Sum" }) else { return }
        copyText(sum.copyText)
        show("Copied sum of \(source?.header[column] ?? "column"): \(sum.display)")
    }

    // MARK: - Private

    private func refresh() {
        guard let source else { return }
        var table = source.filtered(filter)
        if let sortColumn { table = table.sorted(by: sortColumn, ascending: ascending, format: format) }
        visible = table
        columnStats = (0..<table.columnCount).map { numericColumns[$0] ? table.stats(for: $0, format: format) : nil }
    }

    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
