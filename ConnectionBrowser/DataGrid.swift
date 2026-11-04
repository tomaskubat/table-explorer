import AppKit
import SwiftUI

/// NSTableView supplies native multiple selection and virtualization. The
/// context-click location is independent of the selected rows.
struct DataGrid: NSViewRepresentable {
    let workspace: Workspace
    let tab: WorkspaceTab
    @AppStorage("gridFontSize", store: BrowserPreferences.defaults) private var gridFontSize = 12.0

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace, tab: tab) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let table = GridTable()
        table.handler = context.coordinator
        tab.grid = table
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 23
        table.style = .fullWidth; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.setAccessibilityLabel("Data Grid"); table.setAccessibilityIdentifier("Data Grid")
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let table = scroll.documentView as! GridTable
        context.coordinator.update(table, fontSize: gridFontSize)
    }

    final class GridTable: NSTableView {
        weak var handler: Coordinator?
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { handler?.workspace.focusArea = .grid }
            return result
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result && handler?.workspace.focusArea == .grid { handler?.workspace.focusArea = nil }
            return result
        }
        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let r = row(at: point), c = column(at: point)
            super.mouseDown(with: event)
            if r >= 0, tableColumns.indices.contains(c) {
                handler?.tab.focusedRow = r
                handler?.tab.focusedColumn = tableColumns[c].title
                needsDisplay = true
            }
            if event.clickCount == 2 && r >= 0 && c >= 0 { handler?.edit(in: self, row: r, column: c) }
        }
        override func rightMouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let menu = handler?.menu(row: row(at: point), column: column(at: point)) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        func restoreCellFocus() {
            guard let handler, let row = handler.tab.selected, row < numberOfRows else { return }
            scrollRowToVisible(row)
            if let column = tableColumns.firstIndex(where: { $0.title == handler.tab.focusedColumn }) { scrollColumnToVisible(column) }
            window?.makeFirstResponder(self)
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let handler, let row = handler.tab.selected, row < numberOfRows,
                  let column = tableColumns.firstIndex(where: { $0.title == handler.tab.focusedColumn }) else { return }
            let rect = frameOfCell(atColumn: column, row: row).insetBy(dx: 1.5, dy: 1.5)
            if rect.intersects(dirtyRect) {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
            }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, let handler, let row = handler.tab.selected,
               let column = tableColumns.firstIndex(where: { $0.title == handler.tab.focusedColumn }) {
                handler.edit(in: self, row: row, column: column); return
            }
            if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                handler?.workspace.showDetails.toggle()
            } else { super.keyDown(with: event) }
        }
        @objc func copy(_ sender: Any?) { handler?.copySelected(format: .text) }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        let workspace: Workspace
        let tab: WorkspaceTab
        var columns: [(index: Int, name: String)] = []
        var rows: [[SQLValue]] = []
        var markers: [Int: [String: String]] = [:]
        var fontSize = 12.0
        var applying = false
        var editing: (row: Int, column: String, draft: RowChange)?
        init(workspace: Workspace, tab: WorkspaceTab) { self.workspace = workspace; self.tab = tab }

        func update(_ table: GridTable, fontSize: Double) {
            let fontChanged = self.fontSize != fontSize
            self.fontSize = fontSize
            table.rowHeight = max(20, fontSize + 10)
            let display = tab.displayed
            let visible = display.columns.enumerated().filter { !tab.hiddenColumns.contains($0.element) }
            let newMarkers = tab.cellMarkers
            let changedColumns = columns.map(\.name) != visible.map(\.element) || columns.map(\.index) != visible.map(\.offset)
            applying = true
            defer { applying = false }
            if changedColumns {
                for column in table.tableColumns { table.removeTableColumn(column) }
                columns = visible.map { ($0.offset, $0.element) }
                for column in columns {
                    let model = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(column.index)))
                    model.title = column.name; model.minWidth = 55; model.width = 130
                    model.resizingMask = [.userResizingMask, .autoresizingMask]
                    table.addTableColumn(model)
                }
            }
            if changedColumns || fontChanged || display.rows != rows || markers != newMarkers {
                rows = display.rows; markers = newMarkers; table.reloadData()
            }
            let indices = IndexSet(tab.selectedRows.filter(rows.indices.contains))
            if indices != table.selectedRowIndexes { table.selectRowIndexes(indices, byExtendingSelection: false) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Int(tableColumn.identifier.rawValue),
                  rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
            let id = NSUserInterfaceItemIdentifier("DataCell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView(); cell.identifier = id
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingTail; field.delegate = self
                cell.textField = field; cell.addSubview(field)
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            let value = rows[row][column], name = tableColumn.title
            let text: String
            if case .blob(let bytes) = value { text = "BLOB · \(bytes.count) bytes" } else { text = value.display }
            let marker = markers[row]?[name]
            let prefix = marker == "minus.circle" ? "− " : marker == "plus.circle" ? "+ " : marker == nil ? "" : "✎ "
            cell.textField?.font = .systemFont(ofSize: fontSize)
            cell.textField?.stringValue = prefix + text
            cell.textField?.textColor = value == .null ? .secondaryLabelColor : .labelColor
            cell.textField?.isEditable = false; cell.textField?.isSelectable = false
            cell.textField?.setAccessibilityLabel(text.isEmpty ? "Empty string" : text)
            cell.textField?.setAccessibilityIdentifier("grid-\(row)-\(name)")
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table = notification.object as? NSTableView else { return }
            tab.selectedRows = Set(table.selectedRowIndexes)
        }
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard !tab.busy else { return }
            let name = tableColumn.title
            tab.descending = tab.sortColumn == name ? !tab.descending : false
            tab.sortColumn = name; tab.offset = 0
            Task { await workspace.load(tab) }
        }

        func edit(in table: NSTableView, row: Int, column: Int) {
            guard workspace.connected, tab.canEdit(row), columns.indices.contains(column),
                  let draft = tab.editRow(at: row),
                  let field = (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField else { return }
            let info = columns[column]
            guard tab.schema?.columns.first(where: { $0.name == info.name })?.generated == false else { return }
            let value = rows[row][info.index]
            if case .blob = value { tab.editor = draft; return }
            editing = (row, info.name, draft)
            field.stringValue = value == .null ? "" : value.display
            field.isEditable = true; field.isSelectable = true; field.selectText(nil)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let edit = editing, let field = notification.object as? NSTextField else { return }
            editing = nil
            field.isEditable = false; field.isSelectable = false
            let cancelled = (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
            if !cancelled {
                var draft = edit.draft
                draft.defaults.remove(edit.column)
                let new = SQLValue.text(field.stringValue)
                if let old = draft.original?[edit.column], old != .null && old.display == field.stringValue {
                    draft.changes.removeValue(forKey: edit.column)
                } else { draft.changes[edit.column] = new }
                tab.stage(draft)
            }
            if let table = field.superview?.superview?.superview as? NSTableView { table.reloadData() }
        }

        private func copy(_ value: String) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        }
        func copySelected(format: RowCopyFormat, fallback: Int? = nil) {
            let indices = tab.selectedRows.isEmpty ? fallback.map { [$0] } ?? [] : tab.selectedRows.sorted()
            let values = indices.filter(rows.indices.contains).map { i in columns.map { rows[i][$0.index] } }
            do { copy(try GridClipboard.encode(values, fields: columns.map(\.name), format: format, table: tab.title, driver: workspace.profile.driver)) }
            catch { tab.error = error.localizedDescription }
        }

        // NSMenuItem does not retain its target. The represented object owns
        // the callback for exactly as long as the context menu is alive.
        private final class Action: NSObject {
            let handler: @MainActor () -> Void
            init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
            @MainActor @objc func apply(_ sender: Any?) { handler() }
        }
        @discardableResult private func item(_ title: String, in menu: NSMenu, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let target = Action(action)
            let item = NSMenuItem(title: title, action: #selector(Action.apply(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = target; item.isEnabled = enabled; menu.addItem(item)
            return item
        }
        private func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
            let child = NSMenu(title: title); child.autoenablesItems = false
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: ""); entry.submenu = child; menu.addItem(entry)
            return child
        }

        func menu(row: Int, column: Int) -> NSMenu? {
            guard rows.indices.contains(row), columns.indices.contains(column) else { return nil }
            let field = columns[column], value = rows[row][field.index]
            let selected = tab.selectedRows.isEmpty ? Set([row]) : tab.selectedRows
            let metadata = tab.schema?.columns.first { $0.name == field.name }
            let writable = workspace.connected && tab.canEdit(row) && metadata?.generated == false
            let menu = NSMenu(); menu.autoenablesItems = false
            item("Quick Look Editor", in: menu) {
                if self.tab.selectedRows.isEmpty { self.tab.selected = row }
                if self.tab.selectedRows.contains(row) { self.tab.focusedRow = row; self.tab.focusedColumn = field.name }
                self.tab.cellEditor = CellEdit(column: field.name, value: value, draft: self.tab.editRow(at: row), writable: writable, nullable: metadata?.nullable == true)
            }
            item("Refresh", in: menu, enabled: workspace.connected) { Task { await self.workspace.load(self.tab) } }
            item("Paste", in: menu, enabled: writable && NSPasteboard.general.string(forType: .string) != nil) {
                if let text = NSPasteboard.general.string(forType: .string) { self.set(.text(text), row: row, column: field.name) }
            }
            item("Add Row", in: menu, enabled: workspace.connected && tab.canInsert) { self.tab.editor = RowChange(original: nil) }
            item("Duplicate", in: menu, enabled: workspace.connected && tab.canInsert) { self.tab.duplicate(selected) }
            let values = submenu("Set Value", in: menu)
            item("Empty String", in: values, enabled: writable) { self.set(.text(""), row: row, column: field.name) }
            item("NULL", in: values, enabled: writable && tab.schema?.columns.first(where: { $0.name == field.name })?.nullable == true) { self.set(.null, row: row, column: field.name) }
            item("Default", in: values, enabled: writable && (metadata?.defaultSQL != nil || metadata?.nullable == true || tab.draft(at: row)?.original == nil && row >= tab.result.rows.count)) {
                guard var draft = self.tab.editRow(at: row) else { return }
                draft.changes.removeValue(forKey: field.name)
                if draft.original != nil { draft.defaults.insert(field.name) }
                self.tab.stage(draft)
            }
            item("From File…", in: values, enabled: writable) {
                let panel = NSOpenPanel()
                if panel.runModal() == .OK, let url = panel.url {
                    do { self.set(.blob(try Data(contentsOf: url)), row: row, column: field.name) }
                    catch { self.tab.error = error.localizedDescription }
                }
            }
            item("Copy", in: menu) { self.copySelected(format: .text, fallback: row) }
            item("Copy Cell Value", in: menu) { self.copy(value.display) }
            item("Copy Column Values on This Page", in: menu) { self.copy(self.rows.map { $0[field.index].display }.joined(separator: "\n")) }
            let formats = submenu("Copy Rows As", in: menu)
            for format in RowCopyFormat.allCases {
                item(format.rawValue, in: formats) { self.copySelected(format: format, fallback: row) }
            }
            let filterMenu = submenu("Quick Filter", in: menu)
            let options: [(ColumnFilter.Operation, String)] = value == .null ? [(.isNull, "IS NULL"), (.notNull, "IS NOT NULL")] :
                [(.equals, "="), (.notEquals, "<>"), (.less, "<"), (.greater, ">"), (.contains, "CONTAINS"), (.isNull, "IS NULL"), (.notNull, "IS NOT NULL")]
            for (op, symbol) in options {
                let unary = op == .isNull || op == .notNull
                let label = field.name + " " + symbol + (unary ? "" : " " + ChangeSQL.literal(value, driver: workspace.profile.driver))
                item(label, in: filterMenu, enabled: workspace.connected) {
                    let filter = ColumnFilter(column: field.name, operation: op, value: unary ? "" : value.display, typed: unary ? nil : value)
                    self.tab.filters = [filter]; self.tab.appliedFilters = [filter]
                    self.tab.filterEditorVisible = true; self.tab.offset = 0
                    Task { await self.workspace.load(self.tab) }
                }
            }
            item("Import CSV…", in: menu, enabled: workspace.connected && tab.canInsert && tab.changes.isEmpty) { self.tab.transfer = .importCSV }
            item("Export Current Page…", in: menu, enabled: tab.changes.isEmpty) { self.tab.transfer = .exportPage }
            let deletions = tab.deletions(selected)
            item("Mark \(deletions.count) Selected Rows for Deletion…", in: menu, enabled: workspace.connected && !deletions.isEmpty) {
                self.tab.deletionReview = deletions
            }
            return menu
        }
        private func set(_ value: SQLValue, row: Int, column: String) {
            guard var draft = tab.editRow(at: row), tab.schema?.columns.first(where: { $0.name == column })?.generated == false else { return }
            draft.defaults.remove(column)
            if draft.original?[column] == value { draft.changes.removeValue(forKey: column) }
            else { draft.changes[column] = value }
            tab.stage(draft)
        }
    }
}
