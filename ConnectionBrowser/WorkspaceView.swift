import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    let registry: WorkspaceRegistry
    @State private var search = ""
    @State private var fieldSearch = ""
    @State private var navigator = "Items"
    @State private var closing: WorkspaceTab?
    @State private var closingSQL: WorkspaceTab?
    @FocusState private var panelFocus: Workspace.FocusArea?

    var body: some View {
        layout
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("\(workspace.profile.name) — \(workspace.database.isEmpty ? "No Database" : workspace.database)")
        .frame(minWidth: 980, minHeight: 590)
        .onChange(of: panelFocus) { if let panelFocus { workspace.focusArea = panelFocus } }
        .background(WorkspaceWindowGuard(workspace: workspace).frame(width: 0, height: 0))
        .confirmationDialog("Close this tab with pending changes?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), presenting: closing) { tab in
            Button("Review and Commit…") { workspace.activeID = tab.id; tab.showStructure = false; tab.closeAfterCommit = true; tab.previewShown = true }
            Button("Discard and Close", role: .destructive) { tab.discard(); workspace.closeTab(tab) }
            Button("Keep Editing", role: .cancel) {}
        }
        .confirmationDialog("Save changes to this SQL tab?", isPresented: Binding(get: { closingSQL != nil }, set: { if !$0 { closingSQL = nil } }), presenting: closingSQL) { tab in
            Button("Save and Close") {
                do { if try workspace.saveSQL(tab) { workspace.closeTab(tab) } }
                catch { workspace.error = error.localizedDescription }
            }
            Button("Discard and Close", role: .destructive) { workspace.closeTab(tab) }
            Button("Keep Editing", role: .cancel) {}
        }
        .focusedSceneValue(\.connectionWorkspace, workspace)
        .focusedSceneValue(\.activeConnectionTab, workspace.active)
        .sheet(isPresented: $workspace.recoveryShown) { DraftRecoveryView(workspace: workspace) }
        .sheet(item: $workspace.operation) { ObjectOperationView(workspace: workspace, target: $0) }
        .sheet(isPresented: $workspace.overviewShown) { OverviewView(workspace: workspace) }
        .sheet(item: $workspace.schemaDraft) { draft in SchemaEditor(workspace: workspace, draft: draft) }
        .sheet(isPresented: $workspace.csvImportShown) { ImportCSVView(workspace: workspace, tab: workspace.active) }
        .sheet(item: $workspace.maintenance) { action in MaintenanceView(workspace: workspace, action: action) }
        .sheet(item: $workspace.serverTool) { tool in ServerToolSheet(workspace: workspace, tool: tool) }
        .sheet(isPresented: $workspace.objectSearchShown) { ObjectSearch(workspace: workspace) }
        .sheet(isPresented: $workspace.databaseSelectorShown) { DatabaseChooser(workspace: workspace) }
        .sheet(isPresented: Binding(get: { !workspace.bootstrapReview.isEmpty }, set: { if !$0 { workspace.bootstrapReview = [] } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review Bootstrap SQL").font(.title2)
                Text(workspace.profile.name + " / " + workspace.database)
                Text(workspace.profile.environment.uppercased()).foregroundStyle(workspace.profile.environmentColor)
                ScrollView {
                    Text(workspace.bootstrapReview.joined(separator: "\n")).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Spacer()
                HStack {
                    Spacer(); Button("Skip Bootstrap") { workspace.bootstrapReview = [] }.keyboardShortcut(.cancelAction)
                    Button("Run Bootstrap") { Task { await workspace.runBootstrap() } }
                }
            }.padding(18).frame(width: 480, height: 300)
        }
        .task { await workspace.reloadObjects(); workspace.offerBootstrap() }
    }
    private var layout: some View {
        VStack(spacing: 0) {
            WorkspaceTitleBar(workspace: workspace) { if let tab = workspace.active { requestClose(tab) } }
            if !workspace.connected {
                HStack {
                    Label("Disconnected", systemImage: "bolt.slash")
                    Spacer()
                    Button("Reconnect") { Task { await workspace.reconnect() } }.disabled(workspace.reconnecting)
                }.padding(8).background(.orange.opacity(0.12))
            }
            HStack(spacing: 0) {
                if registry.sessions.count > 1 {
                    SessionRail(current: workspace, registry: registry)
                    Divider()
                }
                panes
            }
        }
    }

    private var panes: some View {
        HSplitView {
            if workspace.showItems {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Navigator", selection: $navigator) {
                        ForEach(["Items", "Queries", "History"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.small).tint(.gray)
                    .padding(.horizontal, 9).padding(.vertical, 5).onChange(of: navigator) { search = "" }
                    ChromeSearchField(title: navigator == "Items" ? "Search for item" : "Search queries", text: $search)
                        .focused($panelFocus, equals: .items).padding(.horizontal, 9).padding(.bottom, 4)
                    if navigator != "Items" { QueryNavigator(workspace: workspace, history: navigator == "History", search: search) }
                    else { ObjectListView(workspace: workspace, search: search) }
                    HStack {
                        Spacer()
                        Menu {
                            Button("New Table…") { workspace.schemaDraft = SchemaDraft(kind: .table) }
                            Button("New View…") { workspace.schemaDraft = SchemaDraft(kind: .view) }
                            Button("New Query") { workspace.newQuery() }
                        } label: { Image(systemName: "plus") }
                            .fixedSize().controlSize(.small).disabled(!workspace.connected).accessibilityLabel("Create database item")
                    }.padding(.horizontal, 8).frame(height: 27)
                }.frame(minWidth: 175, idealWidth: 245, maxWidth: 285).background(BrowserChrome.panel)
            }
            VStack(alignment: .leading, spacing: 0) {
                if workspace.tabs.count > 1 {
                    GeometryReader { geo in
                        ScrollView(.horizontal) {
                            HStack(spacing: 0) {
                                ForEach(workspace.tabs) { tab in
                                    Button {
                                        workspace.activeID = tab.id
                                    } label: {
                                        Text(tab.title).lineLimit(1).font(.system(size: 11, weight: tab.id == workspace.activeID ? .semibold : .regular))
                                            .frame(width: max(100, geo.size.width / CGFloat(workspace.tabs.count)), height: 25)
                                            .background(tab.id == workspace.activeID ? BrowserChrome.paper : BrowserChrome.bar)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    .overlay(alignment: .trailing) { Divider() }
                                    .contextMenu { Button("Close Tab") { requestClose(tab) }.disabled(tab.busy) }
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }.frame(height: 25)
                    Divider()
                }
                if let tab = workspace.active {
                    WorkspaceTabView(workspace: workspace, tab: tab).id(tab.id)
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "cylinder.split.1x2").font(.system(size: 42, weight: .thin)).foregroundStyle(.secondary)
                        Text("No Open Tabs").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error = workspace.error { Text(error).foregroundStyle(.red).padding(6) }
                if workspace.showConsole {
                    Divider()
                    WorkspaceConsole(workspace: workspace).frame(height: 135)
                        .focusable().focused($panelFocus, equals: .console)
                }
            }.frame(minWidth: 490, maxWidth: .infinity, maxHeight: .infinity).background(BrowserChrome.paper)
            if workspace.showDetails {
                RecordInspector(workspace: workspace, search: $fieldSearch)
                    .focused($panelFocus, equals: .detail).frame(minWidth: 170, idealWidth: 260, maxWidth: 355)
            }
        }
    }

    private func requestClose(_ tab: WorkspaceTab) {
        if !tab.changes.isEmpty { closing = tab }
        else if tab.unsavedSQL { closingSQL = tab }
        else { workspace.closeTab(tab) }
    }
}

private struct WorkspaceTabView: View {
    @State private var importShown = false
    @State private var exportShown = false
    @State private var exportScope: ExportScope?
    let workspace: Workspace
    @Bindable var tab: WorkspaceTab
    private var hasDataMode: Bool { tab.object?.kind == .table || tab.object?.kind == .view }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tab.object == nil {
                VSplitView {
                    VStack(spacing: 0) { QueryPane(workspace: workspace, tab: tab) }
                        .frame(minHeight: 118, idealHeight: 280, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 0) {
                        activity
                        ResultTable(result: tab.result, selected: $tab.selected)
                    }.frame(minHeight: 84, idealHeight: 240, maxHeight: .infinity)
                }
            } else {
                if hasDataMode && !tab.showStructure { FilterConditions(workspace: workspace, tab: tab) }
                activity
                if tab.showStructure {
                    if tab.section == "DDL", let row = tab.structureResult.rows.first {
                        if let ddl = row.first(where: { $0.display.uppercased().contains("CREATE ") }) {
                            ScrollView { Text(ddl.display).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        } else { Text("The server did not expose this definition to your account.").accessibilityIdentifier("routineUnavailable") }
                    } else { ResultTable(result: tab.structureResult, selected: .constant(nil)) }
                } else {
                    DataGrid(workspace: workspace, tab: tab).frame(minHeight: 130).layoutPriority(1)
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) { modeAndRows; Spacer(minLength: 0); status; Spacer(minLength: 0); pageControls }
                VStack(spacing: 3) {
                    HStack(spacing: 4) { modeAndRows; Spacer(minLength: 0); status }
                    HStack(spacing: 4) { Spacer(); pageControls }
                }
            }
            .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 5).background(BrowserChrome.panel)
        }.controlSize(.small)
        .sheet(isPresented: $importShown) { ImportCSVView(workspace: workspace, tab: tab) }
        .sheet(isPresented: $exportShown) { ExportView(workspace: workspace, tab: tab, initialScope: exportScope) }
        .onChange(of: tab.transfer, initial: true) {
            switch tab.transfer {
            case .importCSV: importShown = true
            case .exportPage: exportScope = .result; exportShown = true
            case .exportTable: exportScope = .table; exportShown = true
            case nil: break
            }
            tab.transfer = nil
        }
        .confirmationDialog("Mark \(tab.deletionReview.count) rows for deletion from \(tab.title)?",
                            isPresented: Binding(get: { !tab.deletionReview.isEmpty }, set: { if !$0 { tab.deletionReview = [] } }),
                            presenting: tab.deletionReview) { drafts in
            Button("Stage Deletions", role: .destructive) { tab.stage(drafts) }
            Button("Cancel", role: .cancel) {}
        } message: { drafts in
            let keys = tab.schema?.key.map(\.name) ?? []
            let identities = drafts.prefix(8).map { draft in keys.map { $0 + "=" + (draft.original?[$0]?.display ?? "new") }.joined(separator: ", ") }
            Text(workspace.profile.name + " / " + workspace.database + "\n" + identities.joined(separator: "\n"))
        }
        .task(id: "\(tab.showStructure)-\(tab.section)") { if tab.showStructure { await workspace.loadStructure(tab) } }
    }
    @ViewBuilder private var activity: some View {
        if tab.busy { ProgressView("Running query…").controlSize(.small) }
        if let error = tab.error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("queryError") }
    }

    @ViewBuilder private var modeAndRows: some View {
        if hasDataMode {
            Picker("Object Mode", selection: $tab.showStructure) {
                Text("Data").tag(false)
                Text("Structure").tag(true)
            }.pickerStyle(.segmented).labelsHidden().fixedSize().tint(.gray)
        }
        if tab.showStructure {
            Picker("Structure Section", selection: $tab.section) {
                ForEach(["Columns", "Indexes", "Foreign Keys", "Triggers", "DDL"], id: \.self) { Text($0) }
            }.labelsHidden().fixedSize().accessibilityIdentifier("Structure Section")
        } else if tab.object != nil { RowActions(workspace: workspace, tab: tab) }
    }

    @ViewBuilder private var status: some View {
        Group {
            if tab.selectedRows.count > 1 { Text("\(tab.selectedRows.count) rows selected") }
            else if tab.object != nil { Text("\(tab.result.rows.count) of \(tab.totalCount) rows") }
            else { Text("\(tab.result.rows.count) rows\(tab.result.truncated ? " (display limit reached)" : "")") }
        }.font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
    }

    @ViewBuilder private var pageControls: some View {
        if hasDataMode && !tab.showStructure { TableControls(workspace: workspace, tab: tab) }
        if tab.object?.kind == .table {
            Button("Import CSV", systemImage: "square.and.arrow.down") { importShown = true }
                .labelStyle(.iconOnly).help("Import CSV")
                .disabled(!workspace.connected || tab.busy || tab.schema?.transactional != true || !tab.changes.isEmpty)
        }
        Button("Export Data", systemImage: "square.and.arrow.up") { exportScope = nil; exportShown = true }
            .labelStyle(.iconOnly).help("Export Data")
            .disabled(tab.result.columns.isEmpty || tab.busy || !tab.changes.isEmpty || !workspace.connected)
        if hasDataMode && !tab.showStructure {
            Button("Previous Page", systemImage: "chevron.left") {
                tab.offset = max(0, tab.offset - tab.limit); Task { await workspace.load(tab) }
            }.labelStyle(.iconOnly).help("Previous page").disabled(tab.offset == 0 || tab.busy)
            Menu {
                Section("Page Size") {
                    ForEach([25, 100, 300, 500, 1000], id: \.self) { size in
                        Button(String(size)) { tab.limit = size; tab.offset = 0; Task { await workspace.load(tab) } }
                    }
                }
                Menu("Sort") {
                    ForEach(tab.result.columns, id: \.self) { column in
                        Menu(column) {
                            Button("Ascending") { sort(column, descending: false) }
                            Button("Descending") { sort(column, descending: true) }
                        }
                    }
                    Button("Clear Sort") { tab.sortColumn = nil; Task { await workspace.load(tab) } }
                }
            } label: { Image(systemName: "gearshape.fill") }
                .menuIndicator(.hidden).fixedSize().accessibilityLabel("Page Size: \(tab.limit)").help("Page size and sorting")
            Button("Next Page", systemImage: "chevron.right") {
                tab.offset += tab.limit; Task { await workspace.load(tab) }
            }.labelStyle(.iconOnly).help("Next page").disabled(tab.offset + tab.result.rows.count >= tab.totalCount || tab.busy)
        }
    }

    private func sort(_ column: String, descending: Bool) {
        tab.sortColumn = column; tab.descending = descending; tab.offset = 0; Task { await workspace.load(tab) }
    }

}
