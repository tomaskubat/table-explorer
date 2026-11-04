import SwiftUI
import SQLite3

struct MaintenanceView: View {
    let workspace: Workspace
    let action: MaintenanceAction
    @State private var path = ""
    @State private var selectedTool = ""
    @State private var tool: NativeDatabaseTool?
    @State private var gzip = false
    @State private var schemaOnly = false
    @State private var routines = false
    @State private var events = false
    @State private var review: MaintenanceRequest?
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error: String?
    @State private var result: String?
    @State private var job: MaintenanceJob?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(action == .backup ? "Back Up Database" : "Restore Database").font(.headline).frame(maxWidth: .infinity)
            LabeledContent("Connection", value: workspace.profile.name)
            LabeledContent("Database", value: workspace.database)
            if let review {
                Text((action == .backup ? "Destination: " : "Source: ") + review.file.path).textSelection(.enabled)
                Text(tool?.version ?? "SQLite \(String(cString: sqlite3_libversion())) · Online Backup API").font(.caption)
                if workspace.profile.driver == .mariaDB {
                    Text(review.arguments.joined(separator: " ")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if review.overwrite { Text("The existing backup file will be replaced after the new backup succeeds.") }
                if action == .restore {
                    Text(workspace.profile.driver == .mariaDB
                         ? "The selected database is the default for this script. USE statements and qualified names can target other databases available to this account. Earlier statements may remain committed if a later statement fails."
                         : "The SQLite snapshot replaces the contents of the open database.")
                    TextField("Type the database name to restore", text: $confirmation).accessibilityIdentifier("Restore Target")
                }
            } else {
                HStack {
                    TextField(action == .backup ? "Backup File" : "Source File", text: $path).accessibilityIdentifier("Maintenance File")
                    Button("Choose…") { chooseFile() }
                }
                if workspace.profile.driver == .mariaDB {
                    HStack {
                        TextField("Native tool path (automatic if empty)", text: $selectedTool)
                        Button("Choose Tool…") {
                            let panel = NSOpenPanel()
                            if panel.runModal() == .OK, let url = panel.url { selectedTool = url.path }
                        }
                    }
                    if action == .backup {
                        HStack { Toggle("Schema only", isOn: $schemaOnly); Toggle("Routines", isOn: $routines); Toggle("Events", isOn: $events) }
                    }
                }
                if action == .backup { Toggle("Compress with gzip", isOn: $gzip) }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("maintenanceError") }
            if let result { Text(result).foregroundStyle(.green).accessibilityIdentifier("maintenanceResult") }
            Spacer()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(busy ? "Stop" : "Close") { if busy { job?.cancel() } else { dismiss() } }
                if result == nil {
                    if review == nil {
                        Button(action == .backup ? "Review Backup" : "Review Restore") { Task { await prepare() } }
                            .disabled(busy || !path.hasPrefix("/") || workspace.database.isEmpty)
                    } else {
                        Button("Back") { review = nil; error = nil }.disabled(busy)
                        Button(action == .backup ? "Start Backup" : "Restore Database") { Task { await run() } }
                            .disabled(busy || (action == .restore && confirmation != workspace.database))
                    }
                }
            }
        }.padding(20).frame(width: 660, height: action == .backup ? 500 : 420).background(BrowserChrome.paper).interactiveDismissDisabled(busy)
        .onAppear { selectedTool = BrowserPreferences.defaults.string(forKey: action == .backup ? "dumpTool" : "restoreTool") ?? "" }
    }

    private func chooseFile() {
        if action == .restore {
            let panel = NSOpenPanel()
            if panel.runModal() == .OK, let url = panel.url { path = url.path }
        } else {
            let panel = NSSavePanel()
            let ext = workspace.profile.driver == .sqlite ? "sqlite" : "sql"
            panel.nameFieldStringValue = workspace.database + "-backup." + ext + (gzip ? ".gz" : "")
            if panel.runModal() == .OK, let url = panel.url { path = url.path }
        }
    }
    private func prepare() async {
        error = nil
        guard !workspace.hasRunningTasks, action == .backup || !workspace.hasDrafts else {
            error = "Finish running operations and resolve pending row changes before restoring."
            return
        }
        busy = true; defer { busy = false }
        do {
            if workspace.profile.driver == .mariaDB {
                let chosen = selectedTool, operation = action
                tool = try await Task.detached { try NativeDatabaseTool.discover(operation, chosen: chosen) }.value
            }
            let file = URL(filePath: path)
            try await workspace.session.checkExportDestination(file)
            if action == .restore, !FileManager.default.isReadableFile(atPath: file.path) { throw BrowserError("Choose a readable source file.") }
            review = MaintenanceRequest(action: action, file: file, database: workspace.database, tool: tool,
                                        gzip: gzip, schemaOnly: schemaOnly, routines: routines, events: events,
                                        overwrite: action == .backup && FileManager.default.fileExists(atPath: file.path))
        } catch { self.error = error.localizedDescription }
    }
    private func run() async {
        guard let review, !busy else { return }
        let job = MaintenanceJob(); self.job = job
        error = nil; busy = true; workspace.maintenanceBusy = true
        defer { busy = false; workspace.maintenanceBusy = false; self.job = nil }
        do {
            result = try await workspace.session.maintain(review, job: job)
            if let result { workspace.log.append(result) }
            if action == .restore {
                workspace.clearDatabaseResults()
                await workspace.reloadObjects()
            }
        } catch { self.error = error.localizedDescription }
    }
}
