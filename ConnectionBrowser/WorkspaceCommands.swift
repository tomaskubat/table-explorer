import SwiftUI

private struct WorkspaceKey: FocusedValueKey { typealias Value = Workspace }
extension FocusedValues {
    var connectionWorkspace: Workspace? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.connectionWorkspace) private var workspace
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Saved Connections") { openWindow(id: "connections") }.keyboardShortcut("n")
            Button("New Query") { workspace?.newQuery() }.keyboardShortcut("t").disabled(workspace == nil)
        }
        CommandGroup(after: .importExport) {
            Button("Import CSV…") { workspace?.csvImportShown = true }.disabled(workspace?.connected != true || workspace?.hasRunningTasks != false || workspace?.database.isEmpty != false)
            Button("Backup Database…") { workspace?.maintenance = .backup }.disabled(workspace?.connected != true || workspace?.hasRunningTasks != false)
            Button("Restore Database…") { workspace?.maintenance = .restore }.disabled(workspace?.connected != true || workspace?.hasRunningTasks != false)
        }
        CommandGroup(after: .pasteboard) {
            Button("Add Row") {
                if gridFocused, let tab = workspace?.active { tab.editor = RowChange(original: nil) }
            }.keyboardShortcut("i").disabled(!gridFocused || workspace?.active?.canInsert != true)
            Button("Duplicate Rows") {
                if gridFocused, let tab = workspace?.active { tab.duplicate(tab.selectedRows) }
            }.keyboardShortcut("d").disabled(!gridFocused || workspace?.active?.canInsert != true || workspace?.active?.selectedRows.isEmpty != false)
            Button("Undo Staged Change") {
                if gridFocused { workspace?.active?.undoChange() }
            }.disabled(!gridFocused || workspace?.active?.editHistory.isEmpty != false)
            Button("Toggle Line Comment") {
                if sqlFocused, let tab = workspace?.active { SQLDocument.toggleComment(in: tab) }
            }.keyboardShortcut("/").disabled(!sqlFocused)
        }
        CommandGroup(after: .sidebar) {
            Toggle("Item List", isOn: flag(\.showItems)).disabled(workspace == nil)
            Toggle("Row Detail", isOn: flag(\.showDetails)).disabled(workspace == nil)
            Toggle("SQL Console", isOn: flag(\.showConsole))
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(workspace == nil)
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
        CommandMenu("Connection") {
            Button("Open Anything…") { workspace?.objectSearchShown = true }.keyboardShortcut("p").disabled(workspace?.connected != true)
            Button("Change Database…") { workspace?.databaseSelectorShown = true }
                .disabled(workspace?.profile.driver != .mariaDB || workspace?.connected != true)
            Divider()
            Button("Disconnect") { if let workspace { Task { await workspace.disconnect() } } }
                .disabled(workspace?.connected != true || workspace?.hasRunningTasks == true)
            Button("Reconnect") { if let workspace { Task { await workspace.reconnect() } } }
                .disabled(workspace?.connected != false || workspace?.reconnecting == true)
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
            Text("Open Anything").font(.title2)
            TextField("Search objects in " + workspace.database, text: $term)
            List(matches, selection: $selection) { object in
                HStack { Text(object.name); Spacer(); Text(object.kind.rawValue).foregroundStyle(.secondary) }
                    .tag(object.id).contentShape(Rectangle()).onTapGesture(count: 2) { open(object) }
            }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { if let target = selection ?? matches.first { open(target) } }
                    .keyboardShortcut(.defaultAction).disabled(matches.isEmpty)
            }
        }.padding(16).frame(width: 420, height: 300)
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
            Text("Change Database").font(.title2)
            Text("Switching databases closes object tabs and clears results. SQL text is kept.").font(.caption)
            TextField("Search databases", text: $search)
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
        }.padding(16).frame(width: 420, height: 300)
        .task {
            do { names = try await workspace.session.query("SHOW DATABASES", limit: .max).rows.map { $0[0].display }; selected = workspace.database }
            catch { self.error = error.localizedDescription }
        }
    }
}
