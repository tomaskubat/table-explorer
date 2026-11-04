import SwiftUI

struct ImportCSVView: View {
    enum Target: Hashable { case existing(String), newTable }
    let workspace: Workspace
    @State private var target: Target
    @State private var tableName = ""
    @State private var fields: [ColumnInfo] = []
    @State private var newColumns: [CSVImportColumn] = []
    @State private var file = ""
    @State private var settings = CSVSettings()
    @State private var document: CSVDocument?
    @State private var preview = QueryResult()
    @State private var mapping: [String?] = []
    @State private var error: String?
    @State private var version = UUID()
    @State private var importing = false
    @State private var job: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(workspace: Workspace, tab: WorkspaceTab?) {
        self.workspace = workspace
        let current = tab?.object.flatMap { $0.kind == .table ? $0.name : nil }
        let first = current ?? workspace.objects.first(where: { $0.kind == .table })?.name
        _target = State(initialValue: first.map(Target.existing) ?? .newTable)
    }

    private var ddl: String? {
        try? CSVImportColumn.createTable(tableName, columns: newColumns, driver: workspace.profile.driver)
    }
    private var ready: Bool {
        guard document != nil, !importing else { return false }
        switch target {
        case .newTable: return ddl != nil
        case .existing: return mapping.contains { $0 != nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Import CSV").font(.title2)
            Text(workspace.profile.name + " / " + workspace.database).foregroundStyle(.secondary)
            Group {
                HStack {
                    TextField("Source File", text: $file).accessibilityIdentifier("Source File")
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        if panel.runModal() == .OK, let url = panel.url { file = url.path }
                    }
                }
                HStack {
                    Picker("Destination Table", selection: $target) {
                        ForEach(workspace.objects.filter { $0.kind == .table }) { object in Text(object.name).tag(Target.existing(object.name)) }
                        Divider(); Text("Create New Table").tag(Target.newTable)
                    }.accessibilityIdentifier("Import Destination")
                    if target == .newTable { TextField("New Table Name", text: $tableName).accessibilityIdentifier("New Table Name") }
                }
                CSVOptionsView(settings: $settings, importing: true)
                Button("Preview Import") { load() }.disabled(file.isEmpty)
                if document != nil {
                    Text("Field mapping").font(.headline)
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(preview.columns.indices, id: \.self) { index in
                                VStack(alignment: .leading) {
                                    Text(preview.columns[index]).font(.caption)
                                    if target == .newTable, newColumns.indices.contains(index) {
                                        Toggle("Include", isOn: $newColumns[index].include)
                                        TextField("Column Name", text: $newColumns[index].name).disabled(!newColumns[index].include)
                                        Picker("Type", selection: $newColumns[index].storage) {
                                            ForEach(CSVImportColumn.Storage.allCases, id: \.self) { Text($0 == .blob ? "Blob (Base64)" : $0.rawValue).tag($0) }
                                        }.accessibilityIdentifier("type-" + String(index))
                                    } else if mapping.indices.contains(index) {
                                        Picker("Destination for " + preview.columns[index], selection: $mapping[index]) {
                                            Text("Skip").tag(nil as String?)
                                            ForEach(fields) { column in Text(column.name).tag(Optional(column.name)) }
                                        }.labelsHidden()
                                    }
                                }.frame(minWidth: 100)
                            }
                        }
                    }
                    if target == .newTable {
                        Text(ddl ?? "Enter distinct column names and a table name.")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("importDDL")
                    }
                    Text("Preview · \(preview.rows.count) rows\(preview.truncated ? " (first 100)" : "")").font(.caption)
                    ResultTable(result: preview, selected: .constant(nil))
                } else { Spacer() }
            }.disabled(importing)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("importError") }
            HStack {
                Spacer()
                Button(importing ? "Cancel Import" : "Cancel") { if importing { job?.cancel() } else { dismiss() } }
                Button(target == .newTable ? "Create and Import" : "Import Rows") { startImport() }.disabled(!ready)
            }
        }
        .padding(18).frame(width: 680, height: target == .newTable ? 560 : 470)
        .onChange(of: file) { version = UUID(); document = nil; error = nil }
        .onChange(of: settings) { if !file.isEmpty { load() } }
        .onChange(of: target) { if !file.isEmpty { load() } }
        .interactiveDismissDisabled(importing)
    }

    private func load() {
        let ticket = UUID(); version = ticket
        document = nil; error = nil
        let source = URL(filePath: file), options = settings, destination = target
        Task {
            do {
                let (document, result) = try await Task.detached {
                    let doc = try CSVDocument(file: source, settings: options)
                    return try (doc, doc.preview())
                }.value
                var columns: [ColumnInfo] = []
                if case let .existing(name) = destination {
                    let schema = try await workspace.session.schema(of: DatabaseObject(name: name, kind: .table), driver: workspace.profile.driver)
                    guard schema.transactional else { throw BrowserError("Choose a transactional destination table.") }
                    columns = schema.columns.filter { !$0.generated }
                }
                guard version == ticket else { return }
                fields = columns
                mapping = result.columns.enumerated().map { index, name in
                    if options.header { return columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.name }
                    return columns.indices.contains(index) ? columns[index].name : nil
                }
                newColumns = result.columns.enumerated().map { index, name in CSVImportColumn(name: name.isEmpty ? "field_" + String(index + 1) : name) }
                if tableName.isEmpty { tableName = source.deletingPathExtension().lastPathComponent }
                preview = result; self.document = document
            } catch { if version == ticket { self.error = error.localizedDescription } }
        }
    }

    private func startImport() {
        guard ready, let document else { return }
        let object: DatabaseObject
        let creating = target == .newTable
        switch target {
        case let .existing(name): object = DatabaseObject(name: name, kind: .table)
        case .newTable: object = DatabaseObject(name: tableName, kind: .table)
        }
        if workspace.tabs.contains(where: { $0.object == object && !$0.changes.isEmpty }) {
            error = "Resolve pending row changes on the destination table before importing."; return
        }
        importing = true; error = nil
        workspace.transferBusy = true
        let selected = creating ? newColumns.map { $0.include ? $0.name : nil } : mapping
        let columns = creating ? newColumns : nil
        job = Task {
            defer { importing = false; job = nil; workspace.transferBusy = false }
            do {
                let count = try await workspace.session.importCSV(document, mapping: selected, object: object, driver: workspace.profile.driver, newColumns: columns)
                workspace.log.append("Imported \(count) rows into \(object.name).")
                if creating {
                    await workspace.reloadObjects()
                    await workspace.open(object)
                } else {
                    for tab in workspace.tabs.filter({ $0.object == object }) { await workspace.load(tab) }
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CSVOptionsView: View {
    @Binding var settings: CSVSettings
    let importing: Bool
    var body: some View {
        HStack {
            Picker("Delimiter", selection: $settings.delimiter) {
                Text("Comma").tag(","); Text("Semicolon").tag(";"); Text("Tab").tag("\t")
            }.accessibilityIdentifier("CSV Delimiter")
            Picker("Quote", selection: $settings.quote) { Text("\"").tag("\""); Text("'").tag("'") }
            if importing {
                Picker("Encoding", selection: $settings.encoding) { ForEach(["UTF-8", "UTF-16", "Latin-1"], id: \.self) { Text($0) } }
            } else {
                Picker("Line ending", selection: $settings.lineEnding) { Text("LF").tag("LF"); Text("CRLF").tag("CRLF") }.accessibilityIdentifier("CSV Line Ending")
            }
        }
        HStack {
            Toggle("Header row", isOn: $settings.header)
            TextField("NULL token", text: $settings.nullToken).frame(width: 115)
            if !importing {
                Toggle("Quote all fields", isOn: $settings.quoteAll)
                Toggle("Decimal comma", isOn: $settings.decimalComma)
            }
        }
    }
}
