import ParseleyCore
import SwiftUI

/// The table viewer window: filter, sort by clicking a header, tick the columns to copy,
/// totals of numeric columns at the bottom (click one to copy it).
struct TableViewerView: View {
    @Bindable var model: TableViewerModel
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let table = model.visible {
                grid(table)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "tablecells.badge.ellipsis").font(.system(size: 32, weight: .light))
                        .foregroundStyle(Theme.amber)
                    Text("This clip isn't a table").font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Tables need at least two rows and two columns, separated by tabs, commas, semicolons or pipes.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(red: 9 / 255, green: 12 / 255, blue: 24 / 255))
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.mint)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.bottom, 44)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .background {
            Button("") { filterFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            ParseleyLogo(size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(verbatim: model.rowCountText).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: 300, alignment: .leading)
            Spacer()
            if model.source != nil {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Theme.textTertiary)
                    TextField("", text: $model.filter, prompt: Text("Filter rows").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain).focused($filterFocused).frame(width: 160)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .glassCard(radius: 8)
                Toggle("Header", isOn: $model.includeHeader)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Include the header row when copying")
                    .disabled(!(model.source?.hasHeader ?? false))
                TransformChip(title: "Copy TSV", icon: "tablecells") { model.copy(as: .tsv) }
                    .help("Tab-separated: pastes into Excel, Numbers and Google Sheets as cells")
                TransformChip(title: "Copy CSV", icon: "doc.text") { model.copy(as: .csv) }
            }
        }
        .padding(.leading, 80)   // room for the window buttons (transparent title bar)
        .padding(.trailing, 14)
        .frame(height: 52)
    }

    // MARK: Grid

    private func grid(_ table: DataTable) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders, .sectionFooters]) {
                Section {
                    ForEach(Array(table.rows.prefix(TableViewerModel.maxDrawnRows).enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(0..<table.columnCount, id: \.self) { column in
                                cell(row[column], column: column)
                            }
                        }
                        .background(index % 2 == 0 ? Color.white.opacity(0.025) : .clear)
                    }
                    if table.rows.count > TableViewerModel.maxDrawnRows {
                        Text(verbatim: "Showing the first \(TableViewerModel.maxDrawnRows) rows. Copy includes all \(table.rows.count).")
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(10)
                    }
                } header: {
                    headerRow(table)
                } footer: {
                    footerRow(table)
                }
            }
        }
    }

    private func cell(_ text: String, column: Int) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12.5, design: model.numericColumns[column] ? .monospaced : .default))
            .foregroundStyle(model.selectedColumns.contains(column) ? Theme.textPrimary : Theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: model.columnWidths[column], alignment: model.numericColumns[column] ? .trailing : .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .textSelection(.enabled)
            .help(text.count > 30 ? text : "")
    }

    private func headerRow(_ table: DataTable) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<table.columnCount, id: \.self) { column in
                HStack(spacing: 6) {
                    Button { model.toggleColumn(column) } label: {
                        Image(systemName: model.selectedColumns.contains(column) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(model.selectedColumns.contains(column) ? Theme.cyan : Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Include this column when copying")
                    Button { model.toggleSort(column) } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: table.header[column]).lineLimit(1)
                            if model.sortColumn == column {
                                Image(systemName: model.ascending ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Sort by \(table.header[column])")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: model.columnWidths[column], alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(Color(red: 16 / 255, green: 22 / 255, blue: 40 / 255))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func footerRow(_ table: DataTable) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<table.columnCount, id: \.self) { column in
                Group {
                    if let stats = model.columnStats[column],
                       let sum = stats.items(format: model.format).first(where: { $0.label == "Sum" }),
                       let avg = stats.items(format: model.format).first(where: { $0.label == "Average" }) {
                        Button { model.copySum(of: column) } label: {
                            Text(verbatim: "Σ \(sum.display)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.numberEmphasis)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Average \(avg.display) · \(stats.count) values · click to copy the sum")
                    } else {
                        Text(" ")
                    }
                }
                .frame(width: model.columnWidths[column], alignment: model.numericColumns[column] ? .trailing : .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(Color(red: 16 / 255, green: 22 / 255, blue: 40 / 255))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
