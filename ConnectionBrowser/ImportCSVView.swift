import SwiftUI

struct ImportCSVView: View {
    let workspace: Workspace
    let tab: WorkspaceTab
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import CSV").font(.title2)
            Text("Target: \(workspace.profile.name) / \(workspace.database) / \(tab.title)")
            HStack {
                TextField("Source File", text: $file).accessibilityIdentifier("Source File")
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK, let url = panel.url { file = url.path }
                }
            }
            CSVOptionsView(settings: $settings, importing: true)
            Button("Preview Import") { load() }.disabled(file.isEmpty || importing)
            if document != nil {
                Text("Field mapping").font(.headline)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(preview.columns.indices, id: \.self) { i in
                            VStack(alignment: .leading) {
                                Text(preview.columns[i]).font(.caption)
                                Picker("Destination for \(preview.columns[i])", selection: $mapping[i]) {
                                    Text("Skip").tag(nil as String?)
                                    ForEach((tab.schema?.columns ?? []).filter { !$0.generated }) { column in
                                        Text(column.name).tag(Optional(column.name))
                                    }
                                }.labelsHidden()
                            }.frame(minWidth: 100)
                        }
                    }
                }
                Text("Preview · \(preview.rows.count) rows\(preview.truncated ? " (first 100)" : "")").font(.caption)
                ResultTable(result: preview, selected: .constant(nil))
            } else { Spacer() }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("importError") }
            HStack {
                Spacer()
                Button(importing ? "Cancel Import" : "Cancel") { if importing { job?.cancel() } else { dismiss() } }
                Button("Import Rows") { startImport() }.disabled(document == nil || importing || mapping.compactMap { $0 }.isEmpty)
            }
        }
        .padding(18).frame(width: 620, height: 470)
        .onChange(of: file) { version = UUID(); document = nil; error = nil }
        .onChange(of: settings) { if !file.isEmpty { load() } }
        .interactiveDismissDisabled(importing)
    }

    private func load() {
        let ticket = UUID(); version = ticket
        document = nil; error = nil
        let source = URL(filePath: file), options = settings
        Task {
            do {
                let (document, result) = try await Task.detached {
                    let doc = try CSVDocument(file: source, settings: options)
                    return try (doc, doc.preview())
                }.value
                guard version == ticket else { return }
                let columns = tab.schema?.columns.filter { !$0.generated } ?? []
                mapping = result.columns.enumerated().map { index, name in
                    if options.header { return columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.name }
                    return columns.indices.contains(index) ? columns[index].name : nil
                }
                preview = result; self.document = document
            } catch { if version == ticket { self.error = error.localizedDescription } }
        }
    }

    private func startImport() {
        guard !importing, let document, let object = tab.object else { return }
        importing = true; error = nil
        let selected = mapping
        job = Task {
            defer { importing = false; job = nil }
            do {
                let count = try await workspace.session.importCSV(document, mapping: selected, object: object, driver: workspace.profile.driver)
                workspace.log.append("Imported \(count) rows into \(object.name).")
                await workspace.load(tab); dismiss()
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
            }
            Picker("Quote", selection: $settings.quote) { Text("\"").tag("\""); Text("'").tag("'") }
            if importing {
                Picker("Encoding", selection: $settings.encoding) { ForEach(["UTF-8", "UTF-16", "Latin-1"], id: \.self) { Text($0) } }
            } else {
                Picker("Line ending", selection: $settings.lineEnding) { Text("LF").tag("LF"); Text("CRLF").tag("CRLF") }
            }
        }
        HStack {
            Toggle("Header row", isOn: $settings.header)
            TextField("NULL token", text: $settings.nullToken).frame(width: 115)
        }
    }
}
