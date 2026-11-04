import SwiftUI

struct WorkspaceTitleBar: View {
    @Bindable var workspace: Workspace
    let closeTab: () -> Void
    @Environment(\.openWindow) private var openWindow

    private var statusColor: Color {
        let p = workspace.profile
        return p.tagColor != nil ? p.badgeColor : p.driver == .sqlite ? BrowserChrome.paper : p.environmentColor
    }

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 76)
            tool("Saved Connections", "powerplug") { openWindow(id: "connections") }
            tool("Close Tab", "xmark.circle", action: closeTab).disabled(workspace.active == nil || workspace.active?.busy == true)
            Divider().frame(height: 15)
            tool("Preview Changes", "eye") { workspace.active?.previewShown = true }
                .disabled(workspace.active?.changes.isEmpty != false)
                .accessibilityLabel("Review Staged Changes")
            if workspace.profile.driver == .mariaDB {
                tool("Database", "cylinder") { workspace.databaseSelectorShown = true }.disabled(!workspace.connected)
            }
            Button("SQL") { workspace.newQuery() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                .frame(width: 26).accessibilityLabel("New Query").help("New SQL query (⌘T)")
            HStack(spacing: 6) {
                Text([workspace.profile.driver.rawValue, workspace.profile.name, workspace.database, workspace.active?.title]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " : "))
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                EnvironmentBadge(profile: workspace.profile)
            }
            .padding(.horizontal, 5).frame(height: 22)
            .background(statusColor.opacity(workspace.profile.driver == .sqlite && workspace.profile.tagColor == nil ? 0.9 : 0.18), in: RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(BrowserChrome.line, lineWidth: 0.7) }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.window?.zoom(nil) })
            .gesture(WindowDragGesture())
            tool("Open Anything", "magnifyingglass") { workspace.objectSearchShown = true }.disabled(!workspace.connected)
            tool("Workspaces", "square.grid.2x2") { openWindow(id: "workspaces") }
            toggle("Item List", "sidebar.left", $workspace.showItems)
            toggle("SQL Console", "rectangle.bottomthird.inset.filled", $workspace.showConsole)
            toggle("Row Detail", "sidebar.right", $workspace.showDetails)
        }
        .padding(.trailing, 8).frame(height: 38)
        .background { BrowserChrome.bar.gesture(WindowDragGesture()) }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tool(_ name: String, _ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 25, height: 22)
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .background(active ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(name).help(name)
    }
    private func toggle(_ name: String, _ symbol: String, _ binding: Binding<Bool>) -> some View {
        tool(name, symbol, active: binding.wrappedValue) { binding.wrappedValue.toggle() }
            .accessibilityValue(binding.wrappedValue ? "Shown" : "Hidden")
    }
}

struct WorkspaceConsole: View {
    let workspace: Workspace
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    @AppStorage("highlightConsole", store: BrowserPreferences.defaults) private var highlight = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(workspace.log.entries) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("-- " + Self.timestamp.string(from: entry.date))
                                .foregroundStyle(highlight ? Color(nsColor: .systemGreen) : .secondary)
                            Text(highlight ? SQLSyntax.colored(entry.text) : AttributedString(entry.text))
                        }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if workspace.log.isEmpty {
                    Text("Open a table or run a query to see its SQL.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("SQL Console").accessibilityIdentifier("SQL Console")
            Divider()
            HStack(spacing: 12) {
                Button("Clear Console", systemImage: "trash") { workspace.log.removeAll() }
                    .buttonStyle(.plain).labelStyle(.iconOnly).disabled(workspace.log.isEmpty).help("Clear console")
                Toggle("Enable syntax highlighting", isOn: $highlight).controlSize(.small)
                Spacer()
            }.font(.caption).padding(.horizontal, 9).frame(height: 27)
        }.background(BrowserChrome.paper)
    }
}

struct RecordInspector: View {
    let workspace: Workspace
    @Binding var search: String
    var body: some View {
        VStack(spacing: 0) {
            ChromeSearchField(title: "Search for field", text: $search)
                .padding(.horizontal, 9).padding(.vertical, 8)
            if let tab = workspace.active, !tab.showStructure, let index = tab.selected, tab.displayed.rows.indices.contains(index) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        let fields = Array(zip(tab.result.columns, tab.displayed.rows[index]).enumerated())
                        ForEach(fields.filter { search.isEmpty || $0.element.0.localizedCaseInsensitiveContains(search) }, id: \.offset) { i, field in
                            let (name, value) = field
                            let column = tab.schema?.columns.first { $0.name == name }
                            let multiple = tab.selectedRows.count > 1
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(column?.type.lowercased() ?? "").lineLimit(1).foregroundStyle(.secondary)
                                }.font(.system(size: 10))
                                HStack(spacing: 0) {
                                    Text(multiple ? "Multiple values" : value.display.isEmpty ? "EMPTY" : value.display)
                                        .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                        .foregroundStyle(multiple || value == .null || value.display.isEmpty ? .secondary : .primary)
                                        .textSelection(.enabled).accessibilityIdentifier("detail-value-\(i)")
                                    Spacer(minLength: 3)
                                    if let column {
                                        Button("Edit " + name, systemImage: "chevron.down") {
                                            if !tab.hiddenColumns.contains(name) { tab.focusedColumn = name }
                                            tab.cellEditor = CellEdit(column: name, value: value, draft: tab.editRow(at: index),
                                                writable: workspace.connected && tab.canEdit(index) && !column.generated, nullable: column.nullable)
                                        }.labelStyle(.iconOnly).font(.system(size: 9, weight: .semibold)).buttonStyle(.plain)
                                            .disabled(multiple).accessibilityIdentifier("detail-edit-" + name)
                                    }
                                }.padding(.horizontal, 6).frame(height: 23)
                                .background(BrowserChrome.paper, in: RoundedRectangle(cornerRadius: 3))
                            }.accessibilityElement(children: .contain)
                        }
                    }.padding(.horizontal, 9).padding(.bottom, 8)
                }
            } else {
                Text("No row selected").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxHeight: .infinity).background(BrowserChrome.panel)
    }
}

struct SessionRail: View {
    let current: Workspace
    let registry: WorkspaceRegistry
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(registry.sessions.values.sorted { ($0.profile.name, $0.id.uuidString) < ($1.profile.name, $1.id.uuidString) }) { session in
                        Button { openWindow(value: session.id) } label: {
                            VStack(spacing: 7) {
                                Image(systemName: "cylinder").font(.system(size: 17))
                                    .foregroundStyle(session.connected ? session.profile.badgeColor : .secondary)
                                Text(session.database.isEmpty ? session.profile.name : session.database)
                                    .font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).frame(height: 75)
                                .background(current.id == session.id ? BrowserChrome.panel : BrowserChrome.paper)
                        }.buttonStyle(.plain).help(session.profile.name)
                    }
                }
            }
            Button("Show Workspaces", systemImage: "square.grid.2x2") { openWindow(id: "workspaces") }
                .buttonStyle(.plain).labelStyle(.iconOnly).help("Show workspaces").frame(height: 28)
        }.frame(width: 78).background(BrowserChrome.paper)
    }
}
