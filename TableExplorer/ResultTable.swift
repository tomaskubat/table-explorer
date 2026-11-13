import SwiftUI

/// The result viewer uses the same column sizing and row rhythm as an editable table.
/// Columns are identified by position: a SELECT may return duplicate aliases.
struct ResultTable: NSViewRepresentable {
    let result: QueryResult
    @Binding var selected: Int?
    var selectableText = false
    @AppStorage("gridFontSize", store: BrowserPreferences.defaults) private var fontSize = 14.0

    @TableStylePreference private var style

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        GridAppearance.configure(table)
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.selectCellText(_:))
        table.setAccessibilityLabel("Query Results")
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        style.apply(to: table, scroll: scroll)
        let c = context.coordinator
        let columnsChanged = c.columns != result.columns
        let reload = columnsChanged || c.parent.result.rows != result.rows || c.parent.selectableText != selectableText || c.size != fontSize || c.style != style
        c.applying = true; defer { c.applying = false }
        c.parent = self; c.size = fontSize; c.style = style
        table.rowHeight = max(22, fontSize + 14)
        if columnsChanged {
            c.columns = result.columns
            for col in table.tableColumns { table.removeTableColumn(col) }
            for (index, name) in result.columns.enumerated() {
                let column = GridAppearance.column(name, index: index, rows: result.rows, fontSize: fontSize, family: style.family)
                column.isEditable = false
                table.addTableColumn(column)
            }
        }
        if reload { table.reloadData() }
        let selection = selected.flatMap { result.rows.indices.contains($0) ? IndexSet(integer: $0) : nil } ?? []
        if table.selectedRowIndexes != selection { table.selectRowIndexes(selection, byExtendingSelection: false) }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: ResultTable
        var columns: [String] = []
        var style = TableStyle()
        var size = 0.0
        var applying = false
        init(_ parent: ResultTable) { self.parent = parent }
        @objc func selectCellText(_ table: NSTableView) {
            guard parent.selectableText, table.clickedRow >= 0, table.clickedColumn >= 0,
                  let cell = table.view(atColumn: table.clickedColumn, row: table.clickedRow, makeIfNecessary: true) as? NSTableCellView else { return }
            // The table restores its first responder after handling the double click.
            DispatchQueue.main.async { [weak field = cell.textField] in field?.selectText(nil) }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.result.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let col = tableColumn.flatMap({ Int($0.identifier.rawValue) }),
                  parent.result.rows.indices.contains(row), parent.result.rows[row].indices.contains(col) else { return nil }
            let cell = GridAppearance.cell(in: tableView)
            let value = parent.result.rows[row][col]
            GridAppearance.show(value, in: cell, size: size, style: style)
            cell.textField?.isSelectable = parent.selectableText
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

    static func column(_ name: String, index: Int, rows: [[SQLValue]], fontSize: Double, family: String = "System", savedWidth: CGFloat? = nil) -> NSTableColumn {
        let model = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
        model.title = name; model.minWidth = 50; model.headerCell.alignment = .center
        model.width = savedWidth ?? width(name, index: index, rows: rows, fontSize: fontSize, family: family)
        model.resizingMask = .userResizingMask
        return model
    }

    static func width(_ name: String, index: Int, rows: [[SQLValue]], fontSize: Double, family: String = "System") -> CGFloat {
        // Sample only on creation. Paging preserves manual column widths.
        let font = FontChoice.font(family, fontSize)
        let widths = rows.prefix(40).compactMap { row -> CGFloat? in
            guard row.indices.contains(index) else { return nil }
            let sample: String
            if case .blob = row[index] { sample = "BLOB · 999 bytes" }
            else { sample = String(row[index].display.prefix(40)) }
            return (sample as NSString).size(withAttributes: [.font: font]).width
        }
        let header = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        return min(260, max(68, ceil(max(header, widths.max() ?? 0)) + 18))
    }

    static func cell(in table: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("GridValue")
        if let reused = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return reused }
        let cell = ValueCell(), field = NSTextField(labelWithString: "")
        cell.identifier = id
        field.lineBreakMode = .byTruncatingTail; cell.textField = field; cell.addSubview(field)
        return cell
    }

    private final class ValueCell: NSTableCellView {
        override func layout() {
            super.layout()
            guard let field = textField, let font = field.font else { return }
            let height = ceil(font.ascender - font.descender + font.leading) + 2
            field.frame = CGRect(x: 3, y: floor((bounds.height - height) / 2),
                                 width: max(0, bounds.width - 6), height: height)
        }
    }

    static func show(_ value: SQLValue, in cell: NSTableCellView, size: Double, prefix: String = "", style: TableStyle) {
        guard let field = cell.textField else { return }
        let text: String
        if case .blob(let bytes) = value { text = "BLOB · \(bytes.count) bytes" } else { text = value.display }
        field.font = FontChoice.font(style.family, size)
        field.stringValue = prefix + (text.isEmpty ? "EMPTY" : text)
        switch value {
        case .integer, .number: field.alignment = .right
        default: field.alignment = .left
        }
        field.textColor = style.palette.color(value == .null || text.isEmpty ? .empty : .cell)
        field.allowsExpansionToolTips = style.expand
        field.isEditable = false; field.isSelectable = false
        field.setAccessibilityLabel(text.isEmpty ? "Empty string" : text)
    }
}

struct TableStyle: Equatable {
    var family = "System", alternate = true, hideScrollers = true, expand = false
    var palette = InkPalette(Data())
    @MainActor func apply(to table: NSTableView, scroll: NSScrollView) {
        if table.usesAlternatingRowBackgroundColors != alternate { table.usesAlternatingRowBackgroundColors = alternate }
        if scroll.autohidesScrollers != hideScrollers { scroll.autohidesScrollers = hideScrollers }
        let scroller: NSScroller.Style = hideScrollers ? .overlay : .legacy
        if scroll.scrollerStyle != scroller { scroll.scrollerStyle = scroller }
    }
}

@propertyWrapper
struct TableStylePreference: DynamicProperty {
    @AppStorage("gridFont", store: BrowserPreferences.defaults) private var family = "System"
    @AppStorage("alternateRows", store: BrowserPreferences.defaults) private var alternating = true
    @AppStorage("autoHideScrollers", store: BrowserPreferences.defaults) private var hide = true
    @AppStorage("expandCells", store: BrowserPreferences.defaults) private var expand = false
    @AppStorage("customInks", store: BrowserPreferences.defaults) private var inks = Data()
    var wrappedValue: TableStyle { TableStyle(family: family, alternate: alternating, hideScrollers: hide, expand: expand, palette: InkPalette(inks)) }
}
