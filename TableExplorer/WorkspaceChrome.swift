import SwiftUI

struct WorkspaceTitleBar: View {
    @Bindable var workspace: Workspace
    let closeTab: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    private var statusColor: Color { workspace.profile.badgeColor }
    private var hasChanges: Bool { workspace.active?.changes.isEmpty == false }
    private var statusOpacity: Double {
        guard let color = workspace.profile.tagColor, !color.hasPrefix("#") else { return colorScheme == .dark ? 0.25 : 1 }
        return 0.18 // Preserve the softer appearance of legacy system colors.
    }

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 76)
            tool("Saved Connections", "powerplug") { openWindow(id: "connections") }
            tool("Close Tab", "xmark.circle", action: closeTab).disabled(workspace.active == nil || workspace.active?.busy == true)
            Divider().frame(height: 15)
            tool("Preview Changes", "eye", active: hasChanges) { workspace.active?.previewShown = true }
                .disabled(!hasChanges || workspace.active?.busy != false)
                .accessibilityLabel("Review Staged Changes")
                .accessibilityValue(hasChanges ? "Pending changes" : "No pending changes")
            tool("Discard Changes", "arrow.uturn.backward", active: hasChanges) { workspace.active?.discard() }
                .disabled(!hasChanges || workspace.active?.busy != false)
                .accessibilityLabel("Discard Staged Changes")
                .accessibilityValue(hasChanges ? "Pending changes" : "No pending changes")
            if workspace.profile.driver == .mariaDB {
                tool("Database", "cylinder") { workspace.databaseSelectorShown = true }.disabled(!workspace.connected)
            }
            Button("SQL") { workspace.newQuery() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                .frame(width: 26).accessibilityLabel("New Query").help("New SQL query")
            HStack(spacing: 6) {
                Text([workspace.profile.driver.rawValue, workspace.profile.name, workspace.database, workspace.active?.title]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " : "))
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                EnvironmentBadge(profile: workspace.profile)
            }
            .padding(.horizontal, 5).frame(height: 22)
            .background(statusColor.opacity(statusOpacity), in: RoundedRectangle(cornerRadius: 3))
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
    @State private var followsLatest = true
    @State private var scrollPhase = ScrollPhase.idle
    private var userIsScrolling: Bool { scrollPhase == .tracking || scrollPhase == .interacting || scrollPhase == .decelerating }
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
                                .fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(followsLatest ? .bottom : nil, for: .sizeChanges)
            .onScrollPhaseChange { _, phase, context in
                let wasUserScrolling = userIsScrolling
                scrollPhase = phase
                if wasUserScrolling || userIsScrolling {
                    followsLatest = isAtEnd(context.geometry)
                }
            }
            .onScrollGeometryChange(for: Bool.self, of: isAtEnd) { _, atEnd in
                if userIsScrolling { followsLatest = atEnd }
            }
            .onChange(of: workspace.log.isEmpty) { if workspace.log.isEmpty { followsLatest = true } }
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

    private func isAtEnd(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height - 4
    }
}

struct RecordInspector: View {
    let workspace: Workspace
    @Binding var search: String
    @State private var expandedField: Int?

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
                                HStack(spacing: 4) {
                                    if expandedField == i {
                                        Button("Collapse " + name, systemImage: "chevron.up") { expandedField = nil }
                                            .labelStyle(.iconOnly).buttonStyle(.plain).help("Collapse value")
                                    }
                                    Text(name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(column?.type.lowercased() ?? "").lineLimit(1).foregroundStyle(.secondary)
                                }.font(.system(size: 10))
                                HStack(alignment: .top, spacing: 5) {
                                    fieldValue(value, index: i, multiple: multiple)
                                    if !multiple {
                                        HStack(spacing: 4) {
                                            fieldAction("Copy " + name, systemImage: "doc.on.doc") {
                                                GridClipboard.copy(value.display)
                                            }.help("Copy value").accessibilityIdentifier("detail-copy-" + name)
                                            fieldAction("Open " + name, systemImage: "arrow.up.right.square") {
                                                if !tab.hiddenColumns.contains(name) { tab.focusedColumn = name }
                                                tab.cellEditor = CellEdit(column: name, value: value, draft: column == nil ? nil : tab.editRow(at: index),
                                                    writable: workspace.connected && tab.canEdit(index) && column?.generated == false,
                                                    nullable: column?.nullable == true)
                                            }.help("Open value editor").accessibilityIdentifier("detail-edit-" + name)
                                        }
                                    }
                                }.padding(.horizontal, 6).padding(.vertical, 4)
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
        .onChange(of: workspace.activeID) { expandedField = nil }
        .onChange(of: workspace.active?.selectedRows) { expandedField = nil }
    }

    private func fieldAction(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).resizable().scaledToFit().frame(width: 12, height: 12)
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    @ViewBuilder private func fieldValue(_ value: SQLValue, index: Int, multiple: Bool) -> some View {
        let display = value.display
        let text = Text(multiple ? "Multiple values" : display.isEmpty ? "EMPTY" : display)
            .font(.system(size: 13))
            .foregroundStyle(multiple || value == .null || display.isEmpty ? .secondary : .primary)
        if expandedField == index && !multiple {
            let maxTextHeight: CGFloat = 242 // Keep the padded value within 250 pt.
            let content = text.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("detail-value-\(index)")
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }.frame(height: maxTextHeight)
            }.frame(maxHeight: maxTextHeight, alignment: .top)
        } else {
            text.lineLimit(1).truncationMode(.middle).accessibilityIdentifier("detail-value-\(index)")
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .onTapGesture { if !multiple { expandedField = index } }
                .accessibilityAction(named: "Expand value") { if !multiple { expandedField = index } }
        }
    }
}

struct SessionRail: View {
    let current: Workspace
    let registry: WorkspaceRegistry
    @Environment(\.openWindow) private var openWindow
    @Environment(ConnectionLibrary.self) private var library: ConnectionLibrary?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(registry.orderedSessions) { session in
                        let profile = savedProfile(for: session)
                        Button { registry.activate(session.id) } label: {
                            VStack(spacing: 7) {
                                connectionIcon(profile: profile, connected: session.connected)
                                Text(session.database.isEmpty ? session.profile.name : session.database)
                                    .font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).frame(height: 75)
                                .background(current.id == session.id ? BrowserChrome.panel : BrowserChrome.paper)
                        }.buttonStyle(.plain).help(session.profile.name)
                            .accessibilityLabel("Connection " + session.profile.name)
                            .contextMenu {
                                Button("Close Connection") { registry.requestClose(session) }
                            }
                    }
                }
            }
            Button("Show Workspaces", systemImage: "square.grid.2x2") { openWindow(id: "workspaces") }
                .buttonStyle(.plain).labelStyle(.iconOnly).help("Show workspaces").frame(height: 28)
        }.frame(width: 78).background(BrowserChrome.paper)
    }

    private func savedProfile(for session: Workspace) -> ConnectionProfile {
        guard let library, library.directory.standardizedFileURL == session.notebook.libraryDirectory.standardizedFileURL else { return session.profile }
        return library.groups.lazy.flatMap(\.connections).first { $0.id == session.profile.id } ?? session.profile
    }

    private func connectionIcon(profile: ConnectionProfile, connected: Bool) -> some View {
        let color = profile.tagColor.map { _ in profile.badgeColor }
        let rgb = color.flatMap { NSColor($0).usingColorSpace(.sRGB) }
        let brightness = rgb.map { $0.redComponent * 0.299 + $0.greenComponent * 0.587 + $0.blueComponent * 0.114 }
        let ink: Color = brightness.map { $0 > 0.54 ? .black : .white } ?? .primary
        return Image(systemName: "cylinder").font(.system(size: 17)).foregroundStyle(ink)
            .opacity(connected ? 1 : 0.48).frame(width: 32, height: 28)
            .background(color ?? .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}
