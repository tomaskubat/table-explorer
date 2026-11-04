import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @State private var search = ""
    @State private var showItems = true
    @State private var showDetails = true
    @State private var showConsole = true

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if showItems {
                    VStack(alignment: .leading) {
                        Text("Items").font(.headline)
                        TextField("Search for item", text: $search)
                        List(workspace.objects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { object in
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
                        }.listStyle(.plain)
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
                    if showConsole {
                        Divider()
                        ScrollView {
                            Text(workspace.log.isEmpty ? "Open a table or run a query to see its SQL." : workspace.log.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(8).frame(height: 80).accessibilityLabel("SQL Console")
                    }
                }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if showDetails {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Row Detail").font(.headline)
                        if let tab = workspace.active, let index = tab.selected, tab.result.rows.indices.contains(index) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(tab.result.columns.indices, id: \.self) { i in
                                        Text(tab.result.columns[i]).font(.caption).foregroundStyle(.secondary)
                                        Text(tab.result.rows[index][i].display).textSelection(.enabled)
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
        .toolbar {
            Button("New Query", systemImage: "plus.rectangle") { workspace.newQuery() }.keyboardShortcut("t")
            Button("Item List", systemImage: "sidebar.left") { showItems.toggle() }
            Button("SQL Console", systemImage: "terminal") { showConsole.toggle() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Row Detail", systemImage: "sidebar.right") { showDetails.toggle() }
        }
        .task { await workspace.reloadObjects() }
    }
}

private struct WorkspaceTabView: View {
    let workspace: Workspace
    @Bindable var tab: WorkspaceTab
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tab.object == nil {
                TextEditor(text: $tab.sql)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("SQL Editor").frame(minHeight: 70, maxHeight: 130)
                Button("Run SQL") { Task { await workspace.execute(tab.sql, on: tab) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(tab.busy || tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if tab.busy { ProgressView("Running query…").controlSize(.small) }
            if let error = tab.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ResultTable(result: tab.result, selected: $tab.selected)
            HStack {
                Text("\(tab.result.rows.count) rows\(tab.result.truncated ? " (display limit reached)" : "")").font(.caption)
                Spacer()
                if tab.object != nil {
                    Button("Previous Page") {
                        tab.offset = max(0, tab.offset - tab.limit)
                        Task { await workspace.load(tab) }
                    }.disabled(tab.offset == 0 || tab.busy)
                    Button("Next Page") {
                        tab.offset += tab.limit
                        Task { await workspace.load(tab) }
                    }.disabled(tab.result.rows.count < tab.limit || tab.busy)
                }
            }
        }.padding(8)
    }
}

private struct GridRow: Identifiable {
    let id: Int
    let cells: [SQLValue]
}

struct ResultTable: View {
    let result: QueryResult
    @Binding var selected: Int?
    var body: some View {
        Table(result.rows.enumerated().map { GridRow(id: $0.offset, cells: $0.element) }, selection: $selected) {
            TableColumnForEach(result.columns.indices, id: \.self) { column in
                TableColumn(result.columns[column]) { row in
                    Text(row.cells[column].display)
                        .foregroundStyle(row.cells[column] == .null ? .secondary : .primary)
                }.width(min: 70, ideal: 125)
            }
        }.accessibilityLabel("Query Results")
    }
}
