import SwiftUI

enum VariableFormat: String, CaseIterable {
    case colon = ":name", percent = "%name%", positional = "?", braces = "${name}", dollar = "$name", doubleBraces = "{{name}}"

    var pattern: String {
        let name = #"([\w.]+)"#
        switch self {
        case .colon: return #"(?<!:):"# + name
        case .percent: return "%" + name + "%"
        case .positional: return #"\?"#
        case .braces: return #"\$\{"# + name + #"\}"#
        case .dollar: return #"\$"# + name
        case .doubleBraces: return #"\{\{"# + name + #"\}\}"#
        }
    }
}

struct QueryVariables: Identifiable {
    let id = UUID()
    let templates: [String]
    let names: [String]
    private let occurrences: [[(name: String, range: NSRange)]]

    init(_ statements: [String], format: VariableFormat, driver: DatabaseDriver, insideStrings: Bool) {
        var names: [String] = [], seen = Set<String>(), position = 0
        // Match whole quoted tokens and comments before placeholders. Ranges
        // use UTF-16 offsets so edits can be applied to NSString back to front.
        let quoted = driver == .mariaDB
            ? #"'(?:''|\\[\s\S]|[^'\\])*'|"(?:""|\\[\s\S]|[^"\\])*"|`(?:``|[^`])*`"#
            : #"'(?:''|[^'])*'|"(?:""|[^"])*"|`(?:``|[^`])*`|\[[^\]]*\]"#
        let comments = driver == .mariaDB ? #"/\*[\s\S]*?(?:\*/|$)|--(?=\s|$)[^\r\n]*|#[^\r\n]*"# : #"/\*[\s\S]*?(?:\*/|$)|--[^\r\n]*"#
        let protected = try! NSRegularExpression(pattern: comments + "|" + quoted)
        let variable = try! NSRegularExpression(pattern: format.pattern)
        occurrences = statements.map { statement in
            let source = statement as NSString
            let all = NSRange(location: 0, length: source.length)
            let excluded = protected.matches(in: statement, range: all).map(\.range).filter { token in
                let first = source.character(at: token.location)
                return !insideStrings || (first != 39 && first != 34)
            }
            var segment = 0
            return variable.matches(in: statement, range: all).compactMap { match in
                while segment < excluded.count && NSMaxRange(excluded[segment]) <= match.range.location { segment += 1 }
                if segment < excluded.count && NSIntersectionRange(excluded[segment], match.range).length > 0 { return nil }
                let key: String
                if format == .positional { position += 1; key = "? " + String(position) }
                else { key = source.substring(with: match.range) }
                if seen.insert(key).inserted { names.append(key) }
                return (key, match.range)
            }
        }
        templates = statements; self.names = names
    }
    func expanded(using values: [String: String]) -> [String] {
        zip(templates, occurrences).map { template, tokens in
            let sql = NSMutableString(string: template)
            for token in tokens.reversed() { sql.replaceCharacters(in: token.range, with: values[token.name] ?? "") }
            return sql as String
        }
    }
}

struct VariablesView: View {
    let query: QueryVariables
    let workspace: Workspace
    let tab: WorkspaceTab
    @State private var values: [String: String]
    @State private var reviewing = false
    @Environment(\.dismiss) private var dismiss

    init(query: QueryVariables, workspace: Workspace, tab: WorkspaceTab) {
        self.query = query; self.workspace = workspace; self.tab = tab
        _values = State(initialValue: tab.variableValues)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reviewing ? "Review Parameterized SQL" : "Query Variables").font(.title2)
            Text(workspace.profile.name + " / " + workspace.database + " · " + workspace.profile.environment.uppercased())
            if reviewing {
                ScrollView {
                    Text(query.expanded(using: values).joined(separator: "\n")).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).accessibilityIdentifier("Expanded SQL")
                }
            } else {
                Text("Enter SQL expressions. Put quotes around text, or enter NULL.")
                ScrollView {
                    Grid(alignment: .leading) {
                        ForEach(query.names, id: \.self) { name in
                            GridRow {
                                Text(name).monospaced()
                                TextField("SQL expression", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                                    .accessibilityIdentifier("variable-" + name)
                            }
                        }
                    }
                }
            }
            Spacer()
            HStack {
                Button("Clear Values") { values = [:]; tab.variableValues = [:]; reviewing = false }
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if reviewing {
                    Button("Back") { reviewing = false }
                    Button("Run Statements") {
                        tab.variableValues = values
                        let sql = query.expanded(using: values)
                        dismiss()
                        Task { await workspace.run(sql, on: tab, templates: query.templates) }
                    }.disabled(!workspace.connected || tab.busy)
                } else {
                    Button("Review SQL") { reviewing = true }.keyboardShortcut(.return, modifiers: .command)
                        .disabled(query.names.contains { (values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }
        }.padding(18).frame(width: 540, height: 330)
    }
}
