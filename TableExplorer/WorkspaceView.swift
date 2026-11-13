import SwiftUI

struct WorkspaceHostView: View {
    let registry: WorkspaceRegistry

    var body: some View {
        Group {
            if let workspace = registry.active {
                WorkspaceView(workspace: workspace, registry: registry).id(workspace.id)
            } else {
                Color.clear.frame(minWidth: 980, minHeight: 590)
            }
        }
        .background(WorkspaceWindowGuard(registry: registry).frame(width: 0, height: 0))
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard BrowserPreferences.defaults.object(forKey: "keepAlive") as? Bool != false else { continue }
                for workspace in registry.orderedSessions where workspace.profile.driver == .mariaDB && workspace.connected && !workspace.hasRunningTasks {
                    do { try await workspace.session.ping() } catch { workspace.record(error) }
                }
            }
        }
    }
}

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    let registry: WorkspaceRegistry
    @AppStorage("loadingWallpaper", store: BrowserPreferences.defaults) private var wallpaper = true
    @State private var search = ""
    @State private var fieldSearch = ""
    @State private var closing: WorkspaceTab?
    @State private var closingSQL: WorkspaceTab?
    @State private var renaming: WorkspaceTab?
    private struct BulkClose {
        let tabs: [WorkspaceTab]
        let anchor: UUID
    }
    @State private var bulkClose: BulkClose?
    @FocusState private var panelFocus: Workspace.FocusArea?

    var body: some View {
        layout
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("\(workspace.profile.name) — \(workspace.database.isEmpty ? "No Database" : workspace.database)")
        .frame(minWidth: 980, minHeight: 590)
        .onChange(of: workspace.paneRequest) {
            var panes: [Workspace.FocusArea] = []
            if workspace.showItems { panes.append(.items) }
            if let tab = workspace.active { panes.append(tab.object == nil ? .sql : .grid) }
            if workspace.showDetails { panes.append(.detail) }
            if workspace.showConsole { panes.append(.console) }
            guard !panes.isEmpty else { return }
            let i = workspace.focusArea.flatMap { panes.firstIndex(of: $0) } ?? 0
            let next = panes[(i + workspace.paneDirection + panes.count) % panes.count]
            if next == .grid { workspace.window?.makeFirstResponder(workspace.active?.grid) }
            else if next == .sql {
                @MainActor func editor(in view: NSView) -> NSView? {
                    if view.accessibilityIdentifier() == "SQL Editor" { return view }
                    return view.subviews.lazy.compactMap { editor(in: $0) }.first
                }
                if let root = workspace.window?.contentView, let editor = editor(in: root) { workspace.window?.makeFirstResponder(editor) }
            } else { panelFocus = next }
        }
        .onChange(of: panelFocus) { if let panelFocus { workspace.focusArea = panelFocus } }
        .onChange(of: workspace.closeTabRequest) { requestCloseActiveTab() }
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
        .confirmationDialog("Close tabs with unsaved changes?", isPresented: Binding(get: { bulkClose != nil }, set: { if !$0 { bulkClose = nil } }), presenting: bulkClose) { request in
            Button("Discard Changes and Close", role: .destructive) { workspace.closeTabs(request.tabs, keeping: request.anchor) }
            Button("Keep Editing", role: .cancel) {}
        } message: { request in
            Text("Unsaved changes in: " + request.tabs.filter { $0.unsavedSQL || !$0.changes.isEmpty }.map(\.title).joined(separator: ", "))
        }
        .focusedSceneValue(\.activeConnectionTab, workspace.active)
        .focusedSceneValue(\.closeWorkspaceTab, requestCloseActiveTab)
        .sheet(item: $renaming) { tab in RenameWorkspaceTab(tab: tab) }
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
                Text(workspace.profile.connectionTag.uppercased()).foregroundStyle(workspace.profile.environmentColor)
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
        .task { await workspace.start() }
        .task(id: workspace.activeID) { await workspace.loadRestoredTab(workspace.active) }
    }
    private var layout: some View {
        VStack(spacing: 0) {
            WorkspaceTitleBar(workspace: workspace, closeTab: requestCloseActiveTab)
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
                    Picker("Navigator", selection: $workspace.navigator) {
                        ForEach(["Items", "Queries", "History"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.small).tint(.gray)
                    .padding(.horizontal, 9).padding(.vertical, 5).onChange(of: workspace.navigator) { search = "" }
                    ChromeSearchField(title: workspace.navigator == "Items" ? "Search for item" : "Search queries", text: $search)
                        .focused($panelFocus, equals: .items).padding(.horizontal, 9).padding(.bottom, 4)
                    if workspace.navigator != "Items" { QueryNavigator(workspace: workspace, history: workspace.navigator == "History", search: search) }
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
            GeometryReader { area in
                VStack(alignment: .leading, spacing: 0) {
                    if !workspace.tabs.isEmpty {
                        tabBar
                        Divider()
                    }
                    if let tab = workspace.active {
                        WorkspaceTabView(workspace: workspace, tab: tab)
                            .id(tab.object == nil ? tab.id : nil)
                    } else {
                        VStack(spacing: 9) {
                            if wallpaper { Image(systemName: "cylinder.split.1x2").font(.system(size: 42, weight: .thin)).foregroundStyle(.secondary) }
                            Text(workspace.loadingInitialCatalog ? "Loading database objects…" : "No Open Tabs").font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let error = workspace.error { Text(error).foregroundStyle(.red).padding(6) }
                    if workspace.showConsole {
                        // Keep enough space for either the data grid or the SQL editor and result.
                        let limits = CGFloat(66)...max(66, area.size.height - 294)
                        let height = min(max(workspace.consoleHeight, limits.lowerBound), limits.upperBound)
                        ConsoleDivider(height: height, limits: limits) { workspace.consoleHeight = $0 }
                            .frame(height: 7)
                        WorkspaceConsole(workspace: workspace).frame(height: height)
                            .focusable().focused($panelFocus, equals: .console)
                    }
                }.frame(width: area.size.width, height: area.size.height)
            }.frame(minWidth: 490, maxWidth: .infinity, maxHeight: .infinity).background(BrowserChrome.paper)
            if workspace.showDetails {
                RecordInspector(workspace: workspace, search: $fieldSearch)
                    .focused($panelFocus, equals: .detail).frame(minWidth: 170, idealWidth: 260, maxWidth: 355)
            }
        }
    }

    private var tabBar: some View {
        GeometryReader { area in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(workspace.tabs) { tab in
                        let active = tab.id == workspace.activeID
                        HStack(spacing: 0) {
                            Button {
                                requestClose(tab)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary).frame(width: 24, height: 25).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Close " + tab.title).help("Close " + tab.title)
                                .disabled(tab.busy)
                            Button {
                                workspace.activeID = tab.id
                            } label: {
                                Text(tab.title).lineLimit(1)
                                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("workspace-tab-" + tab.title)
                        }
                        .frame(width: max(100, area.size.width / CGFloat(workspace.tabs.count)), height: 25)
                        .background(active ? BrowserChrome.paper : BrowserChrome.bar)
                        .overlay(alignment: .bottom) {
                            if tab.busy {
                                TabLoadingBar()
                                    .frame(height: 2).allowsHitTesting(false)
                                    .accessibilityLabel("Loading " + tab.title)
                            }
                        }
                        .overlay(alignment: .trailing) { Divider().allowsHitTesting(false) }
                        .contextMenu {
                            Button("Rename Tab…") { renaming = tab }
                            Divider()
                            Button("Close Tab") { requestClose(tab) }.disabled(tab.busy)
                            Divider()
                            ForEach(Workspace.CloseScope.allCases, id: \.self) { scope in
                                let targets = workspace.targets(scope, relativeTo: tab)
                                Button(scope.rawValue) {
                                    if targets.contains(where: { $0.unsavedSQL || !$0.changes.isEmpty }) {
                                        bulkClose = BulkClose(tabs: targets, anchor: tab.id)
                                    } else { workspace.closeTabs(targets, keeping: tab.id) }
                                }.disabled(targets.isEmpty || targets.contains(where: \.busy))
                            }
                        }
                    }
                }
            }.scrollIndicators(.hidden)
        }.frame(height: 25)
    }

    private func requestCloseActiveTab() {
        if let tab = workspace.active { requestClose(tab) }
    }

    private func requestClose(_ tab: WorkspaceTab) {
        guard !tab.busy else { return }
        if !tab.changes.isEmpty { closing = tab }
        else if tab.unsavedSQL { closingSQL = tab }
        else { workspace.closeTab(tab) }
    }
}

private struct TabLoadingBar: View {
    @State private var moving = false

    var body: some View {
        GeometryReader { area in
            Color.accentColor.opacity(0.2)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.accentColor)
                        .frame(width: area.size.width * 0.3)
                        .offset(x: moving ? area.size.width : -area.size.width * 0.3)
                }
                .clipped()
                .onAppear {
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { moving = true }
                }
        }.accessibilityElement()
    }
}

private struct RenameWorkspaceTab: View {
    let tab: WorkspaceTab
    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    init(tab: WorkspaceTab) { self.tab = tab; _name = State(initialValue: tab.title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tab").font(.headline)
            TextField("Tab Name", text: $name).accessibilityIdentifier("Tab Name")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { tab.title = name.trimmingCharacters(in: .whitespacesAndNewlines); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16).frame(width: 300)
    }
}

private struct WorkspaceTabView: View {
    private struct StructureRequest: Equatable {
        let tabID: UUID
        let section: String?
    }
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
                    } else { ResultTable(result: tab.structureResult, selected: .constant(nil), selectableText: true) }
                } else {
                    DataGrid(workspace: workspace, tab: tab).frame(minHeight: 130).layoutPriority(1)
                }
            }
            Divider()
            WorkspaceFooterLayout {
                HStack(spacing: 5) { modeAndRows }
                HStack(spacing: 0) { status }
                HStack(spacing: 5) { pageControls }
            }
            .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 5).background(BrowserChrome.panel)
        }.controlSize(.small)
        .sheet(isPresented: $tab.importShown) { ImportCSVView(workspace: workspace, tab: tab) }
        .sheet(isPresented: $tab.exportShown) { ExportView(workspace: workspace, tab: tab, initialScope: tab.exportScope) }
        .onChange(of: tab.transfer, initial: true) {
            switch tab.transfer {
            case .importCSV: tab.importShown = true
            case .exportPage: tab.exportScope = .result; tab.exportShown = true
            case .exportTable: tab.exportScope = .table; tab.exportShown = true
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
        .task(id: StructureRequest(tabID: tab.id, section: tab.showStructure ? tab.section : nil)) {
            if tab.showStructure { await workspace.loadStructure(tab) }
        }
    }
    @ViewBuilder private var activity: some View {
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
            if !tab.showStructure, tab.object != nil, !tab.selectedRows.isEmpty, let total = tab.totalCount {
                let count = total + tab.changes.filter { $0.original == nil }.count
                Text("\(tab.selectedRows.count) of \(tab.countEstimated ? "≈" : "")\(count) \(count == 1 ? "row" : "rows") selected")
            }
            else if tab.object != nil, let total = tab.totalCount { Text("\(tab.result.rows.count) of \(tab.countEstimated ? "≈" : "")\(total) rows") }
            else if tab.object != nil { Text("\(tab.result.rows.count) rows loaded") }
            else { Text("\(tab.result.rows.count) rows\(tab.result.truncated ? " (display limit reached)" : "")") }
        }.font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
    }

    @ViewBuilder private var pageControls: some View {
        if hasDataMode && !tab.showStructure { TableControls(workspace: workspace, tab: tab) }
        if hasDataMode && !tab.showStructure {
            Button("Refresh Data", systemImage: "arrow.clockwise") { Task { await workspace.refresh(tab) } }
                .labelStyle(.iconOnly)
                .help(tab.changes.isEmpty ? "Refresh data (\(Keymap.saved[.refresh].display))" : "Commit or discard row changes before refreshing")
                .disabled(!workspace.canRefresh(tab))
        }
        if tab.object?.kind == .table {
            Button("Import CSV", systemImage: "square.and.arrow.down") { tab.importShown = true }
                .labelStyle(.iconOnly).help("Import CSV")
                .disabled(!workspace.connected || tab.busy || tab.schema?.transactional != true || !tab.changes.isEmpty)
        }
        Button("Export Data", systemImage: "square.and.arrow.up") { tab.exportScope = nil; tab.exportShown = true }
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
            }.labelStyle(.iconOnly).help("Next page").disabled(!tab.hasNextPage || tab.busy)
        }
    }

    private func sort(_ column: String, descending: Bool) {
        tab.sortColumn = column; tab.descending = descending; tab.offset = 0; Task { await workspace.load(tab) }
    }

}

/// Keep one set of controls (and sheet presenters) as the footer wraps.
private struct WorkspaceFooterLayout: Layout {
    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let width = proposal.width ?? cache.reduce(10) { $0 + $1.width }
        return CGSize(width: width, height: positions(width: width, sizes: cache).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        for (view, frame) in zip(subviews, positions(width: bounds.width, sizes: cache)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func positions(width: CGFloat, sizes: [CGSize]) -> [CGRect] {
        let tools = sizes[0], status = sizes[1], page = sizes[2]
        if tools.width + status.width + page.width + 10 <= width {
            let height = sizes.map(\.height).max() ?? 0
            let gap = (width - tools.width - status.width - page.width) / 2
            return zip(sizes, [0, tools.width + gap, width - page.width]).map { size, x in
                CGRect(origin: CGPoint(x: x, y: (height - size.height) / 2), size: size)
            }
        }
        let stacked = tools.width + status.width + 5 > width
        let height = stacked ? tools.height : max(tools.height, status.height)
        let statusY = stacked ? height + 3 : (height - status.height) / 2
        return [
            CGRect(origin: CGPoint(x: 0, y: (height - tools.height) / 2), size: tools),
            CGRect(origin: CGPoint(x: width - status.width, y: statusY), size: status),
            CGRect(origin: CGPoint(x: width - page.width, y: max(height, statusY + status.height) + 3), size: page)
        ]
    }
}
