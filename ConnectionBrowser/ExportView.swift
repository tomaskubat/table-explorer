import SwiftUI

struct ExportView: View {
    let workspace: Workspace
    let tab: WorkspaceTab
    @State private var format = ExportFormat.csv
    @State private var scope: ExportScope
    @State private var included: Set<String>
    @State private var csv = CSVSettings()
    @State private var file = ""
    @State private var tableName: String
    @State private var includeDDL = false
    @State private var includeData = true
    @State private var includeDrop = false
    @State private var overwrite = false
    @State private var busy = false
    @State private var job: Task<Void, Never>?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(workspace: Workspace, tab: WorkspaceTab) {
        self.workspace = workspace; self.tab = tab
        _scope = State(initialValue: tab.object == nil ? .result : .filtered)
        _included = State(initialValue: Set(tab.result.columns).subtracting(tab.hiddenColumns))
        _tableName = State(initialValue: tab.object?.name ?? "query_result")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Data").font(.title2)
            Text("Source: \(workspace.profile.name) / \(workspace.database) / \(tab.title)")
            Group {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue) }
                }.pickerStyle(.segmented)
                Picker("Rows", selection: $scope) {
                    Text(tab.object == nil ? "Displayed query result" : "Current page").tag(ExportScope.result)
                    if tab.selected != nil { Text("Selected rows").tag(ExportScope.selected) }
                    if tab.object != nil {
                        Text("All filtered rows").tag(ExportScope.filtered); Text("Entire table").tag(ExportScope.table)
                    }
                }
                DisclosureGroup("Fields (\(included.count) of \(tab.result.columns.count))") {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(Array(Set(tab.result.columns)).sorted(), id: \.self) { name in
                                Toggle(name, isOn: Binding(get: { included.contains(name) }, set: { value in
                                    if value { included.insert(name) } else { included.remove(name) }
                                }))
                            }
                        }
                    }.frame(maxHeight: 90)
                }
                if format == .csv { CSVOptionsView(settings: $csv, importing: false) }
                if format == .sql {
                    TextField("Target Table", text: $tableName).disabled(tab.object != nil)
                    HStack {
                        Toggle("Schema", isOn: $includeDDL).disabled(tab.object == nil)
                        Toggle("Data", isOn: $includeData)
                        Toggle("DROP statement", isOn: $includeDrop)
                    }
                }
                HStack {
                    TextField("Destination File", text: $file).accessibilityIdentifier("Destination File")
                    Button("Choose…") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = tableName + "." + format.rawValue.lowercased()
                        if panel.runModal() == .OK, let url = panel.url { file = url.path }
                    }
                }
            }.disabled(busy)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(busy ? "Cancel Export" : "Cancel") { if busy { job?.cancel() } else { dismiss() } }
                Button("Write Export") {
                    if FileManager.default.fileExists(atPath: file) { overwrite = true } else { start(overwrite: false) }
                }.disabled(busy || included.isEmpty || !file.hasPrefix("/") || (format == .sql && (!includeData && !includeDDL && !includeDrop || tableName.isEmpty)))
            }
        }.padding(18).frame(width: 550, height: 395)
        .interactiveDismissDisabled(busy)
        .confirmationDialog("Replace the existing export file?", isPresented: $overwrite) {
            Button("Replace", role: .destructive) { start(overwrite: true) }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func start(overwrite: Bool) {
        let indices = tab.result.columns.indices.filter { included.contains(tab.result.columns[$0]) }
        let columns = indices.map { tab.result.columns[$0] }
        let rows: [[SQLValue]]
        var read: TableRead?
        if (scope == .table || scope == .filtered), let object = tab.object {
            read = TableRead(object: object, filters: scope == .filtered ? tab.appliedFilters : [], sortColumn: tab.sortColumn, descending: tab.descending, keyColumns: tab.schema?.key.map(\.name) ?? [])
            rows = []
        } else {
            let selected = scope == .selected ? tab.selected.map { [$0] } ?? [] : Array(tab.result.rows.indices)
            rows = selected.filter(tab.result.rows.indices.contains).map { row in indices.map { tab.result.rows[row][$0] } }
        }
        let request = ExportRequest(destination: URL(filePath: file), overwrite: overwrite, driver: workspace.profile.driver,
                                    format: format, scope: scope, csv: csv, object: tab.object, columns: columns,
                                    rows: rows, read: read, includeDDL: includeDDL, includeData: includeData,
                                    includeDrop: includeDrop, outputTable: tableName)
        error = nil; busy = true
        job = Task {
            defer { busy = false; job = nil }
            do {
                let count = try await workspace.session.export(request)
                workspace.log.append("Exported \(count) rows as \(format.rawValue) to \(request.destination.lastPathComponent).")
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
