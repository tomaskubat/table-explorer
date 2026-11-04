import SwiftUI

struct RowActions: View {
    let workspace: Workspace
    @Bindable var tab: WorkspaceTab
    private var canWrite: Bool { workspace.connected && !tab.busy && tab.object?.kind == .table && tab.schema?.transactional == true }
    private var selectedDraft: RowChange? { tab.selected.flatMap(tab.editRow) }
    private var canEdit: Bool {
        guard canWrite, let draft = selectedDraft, let schema = tab.schema else { return false }
        return draft.original == nil || (!schema.key.isEmpty && schema.key.allSatisfy { draft.original?[$0.name] != .null })
    }

    var body: some View {
        HStack(spacing: 3) { editingButtons; changeButtons }
        .controlSize(.small)
        .sheet(item: $tab.editor) { draft in
            if let schema = tab.schema { RowEditor(draft: draft, schema: schema) { tab.stage($0) } }
        }
        .sheet(item: $tab.cellEditor, onDismiss: { tab.grid?.restoreCellFocus() }) { target in
            CellEditor(target: target, tab: tab)
        }
        .sheet(isPresented: $tab.previewShown) { ChangePreview(workspace: workspace, tab: tab) }
    }

    @ViewBuilder private var editingButtons: some View {
        Button { tab.editor = RowChange(original: nil) } label: { Label("Row", systemImage: "plus") }
            .accessibilityLabel("Add Row").help("Add row").disabled(!canWrite)
        Button("Edit Row", systemImage: "pencil") { tab.editor = selectedDraft }.labelStyle(.iconOnly).help("Edit row").disabled(!canEdit)
        Menu {
            Button("Duplicate Rows") { tab.duplicate(tab.selectedRows) }.disabled(!canWrite || tab.selectedRows.isEmpty)
            Button("Mark for Deletion…") { tab.deletionReview = tab.deletions(tab.selectedRows) }.disabled(!canEdit)
            Button("Undo Last Change") { tab.undoChange() }.disabled(tab.editHistory.isEmpty)
        } label: { Image(systemName: "chevron.down") }.menuIndicator(.hidden).fixedSize().accessibilityLabel("Row Actions").help("Row actions")
    }

    @ViewBuilder private var changeButtons: some View {
        if !tab.changes.isEmpty {
            Button("Preview Changes") { tab.commitError = nil; tab.previewShown = true }
                .disabled(tab.busy)
            Button("Discard Changes") { tab.discard() }.disabled(tab.busy)
            Text("\(tab.changes.count) pending").font(.caption).bold()
        }
    }
}

private struct RowEditor: View {
    enum Input: String, CaseIterable { case value = "Value", null = "NULL", omitted = "Default" }
    let draft: RowChange
    let schema: ObjectSchema
    let save: (RowChange) -> Void
    @State private var values: [String: String]
    @State private var modes: [String: Input]
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(draft: RowChange, schema: ObjectSchema, save: @escaping (RowChange) -> Void) {
        self.draft = draft; self.schema = schema; self.save = save
        let current = (draft.original ?? [:]).merging(draft.changes) { _, new in new }
        _values = State(initialValue: current.mapValues { $0 == .null ? "" : $0.display })
        var modes = current.mapValues { $0 == .null ? Input.null : .value }
        for name in draft.defaults { modes[name] = .omitted }
        _modes = State(initialValue: modes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "New Row" : "Edit Row").font(.title2)
            ScrollView {
                Grid(alignment: .leading) {
                    ForEach(schema.columns) { column in
                        GridRow {
                            VStack(alignment: .leading) { Text(column.name); Text(column.type).font(.caption).foregroundStyle(.secondary) }
                            TextField(column.name, text: Binding(get: { values[column.name] ?? "" }, set: {
                                values[column.name] = $0; modes[column.name] = .value
                            })).accessibilityIdentifier("edit-" + column.name)
                            Picker(column.name, selection: Binding(get: { modes[column.name] ?? .omitted }, set: { modes[column.name] = $0 })) {
                                Text("Value").tag(Input.value)
                                if column.nullable { Text("NULL").tag(Input.null) }
                                if draft.original == nil || column.defaultSQL != nil || column.nullable { Text("Default").tag(Input.omitted) }
                            }.labelsHidden().frame(width: 90).accessibilityIdentifier("mode-" + column.name)
                        }.disabled(column.generated)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Stage Changes") {
                    do { save(try changed()); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 520, height: 320)
    }

    private func changed() throws -> RowChange {
        var edit = draft
        edit.changes = [:]; edit.defaults = []; edit.deleted = false
        for column in schema.columns where !column.generated {
            let name = column.name
            let old = draft.original?[name]
            let value: SQLValue
            switch modes[name] ?? .omitted {
            case .omitted:
                if draft.original != nil { edit.defaults.insert(name) }
                continue
            case .null: value = .null
            case .value:
                let text = values[name] ?? ""
                if let old, old != .null && old.display == text { continue }
                if case .blob = old { throw BrowserError("Binary values require a binary editor.") }
                // Keep SQL literals as bound text. The declared column affinity
                // performs the same conversion as a value typed into the grid.
                value = .text(text)
            }
            if value != old { edit.changes[name] = value }
        }
        return edit
    }
}

private struct ChangePreview: View {
    let workspace: Workspace
    @Bindable var tab: WorkspaceTab
    @Environment(\.dismiss) private var dismiss
    private var sql: String {
        guard let object = tab.object, let schema = tab.schema else { return "" }
        do { return try tab.changes.map { try ChangeSQL.statement($0, object: object, schema: schema, driver: workspace.profile.driver).preview }.joined(separator: "\n") }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview Changes").font(.title2)
            Text("\(workspace.profile.name) / \(workspace.database) / \(tab.title)").foregroundStyle(.secondary)
            ScrollView { Text(sql).font(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("changePreviewSQL").frame(maxWidth: .infinity, alignment: .leading) }
            if let error = tab.commitError { Text(error).foregroundStyle(.red).accessibilityIdentifier("commitError") }
            HStack {
                Spacer()
                Button("Close Preview") { tab.closeAfterCommit = false; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Commit Changes") { Task { await workspace.commit(tab) } }.keyboardShortcut("s").disabled(tab.busy || !workspace.connected)
            }
        }.padding(20).frame(width: 550, height: 280).interactiveDismissDisabled(tab.busy)
        .onDisappear { tab.closeAfterCommit = false }
    }
}
