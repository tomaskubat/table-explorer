import SwiftUI

struct QueryPane: View {
    let workspace: Workspace
    @Bindable var tab: WorkspaceTab
    @State private var review: [String] = []
    @State private var favoriteSheet = false
    @State private var favoriteName = ""
    @State private var keywords = ""
    @AppStorage("queryFontSize", store: BrowserPreferences.defaults) private var fontSize = 13.0

    @AppStorage("highlightSQL", store: BrowserPreferences.defaults) private var highlight = true
    @AppStorage("indentSpaces", store: BrowserPreferences.defaults) private var indent = 4
    @AppStorage("querySafety", store: BrowserPreferences.defaults) private var safety = "Review writes"

    var body: some View {
        HStack {
            Text(workspace.profile.environment.uppercased())
                .foregroundStyle(workspace.profile.environment.lowercased().hasPrefix("pro") ? Color.red : .secondary)
            Text(workspace.profile.name + " / " + workspace.database)
            Spacer()
            Text(position).monospacedDigit()
        }.font(.caption)
        SQLTextEditor(text: $tab.sql, selection: $tab.textSelection, fontSize: fontSize, highlighting: highlight, indent: indent, driver: workspace.profile.driver, objectNames: workspace.objects.map(\.name)) { focused in
            if focused { workspace.focusArea = .sql } else if workspace.focusArea == .sql { workspace.focusArea = nil }
        }
            .frame(minHeight: 78, idealHeight: 130, maxHeight: 200)
        HStack {
            Button("Run Current") { run(.current) }.keyboardShortcut(.return, modifiers: .command)
            Menu("Run Options") {
                Button("Run Selection") { run(.selection) }.disabled(tab.textSelection.length == 0)
                Button("Run Script") { run(.script) }
            }
            Button("Save Favorite") { favoriteSheet = true }
        }.disabled(tab.busy || !workspace.connected || tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if tab.cancellation != nil {
            HStack {
                Button("Stop Query") { Task { await workspace.stop(tab) } }.disabled(tab.stopRequested)
                if tab.stopRequested { Text("Stop requested. Waiting for the database…").font(.caption) }
            }
        }
        if tab.executions.count > 1 {
            Picker("Statement Result", selection: Binding(get: { tab.executionIndex }, set: { tab.selectExecution($0) })) {
                ForEach(tab.executions.indices, id: \.self) { i in Text("Statement \(i + 1)").tag(i) }
            }
        }
        if let elapsed = tab.lastDuration {
            Text(String(format: "%.3f s", elapsed) + (tab.result.columns.isEmpty && tab.error == nil ? " · \(tab.result.affectedRows) affected rows" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        Color.clear.frame(height: 0)
            .sheet(isPresented: Binding(get: { !review.isEmpty }, set: { if !$0 { review = [] } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Run SQL on \(workspace.profile.name)?").font(.title2)
                    Text("These statements run directly on \(workspace.database.isEmpty ? "the server" : workspace.database). They may change data immediately.")
                    ScrollView { Text(review.joined(separator: ";\n")).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    HStack {
                        Spacer()
                        Button("Cancel") { review = [] }.keyboardShortcut(.cancelAction)
                        Button("Run Statements") { let commands = review; review = []; Task { await workspace.run(commands, on: tab) } }
                    }
                }.padding(20).frame(width: 500, height: 300)
            }
            .sheet(isPresented: $favoriteSheet) {
                VStack(alignment: .leading) {
                    Text("Save Favorite").font(.title2)
                    TextField("Query Name", text: $favoriteName)
                    TextField("Keywords", text: $keywords)
                    HStack {
                        Spacer(); Button("Cancel") { favoriteSheet = false }
                        Button("Save") {
                            workspace.notebook.add(FavoriteQuery(name: favoriteName, sql: tab.sql, keywords: keywords))
                            favoriteSheet = false
                        }.disabled(favoriteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(18).frame(width: 340)
            }
    }

    private var position: String {
        let source = tab.sql as NSString
        let prefix = source.substring(to: min(tab.textSelection.location, source.length))
        let lines = prefix.components(separatedBy: "\n")
        return "Ln \(lines.count), Col \((lines.last?.count ?? 0) + 1)"
    }
    private func run(_ scope: SQLScope) {
        let commands = SQLDocument.commands(text: tab.sql, selection: tab.textSelection, scope: scope, driver: workspace.profile.driver)
        guard !commands.isEmpty else { return }
        if workspace.profile.environment.lowercased().hasPrefix("pro") || safety == "Review every statement" || (safety != "Run immediately" && commands.contains(where: SQLDocument.requiresConfirmation)) { review = commands }
        else { Task { await workspace.run(commands, on: tab) } }
    }
}

struct QueryNavigator: View {
    let workspace: Workspace
    let history: Bool
    let search: String

    var body: some View {
        if history {
            List(workspace.notebook.history.filter { search.isEmpty || $0.sql.localizedCaseInsensitiveContains(search) }) { entry in
                Button { workspace.newQuery(text: entry.sql) } label: {
                    VStack(alignment: .leading) {
                        Text(entry.sql).lineLimit(2)
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("history-" + entry.sql)
            }
        } else {
            List(workspace.notebook.favorites.filter { search.isEmpty || ($0.name + " " + $0.keywords).localizedCaseInsensitiveContains(search) }) { favorite in
                Button(favorite.name) { workspace.newQuery(text: favorite.sql) }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Remove Favorite") { workspace.notebook.removeFavorite(favorite.id) } }
            }
        }
        if let error = workspace.notebook.error { Text(error).foregroundStyle(.red) }
    }
}
