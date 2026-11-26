import SwiftUI

/// The result viewer uses the same column sizing and row rhythm as an editable table.
/// Columns are identified by position: a SELECT may return duplicate aliases.
struct ResultTable: NSViewRepresentable {
    struct QueryOptions {
        let tab: WorkspaceTab
        let driver: DatabaseDriver
    }

    let result: QueryResult
    @Binding var selected: Int?
    var selectableText = false
    var query: QueryOptions?
    @AppStorage("gridFontSize", store: BrowserPreferences.defaults) private var fontSize = 14.0

    @TableStylePreference private var style

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table: NSTableView
        if query != nil {
            let grid = QueryTable()
            let header = QueryHeader()
            header.coordinator = context.coordinator
            grid.headerView = header
            grid.coordinator = context.coordinator
            grid.allowsMultipleSelection = true
            grid.allowsColumnReordering = false
            table = grid
        } else {
            table = NSTableView()
        }
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
        let rows = query.map { IndexSet($0.tab.selectedRows.filter(result.rows.indices.contains)) } ??
            (selected.flatMap { result.rows.indices.contains($0) ? IndexSet(integer: $0) : nil } ?? [])
        if table.selectedRowIndexes != rows { table.selectRowIndexes(rows, byExtendingSelection: false) }
        c.showSelectedColumn(in: table)
    }

    final class QueryTable: NSTableView {
        weak var coordinator: Coordinator?

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            return coordinator?.menu(in: self, row: row(at: point), column: column(at: point)) ?? super.menu(for: event)
        }

        override func mouseDown(with event: NSEvent) {
            coordinator?.clearColumnSelection(in: self)
            super.mouseDown(with: event)
        }

        @objc func copy(_ sender: Any?) { coordinator?.copySelection(in: self) }
    }

    final class QueryHeader: NSTableHeaderView {
        weak var coordinator: Coordinator?

        override func menu(for event: NSEvent) -> NSMenu? {
            let index = column(at: convert(event.locationInWindow, from: nil))
            guard let tableView else { return super.menu(for: event) }
            return coordinator?.menu(in: tableView, row: -1, column: index) ?? super.menu(for: event)
        }
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
            if parent.query != nil { highlight(cell, selected: col == parent.query?.tab.selectedResultColumn) }
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow >= 0 ? table.selectedRow : nil
            if let tab = parent.query?.tab {
                tab.selectedRows = Set(table.selectedRowIndexes)
                tab.focusedRow = row
                if row != nil { clearColumnSelection(in: table) }
            } else {
                parent.selected = row
            }
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let tab = parent.query?.tab, let column = Int(tableColumn.identifier.rawValue) else { return }
            tableView.window?.makeFirstResponder(tableView)
            tableView.deselectAll(nil)
            tab.selectedResultColumn = tab.selectedResultColumn == column ? nil : column
            showSelectedColumn(in: tableView)
        }

        func clearColumnSelection(in table: NSTableView) {
            guard let tab = parent.query?.tab, tab.selectedResultColumn != nil else { return }
            tab.selectedResultColumn = nil
            showSelectedColumn(in: table)
        }

        func showSelectedColumn(in table: NSTableView) {
            guard let query = parent.query else { return }
            let column = query.tab.selectedResultColumn
            let highlighted = column.flatMap { table.tableColumns.indices.contains($0) ? table.tableColumns[$0] : nil }
            guard table.highlightedTableColumn !== highlighted else { return }
            table.highlightedTableColumn = highlighted
            table.enumerateAvailableRowViews { view, _ in
                for index in 0..<view.numberOfColumns {
                    if let cell = view.view(atColumn: index) as? NSView { highlight(cell, selected: index == column) }
                }
            }
        }

        private func highlight(_ cell: NSView, selected: Bool) {
            if selected { cell.wantsLayer = true }
            cell.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor : nil
        }

        func copySelection(in table: NSTableView) {
            let result = parent.result
            if let column = parent.query?.tab.selectedResultColumn {
                copy(result, rows: IndexSet(integersIn: result.rows.indices), columns: IndexSet(integer: column), format: .text)
            } else if !table.selectedRowIndexes.isEmpty {
                copy(result, rows: table.selectedRowIndexes, columns: IndexSet(integersIn: result.columns.indices), format: .text)
            }
        }

        func menu(in table: NSTableView, row: Int, column: Int) -> NSMenu? {
            let result = parent.result
            guard let query = parent.query, result.columns.indices.contains(column) else { return nil }
            let allRows = IndexSet(integersIn: result.rows.indices)
            let allColumns = IndexSet(integersIn: result.columns.indices)
            let pickedColumn = IndexSet(integer: column)
            let menu = NSMenu(); menu.autoenablesItems = false
            if result.rows.indices.contains(row) {
                if query.tab.selectedResultColumn != column {
                    let pickedRows = table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : IndexSet(integer: row)
                    GridContextMenu.item("Copy", in: menu) { self.copy(result, rows: pickedRows, columns: allColumns, format: .text) }
                    addFormats("Copy Rows As", in: menu, result: result, rows: pickedRows, columns: allColumns)
                } else {
                    GridContextMenu.item("Copy", in: menu) { self.copy(result, rows: allRows, columns: pickedColumn, format: .text) }
                }
                let value = result.rows[row][column]
                GridContextMenu.item("Copy Cell Value", in: menu) { GridClipboard.copy(value.display) }
            } else if row == -1 {
                GridContextMenu.item("Copy", in: menu, enabled: !allRows.isEmpty) {
                    self.copy(result, rows: allRows, columns: pickedColumn, format: .text)
                }
            }
            addFormats("Copy Column As", in: menu, result: result, rows: allRows, columns: pickedColumn)
            return menu
        }

        private func addFormats(_ title: String, in menu: NSMenu, result: QueryResult, rows: IndexSet, columns: IndexSet) {
            let formats = GridContextMenu.submenu(title, in: menu)
            for format in RowCopyFormat.allCases {
                GridContextMenu.item(format.rawValue, in: formats) { self.copy(result, rows: rows, columns: columns, format: format) }
            }
            GridContextMenu.item("SQL Dump", in: formats) { self.copy(result, rows: rows, columns: columns, format: nil) }
        }

        private func copy(_ result: QueryResult, rows: IndexSet, columns: IndexSet, format: RowCopyFormat?) {
            guard let query = parent.query else { return }
            let indices = columns.filter(result.columns.indices.contains)
            var fields = indices.map { result.columns[$0] }
            let values = rows.filter(result.rows.indices.contains).map { row in indices.map { result.rows[row][$0] } }
            if format == nil || format == .json || format == .sql { fields = GridClipboard.uniqueFields(fields) }
            do {
                let text: String
                if let format {
                    text = try GridClipboard.encode(values, fields: fields, format: format, table: "query_result", driver: query.driver)
                } else {
                    text = try GridClipboard.dump(values, fields: fields, table: "query_result", driver: query.driver)
                }
                GridClipboard.copy(text)
            } catch {
                query.tab.error = error.localizedDescription
            }
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
