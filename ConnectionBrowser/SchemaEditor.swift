import SwiftUI

struct SchemaEditor: View {
    let workspace: Workspace
    @State var draft: SchemaDraft
    @State private var statements: [String] = []
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New " + draft.kind.rawValue).font(.title2)
            Text(workspace.profile.name + " / " + workspace.database).foregroundStyle(.secondary)
            if statements.isEmpty {
                TextField("Object Name", text: $draft.name).accessibilityIdentifier("Object Name")
                if draft.kind == .view {
                    Text("View Definition").font(.headline)
                    TextEditor(text: $draft.select).font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("View Definition")
                } else if draft.isRoutine {
                    TextField("Parameters", text: $draft.parameters)
                    if draft.kind == .function { TextField("Return Type", text: $draft.returnType) }
                    Text("Routine Body").font(.headline)
                    TextEditor(text: $draft.routineBody).font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("Routine Body")
                    Text("Compound statements can use BEGIN and END. The routine runs with the caller’s privileges.").font(.caption)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Columns").font(.headline)
                            ForEach($draft.columns) { $column in
                                HStack {
                                    TextField("Name", text: $column.name)
                                    TextField("Type", text: $column.type)
                                    Toggle("NULL", isOn: $column.nullable)
                                    TextField("Default SQL", text: $column.defaultExpression)
                                    Button("Remove", systemImage: "minus.circle") { draft.columns.removeAll { $0.id == column.id } }.labelStyle(.iconOnly)
                                }
                            }
                            Button("Add Column") { draft.columns.append(DraftColumn()) }
                            Divider()
                            TextField("Primary key columns, in order", text: $draft.primaryKey)
                            ForEach($draft.indexes) { $index in
                                HStack {
                                    TextField("Index name", text: $index.name)
                                    TextField("Columns, in order", text: $index.columns)
                                    Toggle("Unique", isOn: $index.unique)
                                    Button("Remove", systemImage: "minus.circle") { draft.indexes.removeAll { $0.id == index.id } }.labelStyle(.iconOnly)
                                }
                            }
                            Button("Add Index") { draft.indexes.append(DraftIndex()) }
                            ForEach($draft.foreignKeys) { $key in
                                HStack {
                                    TextField("Local columns", text: $key.columns)
                                    TextField("Referenced table", text: $key.table)
                                    TextField("Referenced columns", text: $key.referenced)
                                    Button("Remove", systemImage: "minus.circle") { draft.foreignKeys.removeAll { $0.id == key.id } }.labelStyle(.iconOnly)
                                }
                            }
                            Button("Add Foreign Key") { draft.foreignKeys.append(DraftForeignKey()) }
                        }
                    }
                }
            } else {
                Text("DDL Preview").font(.headline)
                ScrollView {
                    Text(statements.joined(separator: ";\n") + ";").textSelection(.enabled).font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("ddlPreview")
                }
                if workspace.profile.driver == .mariaDB { Text("MariaDB commits DDL independently of row edits.").font(.caption) }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Discard Draft") { dismiss() }.keyboardShortcut(.cancelAction)
                if statements.isEmpty {
                    Button("Preview DDL") {
                        do { statements = try draft.ddl(workspace.profile.driver); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(draft.name.isEmpty)
                } else {
                    Button("Edit Draft") { statements = [] }
                    Button("Apply DDL") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                try await workspace.session.applySchema(statements, driver: workspace.profile.driver)
                                workspace.log.append(contentsOf: statements)
                                await workspace.reloadObjects(); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }.disabled(busy)
        }.padding(20).frame(width: 625, height: 420).interactiveDismissDisabled(busy)
    }
}

enum ServerTool: String, Identifiable {
    case accounts = "Server Accounts", processes = "Process List"
    var id: Self { self }
}

struct ServerToolSheet: View {
    let workspace: Workspace
    let tool: ServerTool
    @State private var result = QueryResult()
    @State private var selection: Int?
    @State private var details = ""
    @State private var error: String?
    @State private var confirmation: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tool.rawValue).font(.title2)
            Text(workspace.profile.name + " · " + workspace.profile.detail).foregroundStyle(.secondary)
            ResultTable(result: result, selected: $selection)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("serverToolError") }
            if !details.isEmpty { ScrollView { Text(details).textSelection(.enabled).font(.system(.caption, design: .monospaced)) }.frame(height: 75) }
            HStack {
                Button("Refresh") { Task { await refresh() } }
                if tool == .accounts {
                    Button("Show Grants") {
                        guard let row = selectedRow else { return }
                        let account = row.prefix(2).map { ChangeSQL.literal($0, driver: .mariaDB) }.joined(separator: "@")
                        Task {
                            do { details = try await workspace.session.query("SHOW GRANTS FOR " + account).rows.map { $0[0].display }.joined(separator: "\n") }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(selection == nil)
                } else {
                    Button("Kill Query…") { if let first = selectedRow?.first, Int64(first.display) != nil { confirmation = first.display } }.disabled(selection == nil)
                }
                Spacer()
                Button("Close Server Tool") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(16).frame(width: 700, height: 390)
        .task { await refresh() }
        .confirmationDialog("Kill query \(confirmation ?? "") on \(workspace.profile.name)?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { id in
            Button("Kill Query", role: .destructive) {
                Task {
                    do { _ = try await workspace.session.query("KILL QUERY " + id); await refresh() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    private var selectedRow: [SQLValue]? {
        guard let selection, result.rows.indices.contains(selection) else { return nil }
        return result.rows[selection]
    }
    private func refresh() async {
        error = nil; details = ""; selection = nil
        do { result = try await workspace.session.query(tool == .accounts ? "SELECT User,Host,plugin FROM mysql.user ORDER BY User,Host" : "SHOW FULL PROCESSLIST", limit: .max) }
        catch { result = QueryResult(); self.error = error.localizedDescription }
    }
}
