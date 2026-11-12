import SwiftUI
import UniformTypeIdentifiers

private struct WorkspaceKey: FocusedValueKey { typealias Value = Workspace }
private struct WorkspaceTabKey: FocusedValueKey { typealias Value = WorkspaceTab }
private struct CloseTabActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var closeWorkspaceTab: (() -> Void)? {
        get { self[CloseTabActionKey.self] }
        set { self[CloseTabActionKey.self] = newValue }
    }
    var activeConnectionTab: WorkspaceTab? {
        get { self[WorkspaceTabKey.self] }
        set { self[WorkspaceTabKey.self] = newValue }
    }
    var connectionWorkspace: Workspace? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    let registry: WorkspaceRegistry
    @AppStorage(Keymap.key, store: BrowserPreferences.defaults) private var bindings = Data()
    private var map: Keymap { Keymap(bindings) }
    @FocusedValue(\.connectionWorkspace) private var workspace
    @FocusedValue(\.activeConnectionTab) private var activeTab
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.closeWorkspaceTab) private var closeTab
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Saved Connections") { openWindow(id: "connections") }.keyboardShortcut(map[.connections].shortcut)
            Button("New SQL Document") { newDocument(SQLFileDocument()) }.keyboardShortcut(map[.document].shortcut)
            Button("Open SQL File…") { openSQL() }.keyboardShortcut(map[.openFile].shortcut)
            Button("New Query") { workspace?.newQuery() }.keyboardShortcut(map[.newQuery].shortcut).disabled(workspace == nil)
            Button("Recover SQL Draft…") { workspace?.recoveryShown = true }.disabled(workspace == nil)
            if let workspace, let tab = activeTab {
                Divider()
                Button("Close Tab") { closeTab?() }.keyboardShortcut(map[.close].shortcut).disabled(tab.busy)
                if tab.object == nil {
                    Button("Save Query") { workspace.saveActiveTab() }
                        .keyboardShortcut(map[.save].shortcut)
                    Button("Save Query As…") { do { try workspace.saveSQL(tab, saveAs: true) } catch { workspace.error = error.localizedDescription } }
                } else {
                    Button("Commit Changes…") { workspace.saveActiveTab() }.keyboardShortcut(map[.save].shortcut).disabled(!workspace.connected || tab.changes.isEmpty)
                }
            }
        }
        CommandGroup(after: .importExport) {
            Button("Import CSV…") { workspace?.csvImportShown = true }.disabled(workspace?.connected != true || workspace?.hasRunningTasks != false || workspace?.database.isEmpty != false)
            Button("Import SQL Dump…") { openSQL() }.disabled(workspace == nil)
            Button("Backup Database…") { workspace?.maintenance = .backup }.disabled(workspace?.connected != true || workspace?.hasRunningTasks != false)
            Button("Restore Database…") { workspace?.maintenance = .restore }.disabled(workspace?.connected != true || workspace?.hasRunningTasks != false)
        }
        CommandGroup(after: .pasteboard) {
            Button("Add Row") {
                if gridFocused, let tab = workspace?.active { tab.editor = RowChange(original: nil) }
            }.keyboardShortcut(map[.add].shortcut).disabled(!gridFocused || workspace?.active?.canInsert != true)
            Button("Duplicate Rows") {
                if gridFocused, let tab = workspace?.active { tab.duplicate(tab.selectedRows) }
            }.keyboardShortcut(map[.duplicate].shortcut).disabled(!gridFocused || workspace?.active?.canInsert != true || workspace?.active?.selectedRows.isEmpty != false)
            Button("Undo Staged Change") {
                if gridFocused { workspace?.active?.undoChange() }
            }.disabled(!gridFocused || workspace?.active?.editHistory.isEmpty != false)
            Button("Toggle Block Comment") {
                if let tab = activeTab { SQLDocument.toggleBlockComment(in: tab) }
            }.keyboardShortcut(map[.block].shortcut).disabled(!sqlFocused)
            ForEach([BrowserAction.bigger, .smaller], id: \.self) { action in
                Button(action.rawValue) {
                    let size = BrowserPreferences.integer("queryFontSize", fallback: 13, range: 9...28)
                    BrowserPreferences.defaults.set(min(28, max(9, size + (action == .bigger ? 1 : -1))), forKey: "queryFontSize")
                }.keyboardShortcut(map[action].shortcut).disabled(!sqlFocused)
            }
            Button("Complete SQL") {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.complete(nil)
            }.keyboardShortcut(map[.complete].shortcut).disabled(!sqlFocused)
            Button("Toggle Line Comment") {
                if sqlFocused, let tab = workspace?.active { SQLDocument.toggleComment(in: tab) }
            }.keyboardShortcut(map[.comment].shortcut).disabled(!sqlFocused)
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh Data") {
                if let workspace, let activeTab { Task { await workspace.refresh(activeTab) } }
            }.keyboardShortcut(map[.refresh].shortcut)
                .disabled(workspace?.canRefreshActiveTable != true)
            Button("Show Filters") { activeTab?.toggleFilters() }.keyboardShortcut(map[.filters].shortcut).disabled(!gridFocused)
            Button(workspace?.focusArea == .filter ? "Apply All Conditions" : "Run Current Statement") {
                if let workspace, let activeTab {
                    if workspace.focusArea == .filter { Task { await workspace.applyFilters(activeTab) } }
                    else if sqlFocused { activeTab.runRequest = UUID() }
                }
            }.keyboardShortcut(map[.run].shortcut)
                .disabled(workspace?.connected != true || activeTab?.busy != false || !(sqlFocused || (workspace?.focusArea == .filter && activeTab?.filterEditorVisible == true)))
            Button("Choose Columns…") { activeTab?.columnsShown.toggle() }.keyboardShortcut(map[.columns].shortcut).disabled(!gridFocused)
            Button("Previous Page") { changePage(forward: false) }.keyboardShortcut(map[.back].shortcut)
                .disabled(!gridFocused || activeTab?.busy != false || (activeTab?.offset ?? 0) == 0)
            Button("Next Page") { changePage(forward: true) }.keyboardShortcut(map[.forward].shortcut)
                .disabled(!gridFocused || activeTab?.busy != false || activeTab?.hasNextPage != true)
            Button("Preview Changes…") { activeTab?.previewShown = true }.keyboardShortcut(map[.preview].shortcut)
                .disabled(activeTab?.changes.isEmpty != false || workspace?.connected != true)
            Divider()
            Toggle("Item List", isOn: flag(\.showItems)).disabled(workspace == nil)
            Toggle("Row Detail", isOn: flag(\.showDetails)).disabled(workspace == nil)
            Toggle("SQL Console", isOn: flag(\.showConsole))
                .keyboardShortcut(map[.console].shortcut).disabled(workspace == nil)
        }
        CommandMenu("Database") {
            Button("New Table…") { workspace?.schemaDraft = SchemaDraft(kind: .table) }.disabled(workspace?.connected != true)
            Button("New View…") { workspace?.schemaDraft = SchemaDraft(kind: .view) }.disabled(workspace?.connected != true)
            if workspace?.profile.driver == .mariaDB {
                Divider()
                Button("New Procedure…") { workspace?.schemaDraft = SchemaDraft(kind: .procedure) }.disabled(workspace?.connected != true)
                Button("New Function…") { workspace?.schemaDraft = SchemaDraft(kind: .function) }.disabled(workspace?.connected != true)
                Divider()
                Button("Server Accounts…") { workspace?.serverTool = .accounts }.disabled(workspace?.connected != true)
                Button("Process List…") { workspace?.serverTool = .processes }.disabled(workspace?.connected != true)
            }
        }
        CommandMenu("Navigate") {
            ForEach([BrowserAction.previousTab, .nextTab, .previousPane, .nextPane, .previousWorkspace, .nextWorkspace, .data, .structure], id: \.self) { action in
                Button(action.rawValue) { navigate(action) }.keyboardShortcut(map[action].shortcut)
                    .disabled(workspace == nil || ([.data,.structure].contains(action) && activeTab?.object == nil))
            }
        }
        CommandGroup(before: .windowList) {
            Button("Show Workspaces") { openWindow(id: "workspaces") }
        }
        CommandMenu("Connection") {
            Button("Open Anything…") { workspace?.objectSearchShown = true }.keyboardShortcut(map[.search].shortcut).disabled(workspace?.connected != true)
            Button("Change Database…") { workspace?.databaseSelectorShown = true }
                .disabled(workspace?.profile.driver != .mariaDB || workspace?.connected != true)
            Divider()
            Button("Disconnect") { if let workspace { Task { await workspace.disconnect() } } }
                .disabled(workspace?.connected != true || workspace?.hasRunningTasks == true)
            Button("Reconnect") { if let workspace { Task { await workspace.reconnect() } } }
                .disabled(workspace?.connected != false || workspace?.reconnecting == true)
        }
    }
    private func navigate(_ action: BrowserAction) {
        guard let w = workspace else { return }
        switch action {
        case .nextTab, .previousTab:
            guard !w.tabs.isEmpty else { return }
            let i = w.tabs.firstIndex { $0.id == w.activeID } ?? 0
            w.activeID = w.tabs[(i + (action == .nextTab ? 1 : -1) + w.tabs.count) % w.tabs.count].id
        case .data, .structure: activeTab?.showStructure = action == .structure
        case .nextWorkspace, .previousWorkspace:
            registry.cycle(forward: action == .nextWorkspace)
        case .nextPane, .previousPane: w.paneDirection = action == .nextPane ? 1 : -1; w.paneRequest = UUID()
        default: break
        }
    }
    private func changePage(forward: Bool) {
        guard gridFocused, let workspace, let tab = activeTab else { return }
        tab.offset = max(0, tab.offset + (forward ? tab.limit : -tab.limit))
        Task { await workspace.load(tab) }
    }
    private func openSQL() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.connectionSQL, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let workspace {
            do { workspace.newQuery(text: try SQLFileDocument.decode(Data(contentsOf: url)), file: url) }
            catch { workspace.error = error.localizedDescription }
        } else {
            Task { do { try await openDocument(at: url) } catch { NSApp.presentError(error) } }
        }
    }
    private var gridFocused: Bool {
        workspace?.focusArea == .grid && workspace?.connected == true && workspace?.active?.showStructure == false
            && NSApp.keyWindow?.firstResponder is DataGrid.GridTable
    }
    private var sqlFocused: Bool {
        guard let workspace, let tab = workspace.active, tab.object == nil,
              let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return textView.accessibilityIdentifier() == "SQL Editor"
    }
    private func flag(_ key: ReferenceWritableKeyPath<Workspace, Bool>) -> Binding<Bool> {
        Binding(get: { workspace?[keyPath: key] ?? false }, set: { workspace?[keyPath: key] = $0 })
    }
}

struct ObjectSearch: View {
    let workspace: Workspace
    @State private var term = ""
    @State private var selection: DatabaseObject.ID?
    @Environment(\.dismiss) private var dismiss
    private var matches: [DatabaseObject] { workspace.objects.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) } }
    var body: some View {
        VStack(alignment: .leading) {
            Text("Open Anything").font(.headline).frame(maxWidth: .infinity)
            ChromeSearchField(title: "Search objects in " + workspace.database, text: $term)
            List(matches, selection: $selection) { object in
                HStack { Text(object.name); Spacer(); Text(object.kind.rawValue).foregroundStyle(.secondary) }
                    .tag(object.id).contentShape(Rectangle()).onTapGesture(count: 2) { open(object) }
            }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { if let target = selection ?? matches.first { open(target) } }
                    .keyboardShortcut(.defaultAction).disabled(matches.isEmpty)
            }
        }.padding(16).frame(width: 400, height: 430).background(BrowserChrome.paper)
        .onChange(of: term) { selection = matches.first }
    }
    private func open(_ object: DatabaseObject) { dismiss(); Task { await workspace.open(object) } }
}

struct DatabaseChooser: View {
    let workspace: Workspace
    @State private var names: [String] = []
    @State private var search = ""
    @State private var selected: String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text("Change Database").font(.headline).frame(maxWidth: .infinity)
            Text("Switching databases closes object tabs and clears results. SQL text is kept.").font(.caption)
            ChromeSearchField(title: "Search databases", text: $search)
            List(names.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self, selection: $selected) { Text($0) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") {
                    guard let selected else { return }
                    Task {
                        do { try await workspace.switchDatabase(to: selected); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(selected == nil)
            }
        }.padding(16).frame(width: 400, height: 430).background(BrowserChrome.paper)
        .task {
            do { names = try await workspace.session.query("SHOW DATABASES", limit: .max).rows.map { $0[0].display }; selected = workspace.database }
            catch { self.error = error.localizedDescription }
        }
    }
}
