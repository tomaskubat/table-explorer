import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @State private var search = ""
    @State private var navigator = "Items"
    @State private var closing: WorkspaceTab?

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.connected {
                HStack {
                    Label("Disconnected", systemImage: "bolt.slash")
                    Spacer()
                    Button("Reconnect") { Task { await workspace.reconnect() } }.disabled(workspace.reconnecting)
                }.padding(8).background(.orange.opacity(0.12))
            }
            HSplitView {
                if workspace.showItems {
                    VStack(alignment: .leading) {
                        Picker("Navigator", selection: $navigator) {
                            ForEach(["Items", "Queries", "History"], id: \.self) { Text($0) }
                        }.pickerStyle(.segmented).labelsHidden().onChange(of: navigator) { search = "" }
                        TextField(navigator == "Items" ? "Search for item" : "Search queries", text: $search)
                        if navigator != "Items" { QueryNavigator(workspace: workspace, history: navigator == "History", search: search) }
                        else { List(workspace.objects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { object in
                            Label(object.name, systemImage: object.kind == .view ? "eye" : "tablecells")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { Task { await workspace.open(object) } }
                                .contextMenu {
                                    Button("Open in Tab") { Task { await workspace.open(object) } }
                                    Button("Copy Name") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(object.name, forType: .string)
                                    }
                                }
                        }.listStyle(.plain) }
                    }.padding(8).frame(minWidth: 135, idealWidth: 185, maxWidth: 270)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !workspace.tabs.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(workspace.tabs) { tab in
                                    Button(tab.title) { workspace.activeID = tab.id }
                                        .buttonStyle(.bordered)
                                        .tint(tab.id == workspace.activeID ? .accentColor : .secondary)
                                        .contextMenu { Button("Close Tab") { requestClose(tab) }.disabled(tab.busy) }
                                    if tab.id == workspace.activeID {
                                        Button("Close Tab", systemImage: "xmark") { requestClose(tab) }
                                            .buttonStyle(.borderless).labelStyle(.iconOnly).disabled(tab.busy)
                                    }
                                }
                            }.padding(6)
                        }
                        Divider()
                    }
                    if let tab = workspace.active {
                        WorkspaceTabView(workspace: workspace, tab: tab).id(tab.id)
                    } else {
                        ContentUnavailableView("No Open Tabs", systemImage: "tablecells", description: Text("Open a table or start a new SQL query."))
                    }
                    if let error = workspace.error { Text(error).foregroundStyle(.red).padding(6) }
                    if workspace.showConsole {
                        Divider()
                        ScrollView {
                            Text(workspace.log.isEmpty ? "Open a table or run a query to see its SQL." : workspace.log.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(8).frame(height: 80).accessibilityLabel("SQL Console").accessibilityIdentifier("SQL Console")
                    }
                }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if workspace.showDetails {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Row Detail").font(.headline).accessibilityIdentifier("row-detail-header")
                        if let tab = workspace.active, let index = tab.selected, tab.displayed.rows.indices.contains(index) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(tab.result.columns.indices, id: \.self) { i in
                                        Text(tab.result.columns[i]).font(.caption).foregroundStyle(.secondary)
                                        Text(tab.displayed.rows[index][i].display).textSelection(.enabled).accessibilityIdentifier("detail-value-\(i)")
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else { Text("Select a row").foregroundStyle(.secondary) }
                        Spacer()
                    }.padding(8).frame(minWidth: 130, idealWidth: 175, maxWidth: 250)
                }
            }
        }
        .navigationTitle("\(workspace.profile.name) — \(workspace.database.isEmpty ? "No Database" : workspace.database)")
        .frame(minWidth: 740, minHeight: 390)
        .background(WorkspaceWindowGuard(workspace: workspace).frame(width: 0, height: 0))
        .confirmationDialog("Close this tab with pending changes?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), presenting: closing) { tab in
            Button("Review and Commit…") { workspace.activeID = tab.id; tab.showStructure = false; tab.previewShown = true }
            Button("Discard and Close", role: .destructive) { tab.discard(); workspace.closeTab(tab) }
            Button("Keep Editing", role: .cancel) {}
        }
        .focusedSceneValue(\.connectionWorkspace, workspace)
        .sheet(item: $workspace.schemaDraft) { draft in SchemaEditor(workspace: workspace, draft: draft) }
        .sheet(item: $workspace.serverTool) { tool in ServerToolSheet(workspace: workspace, tool: tool) }
        .sheet(isPresented: $workspace.objectSearchShown) { ObjectSearch(workspace: workspace) }
        .sheet(isPresented: $workspace.databaseSelectorShown) { DatabaseChooser(workspace: workspace) }
        .toolbar {
            if workspace.profile.driver == .mariaDB {
                Button("Database", systemImage: "cylinder") { workspace.databaseSelectorShown = true }.disabled(!workspace.connected)
            }
            Button("New Query", systemImage: "plus.rectangle") { workspace.newQuery() }
            Button("Item List", systemImage: "sidebar.left") { workspace.showItems.toggle() }
            Button("SQL Console", systemImage: "terminal") { workspace.showConsole.toggle() }
            Button("Row Detail", systemImage: "sidebar.right") { workspace.showDetails.toggle() }
        }
        .task { await workspace.reloadObjects() }
    }
    private func requestClose(_ tab: WorkspaceTab) {
        if tab.changes.isEmpty { workspace.closeTab(tab) } else { closing = tab }
    }
}

private struct WorkspaceTabView: View {
    @State private var importShown = false
    @State private var exportShown = false
    let workspace: Workspace
    @Bindable var tab: WorkspaceTab
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tab.object == nil {
                QueryPane(workspace: workspace, tab: tab)
            }
            if tab.object?.kind == .table || tab.object?.kind == .view {
                Picker("Object Mode", selection: $tab.showStructure) {
                    Text("Data").tag(false)
                    Text("Structure").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                if tab.showStructure {
                    Picker("Structure Section", selection: $tab.section) {
                        ForEach(["Columns", "Indexes", "Foreign Keys", "Triggers", "DDL"], id: \.self) { Text($0) }
                    }.frame(maxWidth: 320).accessibilityIdentifier("Structure Section")
                } else {
                    TableControls(workspace: workspace, tab: tab)
                }
            }
            if tab.busy { ProgressView("Running query…").controlSize(.small) }
            if let error = tab.error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("queryError") }
            if tab.showStructure {
                if tab.section == "DDL", let row = tab.structureResult.rows.first {
                    if let ddl = row.first(where: { $0.display.uppercased().contains("CREATE ") }) {
                        ScrollView { Text(ddl.display).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    } else { Text("The server did not expose this definition to your account.").accessibilityIdentifier("routineUnavailable") }
                } else { ResultTable(result: tab.structureResult, selected: .constant(nil)) }
            } else {
                ResultTable(result: tab.displayed, selected: $tab.selected, hidden: tab.hiddenColumns, pending: tab.cellMarkers)
                if tab.object != nil { RowActions(workspace: workspace, tab: tab) }
            }
            HStack {
                if tab.object?.kind == .table {
                    Button("Import CSV") { importShown = true }
                        .disabled(!workspace.connected || tab.busy || tab.schema?.transactional != true || !tab.changes.isEmpty)
                }
                Button("Export Data") { exportShown = true }
                    .disabled(tab.result.columns.isEmpty || tab.busy || !tab.changes.isEmpty || !workspace.connected)
                if tab.object != nil { Text("\(tab.result.rows.count) of \(tab.totalCount) rows").font(.caption) }
                else { Text("\(tab.result.rows.count) rows\(tab.result.truncated ? " (display limit reached)" : "")").font(.caption) }
                Spacer()
                if tab.object != nil {
                    Button("Previous Page") {
                        tab.offset = max(0, tab.offset - tab.limit)
                        Task { await workspace.load(tab) }
                    }.disabled(tab.offset == 0 || tab.busy)
                    Button("Next Page") {
                        tab.offset += tab.limit
                        Task { await workspace.load(tab) }
                    }.disabled(tab.offset + tab.result.rows.count >= tab.totalCount || tab.busy)
                }
            }
        }.padding(8)
        .sheet(isPresented: $importShown) { ImportCSVView(workspace: workspace, tab: tab) }
        .sheet(isPresented: $exportShown) { ExportView(workspace: workspace, tab: tab) }
        .task(id: "\(tab.showStructure)-\(tab.section)") { if tab.showStructure { await workspace.loadStructure(tab) } }
    }
}

private struct GridRow: Identifiable {
    let id: Int
    let cells: [SQLValue]
}

private struct GridColumn: Identifiable, Hashable {
    let offset: Int
    let title: String
    var id: Self { self }
}

struct ResultTable: View {
    let result: QueryResult
    @Binding var selected: Int?
    var hidden: Set<String> = []
    var pending: [Int: [String: String]] = [:]
    var body: some View {
        let columns = result.columns.enumerated().compactMap { offset, title in
            hidden.contains(title) ? nil : GridColumn(offset: offset, title: title)
        }
        Table(result.rows.enumerated().map { GridRow(id: $0.offset, cells: $0.element) }, selection: $selected) {
            TableColumnForEach(columns) { column in
                TableColumn(column.title) { row in
                    if row.cells.indices.contains(column.offset) {
                        let value = row.cells[column.offset]
                        let marker = pending[row.id]?[column.title]
                        HStack(spacing: 4) {
                            if let marker { Image(systemName: marker).accessibilityLabel("Pending change") }
                            Text(value.display).strikethrough(marker == "minus.circle")
                                .foregroundStyle(value == .null ? .secondary : .primary)
                        }
                    }
                }.width(min: 70, ideal: 125)
            }
        }.id(columns).accessibilityLabel("Query Results")
    }
}
