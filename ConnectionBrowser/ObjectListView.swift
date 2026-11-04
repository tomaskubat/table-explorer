import SwiftUI

struct ObjectListView: View {
    let workspace: Workspace
    let search: String
    @State private var selection: DatabaseObject?
    private var visible: [DatabaseObject] { workspace.objects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        List(selection: $selection) {
            let pinned = visible.filter { workspace.notebook.isPinned($0, database: workspace.database) }
            if !pinned.isEmpty { Section("Pinned") { ForEach(pinned) { row($0) } } }
            ForEach(DatabaseObject.Kind.allCases, id: \.self) { kind in
                let objects = visible.filter { $0.kind == kind && !workspace.notebook.isPinned($0, database: workspace.database) }
                if !objects.isEmpty {
                    Section(kind.rawValue + "s") { ForEach(objects) { row($0) } }
                }
            }
        }
        .contextMenu(forSelectionType: DatabaseObject.self) { objects in
            if let object = objects.first { menu(for: object) }
        } primaryAction: { objects in
            if let object = objects.first { Task { await workspace.open(object) } }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) {
            if let selection { Task { await workspace.open(selection) } }
        }
    }
    private func row(_ object: DatabaseObject) -> some View {
        let icons: [DatabaseObject.Kind: String] = [.table: "tablecells", .view: "eye", .procedure: "gearshape.2", .function: "function"]
        return Label(object.name, systemImage: icons[object.kind] ?? "tablecells")
            .tag(object).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    @ViewBuilder private func menu(for object: DatabaseObject) -> some View {
        Button("Open in New Tab") { Task { await workspace.open(object, newTab: true) } }
        Button("Open Structure") { Task { await workspace.open(object, structure: true) } }
        Button("Item Overview") { workspace.overviewShown = true }
        Button("Copy Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(object.name, forType: .string) }
        Button(workspace.notebook.isPinned(object, database: workspace.database) ? "Unpin" : "Pin to Top") {
            workspace.notebook.togglePin(object, database: workspace.database)
        }
        if [.table, .view].contains(object.kind) {
            Button("Export Entire Object…") { Task { await workspace.open(object); workspace.active?.transfer = .exportTable } }
            if object.kind == .table {
                Button("Import CSV…") { Task { await workspace.open(object); workspace.active?.transfer = .importCSV } }
            }
        }
        Menu("New") {
            Button("Table…") { workspace.schemaDraft = SchemaDraft(kind: .table) }
            Button("View…") { workspace.schemaDraft = SchemaDraft(kind: .view) }
            if workspace.profile.driver == .mariaDB {
                Button("Procedure…") { workspace.schemaDraft = SchemaDraft(kind: .procedure) }
                Button("Function…") { workspace.schemaDraft = SchemaDraft(kind: .function) }
            }
        }
        if object.kind == .table || object.kind == .view {
            operation(.clone, object)
            if object.kind == .table || workspace.profile.driver == .mariaDB { operation(.rename, object) }
        }
        if object.kind == .table { operation(.addColumn, object); operation(.addIndex, object); operation(.empty, object) }
        operation(.drop, object)
    }
    private func operation(_ action: ObjectOperation, _ object: DatabaseObject) -> some View {
        Button(action.rawValue + "…") { workspace.operation = ObjectOperationTarget(object: object, operation: action) }
            .disabled(!workspace.connected || workspace.hasRunningTasks)
    }
}

struct ObjectOperationView: View {
    let workspace: Workspace
    let target: ObjectOperationTarget
    @State private var name = ""
    @State private var definition = ""
    @State private var includeData = true
    @State private var unique = false
    @State private var statements: [String] = []
    @State private var confirmation = ""
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.operation.rawValue + " · " + target.object.name).font(.title2)
            Text(workspace.profile.name + " / " + workspace.database + " / " + target.object.name)
            if statements.isEmpty {
                if !target.operation.destructive {
                    TextField("New Object Name", text: $name).accessibilityIdentifier("New Object Name")
                }
                if target.operation == .clone && target.object.kind == .table {
                    Toggle("Copy rows", isOn: $includeData)
                    Text("The preview includes columns, keys and indexes. Table triggers are managed separately.").font(.caption)
                }
                if target.operation == .addColumn { TextField("Column definition, e.g. TEXT NOT NULL", text: $definition) }
                if target.operation == .addIndex { TextField("Column names in index order", text: $definition); Toggle("Unique", isOn: $unique) }
            } else {
                ScrollView {
                    Text(statements.joined(separator: ";\n") + ";").font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("objectPreview")
                }
                if target.operation.destructive {
                    Text(target.operation == .empty ? "All rows will be removed. Foreign key rules apply." : "This database object will be removed.")
                    TextField("Type the object name to confirm", text: $confirmation).accessibilityIdentifier("Confirm Object Name")
                }
                if workspace.profile.driver == .mariaDB { Text("MariaDB DDL may commit each statement independently.").font(.caption) }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if statements.isEmpty { Button("Preview Operation") { Task { await preview() } } }
                else {
                    Button("Back") { statements = []; error = nil }
                    Button("Apply Operation") { Task { await apply() } }.disabled(target.operation.destructive && confirmation != target.object.name)
                }
            }.disabled(busy)
        }.padding(20).frame(width: 560, height: 380).interactiveDismissDisabled(busy)
        .onAppear { if target.operation == .clone { name = target.object.name + "_copy" } }
    }
    private func preview() async {
        guard !workspace.tabs.contains(where: { $0.object == target.object && !$0.changes.isEmpty }) else {
            error = "Resolve pending row changes on this object first."; return
        }
        busy = true; defer { busy = false }
        do {
            statements = try await workspace.session.planObjectOperation(target, driver: workspace.profile.driver, name: name, definition: definition,
                                                                         includeData: includeData, unique: unique)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func apply() async {
        busy = true; defer { busy = false }
        do {
            try await workspace.session.applyObjectOperation(statements, driver: workspace.profile.driver)
            workspace.log.append(contentsOf: statements)
            for tab in workspace.tabs.filter({ $0.object == target.object }) {
                if target.operation == .drop || target.operation == .rename { workspace.closeTab(tab) }
                else if tab.object?.kind == .table {
                    tab.schema = try await workspace.session.schema(of: target.object, driver: workspace.profile.driver)
                    await workspace.load(tab)
                    if tab.showStructure { await workspace.loadStructure(tab) }
                }
            }
            await workspace.reloadObjects(); dismiss()
        } catch { self.error = error.localizedDescription; await workspace.reloadObjects() }
    }
}

struct OverviewView: View {
    let workspace: Workspace
    @State private var result = QueryResult()
    @State private var selection: Int?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text("Object Overview").font(.title2)
            Text(workspace.profile.name + " / " + workspace.database).foregroundStyle(.secondary)
            ResultTable(result: result, selected: $selection)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Close Overview") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(16).frame(width: 700, height: 400)
        .task { do { result = try await workspace.session.overview(driver: workspace.profile.driver) } catch { self.error = error.localizedDescription } }
    }
}
