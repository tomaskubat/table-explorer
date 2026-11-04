import SwiftUI

struct QueryPane: View {
    let workspace: Workspace
    @Bindable var tab: WorkspaceTab
    @State private var review: [String] = []
    @State private var favoriteSheet = false
    @State private var variables: QueryVariables?
    @AppStorage("enableQueryVariables", store: BrowserPreferences.defaults) private var enableVariables = false
    @AppStorage("variableFormat", store: BrowserPreferences.defaults) private var variableFormat = VariableFormat.colon
    @AppStorage("variablesInsideStrings", store: BrowserPreferences.defaults) private var insideStrings = false
    @State private var favoriteName = ""
    @State private var keywords = ""
    @AppStorage("queryFontSize", store: BrowserPreferences.defaults) private var fontSize = 13.0

    @AppStorage("highlightSQL", store: BrowserPreferences.defaults) private var highlight = true
    @AppStorage("indentSpaces", store: BrowserPreferences.defaults) private var indent = 4
    @AppStorage("querySafety", store: BrowserPreferences.defaults) private var safety = "Review writes"

    var body: some View {
        SQLTextEditor(text: $tab.sql, selection: $tab.textSelection, fontSize: fontSize, highlighting: highlight, indent: indent, driver: workspace.profile.driver, objectNames: workspace.objects.map(\.name)) { focused in
            if focused { workspace.focusArea = .sql } else if workspace.focusArea == .sql { workspace.focusArea = nil }
        }
            .frame(minHeight: 66, maxHeight: .infinity)
            .onChange(of: tab.sql) { workspace.updateRecovery(tab) }
            .onChange(of: tab.runRequest) { if !tab.busy && workspace.connected { run(.current) } }
            .onDisappear { workspace.saveRecovery(tab) }
        HStack(spacing: 5) {
            Text(position).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Save Favorite", systemImage: "star") { favoriteSheet = true }.labelStyle(.iconOnly).help("Save favorite")
            Button("Run Current") { run(.current) }.help("Run the statement at the cursor (⌘Return)")
            Menu("Run Options") {
                Button("Run Selection") { run(.selection) }.disabled(tab.textSelection.length == 0)
                Button("Run Script") { run(.script) }
                Divider()
                Toggle("Enable Query Parameters", isOn: $enableVariables)
                Picker("Parameter Format", selection: $variableFormat) {
                    ForEach(VariableFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Find Parameters Inside Quoted Strings", isOn: $insideStrings)
            }
        }.padding(.horizontal, 6).frame(height: 28).background(BrowserChrome.panel).disabled(tab.busy || !workspace.connected || tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if tab.cancellation != nil {
            HStack {
                Button("Stop Query") { Task { await workspace.stop(tab) } }.disabled(tab.stopRequested)
                if tab.stopRequested { Text("Stop requested. Waiting for the database…").font(.caption) }
            }
        }
        if tab.executions.count > 1 {
            Picker("Statement Result", selection: Binding(get: { tab.executionIndex }, set: { tab.selectExecution($0) })) {
                ForEach(Array(tab.executions.map(\.title).enumerated()), id: \.offset) { index, title in
                    Text(title).tag(index)
                }
            }.accessibilityIdentifier("Statement Result")
        }
        if let elapsed = tab.lastDuration {
            let affected = tab.result.affectedRows
            let count = affected == 1 ? "1 affected row" : "\(affected) affected rows"
            Text(String(format: "%.3f s", elapsed) + (tab.result.columns.isEmpty && tab.error == nil ? " · " + count : ""))
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
            .sheet(item: $variables) { VariablesView(query: $0, workspace: workspace, tab: tab) }
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
        if enableVariables {
            let query = QueryVariables(commands, format: variableFormat, driver: workspace.profile.driver, insideStrings: insideStrings)
            if !query.names.isEmpty { variables = query; return }
        }
        if workspace.profile.production || safety == "Review every statement" || (safety != "Run immediately" && commands.contains(where: SQLDocument.requiresConfirmation)) { review = commands }
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
