import SwiftUI

/// The result viewer uses the same column sizing and row rhythm as an editable table.
/// Columns are identified by position: a SELECT may return duplicate aliases.
struct ResultTable: NSViewRepresentable {
    let result: QueryResult
    @Binding var selected: Int?
    @AppStorage("gridFontSize", store: BrowserPreferences.defaults) private var fontSize = 14.0

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        GridAppearance.configure(table)
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.setAccessibilityLabel("Query Results")
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let c = context.coordinator
        let columnsChanged = c.columns != result.columns
        let reload = columnsChanged || c.parent.result.rows != result.rows || c.size != fontSize
        c.applying = true; defer { c.applying = false }
        c.parent = self; c.size = fontSize
        table.rowHeight = max(22, fontSize + 14)
        if columnsChanged {
            c.columns = result.columns
            for col in table.tableColumns { table.removeTableColumn(col) }
            for (index, name) in result.columns.enumerated() {
                table.addTableColumn(GridAppearance.column(name, index: index, rows: result.rows, fontSize: fontSize))
            }
        }
        if reload { table.reloadData() }
        let selection = selected.flatMap { result.rows.indices.contains($0) ? IndexSet(integer: $0) : nil } ?? []
        if table.selectedRowIndexes != selection { table.selectRowIndexes(selection, byExtendingSelection: false) }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: ResultTable
        var columns: [String] = []
        var size = 0.0
        var applying = false
        init(_ parent: ResultTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.result.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let col = tableColumn.flatMap({ Int($0.identifier.rawValue) }),
                  parent.result.rows.indices.contains(row), parent.result.rows[row].indices.contains(col) else { return nil }
            let cell = GridAppearance.cell(in: tableView)
            let value = parent.result.rows[row][col]
            GridAppearance.show(value, in: cell, size: size)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table = notification.object as? NSTableView else { return }
            parent.selected = table.selectedRow >= 0 ? table.selectedRow : nil
        }
    }
}

@MainActor enum GridAppearance {
    static func configure(_ table: NSTableView) {
        table.usesAlternatingRowBackgroundColors = true; table.style = .fullWidth
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 1, height: 0)
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.26)
        table.gridStyleMask = [.solidVerticalGridLineMask]
    }

    static func column(_ name: String, index: Int, rows: [[SQLValue]], fontSize: Double) -> NSTableColumn {
        let model = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
        model.title = name; model.minWidth = 50; model.headerCell.alignment = .center
        // Sample only on creation. Paging preserves manual column widths.
        let font = NSFont.systemFont(ofSize: fontSize)
        let widths = rows.prefix(40).compactMap { row -> CGFloat? in
            guard row.indices.contains(index) else { return nil }
            let sample: String
            if case .blob = row[index] { sample = "BLOB · 999 bytes" }
            else { sample = String(row[index].display.prefix(40)) }
            return (sample as NSString).size(withAttributes: [.font: font]).width
        }
        let header = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        model.width = min(260, max(68, ceil(max(header, widths.max() ?? 0)) + 18))
        model.resizingMask = .userResizingMask
        return model
    }

    static func cell(in table: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("GridValue")
        if let reused = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return reused }
        let cell = NSTableCellView(), field = NSTextField(labelWithString: "")
        cell.identifier = id; field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail; cell.textField = field; cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    static func show(_ value: SQLValue, in cell: NSTableCellView, size: Double, prefix: String = "") {
        guard let field = cell.textField else { return }
        let text: String
        if case .blob(let bytes) = value { text = "BLOB · \(bytes.count) bytes" } else { text = value.display }
        field.font = .systemFont(ofSize: size)
        field.stringValue = prefix + (text.isEmpty ? "EMPTY" : text)
        switch value {
        case .integer, .number: field.alignment = .right
        default: field.alignment = .left
        }
        field.textColor = value == .null || text.isEmpty ? .tertiaryLabelColor : .labelColor
        field.isEditable = false; field.isSelectable = false
        field.setAccessibilityLabel(text.isEmpty ? "Empty string" : text)
    }
}
