import SwiftUI
import UniformTypeIdentifiers

private enum LibraryEditor: Identifiable {
    case group(ConnectionGroup), profile(ConnectionProfile, UUID, error: String? = nil), choose(UUID)
    var id: UUID {
        switch self {
        case .choose(let id): id
        case .group(let group): group.id
        case .profile(let profile, _, _): profile.id
        }
    }
}

struct SavedConnectionsView: View {
    let library: ConnectionLibrary
    let workspaces: WorkspaceRegistry
    @Environment(\.openWindow) private var openWindow
    @State private var selection: UUID?
    @State private var editor: LibraryEditor?
    @State private var removal: UUID?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer()
                LibraryMark().frame(width: 96, height: 76)
                Text("TableExplorer").font(.system(size: 23, weight: .light)).padding(.top, 12)
                Text("Build " + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))
                    .font(.system(size: 13, weight: .light)).foregroundStyle(.secondary).padding(.top, 11)
                let count = library.groups.reduce(0) { $0 + $1.connections.count }
                Text(count == 1 ? "1 saved connection" : "\(count) saved connections").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary).padding(.top, 17)
                HStack(spacing: 5) {
                    libraryAction("Export", transfer: .export) { export(library.groups) }
                    libraryAction("Import", transfer: .importProfiles) { importProfiles() }
                    libraryAction("New Group", transfer: nil) { editor = .group(ConnectionGroup(name: "")) }
                }.padding(.top, 27)
                Spacer()
            }
            .frame(width: 250).frame(maxHeight: .infinity)
            .background { BrowserChrome.panel.gesture(WindowDragGesture()) }
            VStack(spacing: 0) {
                if let issue = library.loadError { Text(issue).foregroundStyle(.red).padding(8) }
                List(selection: $selection) {
                    ForEach(library.groups) { group in
                        ConnectionGroupSection(group: group) { profile in
                            modify { try library.move(profile, to: group.id) }
                        }
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    libraryMenu(ids.first)
                } primaryAction: { ids in
                    if let id = ids.first, let (profile, group) = findProfile(id) {
                        Task { await connectSaved(profile, group: group) }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 37)
                HStack {
                    Button("Create a new connection…") { newProfile(in: selectedGroup) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(library.groups.isEmpty).accessibilityLabel("New Connection")
                    Spacer()
                    Menu("Library", systemImage: "ellipsis.circle") {
                        Button("New Group…") { editor = .group(ConnectionGroup(name: "")) }
                        Button("Import Connections…") { importProfiles() }
                        Button("Export All Connections…") { export(library.groups) }
                    }.menuStyle(.borderlessButton).labelStyle(.iconOnly).fixedSize().help("Library actions")
                }.padding(.horizontal, 11).frame(height: 28)
            }.padding(.top, 19).background(BrowserChrome.paper)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 620, minHeight: 380)
        .sheet(item: $editor) { editor in
            switch editor {
            case .choose(let group):
                DriverChooser(library: library, groupID: group) { profile, session, database, password, sshPassword in
                    showWorkspace(profile, session: session, database: database, password: password, sshPassword: sshPassword)
                }
            case .group(let group): GroupEditor(library: library, group: group)
            case .profile(let profile, let group, let failure):
                ProfileEditor(library: library, profile: profile, groupID: group, initialError: failure) { connection, session, database, password, sshPassword in
                    showWorkspace(connection, session: session, database: database, password: password, sshPassword: sshPassword)
                }
            }
        }
        .alert("Connection Library", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("Remove from the library?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { id in
            Button("Remove", role: .destructive) { remove(id) }
            Button("Cancel", role: .cancel) {}
        } message: { id in
            if let group = library.groups.first(where: { $0.id == id }) {
                Text("Remove \(group.name) and its \(group.connections.count) saved profiles? Database files and servers are kept.")
            } else { Text("Remove this saved profile? Its database is kept.") }
        }
    }

    private enum Transfer { case importProfiles, export }

    private func libraryAction(_ title: String, transfer: Transfer?, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 8) {
                if let transfer { LibraryTransferIcon(importing: transfer == .importProfiles) }
                else {
                    Image(systemName: "folder.fill.badge.plus").font(.system(size: 32)).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.purple).frame(width: 43, height: 37)
                }
                Text(title).font(.system(size: 12)).fixedSize()
            }.frame(width: 70, height: 66).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title == "New Group" ? title : title + " Connections").help(title == "New Group" ? "Create a connection group" : title + " connection profiles")
    }

    private func findProfile(_ id: UUID) -> (ConnectionProfile, UUID)? {
        for group in library.groups {
            if let profile = group.connections.first(where: { $0.id == id }) { return (profile, group.id) }
        }
        return nil
    }
    private var selectedGroup: UUID? {
        selection.flatMap { id in library.groups.first(where: { $0.id == id })?.id ?? findProfile(id)?.1 } ?? library.groups.first?.id
    }
    private func newProfile(in group: UUID?) {
        if let group { editor = .choose(group) }
    }
    @ViewBuilder private func libraryMenu(_ id: UUID?) -> some View {
        let found = id.flatMap { findProfile($0) }
        let group = library.groups.first { $0.id == id }
        Button("Connect") { if let (p, g) = found { Task { await connectSaved(p, group: g) } } }.disabled(found == nil)
        Button("New Connection…") { newProfile(in: group?.id ?? found?.1 ?? selectedGroup) }
        Button("New Group…") { editor = .group(ConnectionGroup(name: "")) }
        if let group {
            Button("Rename Group…") { editor = .group(group) }
        }
        if let (p, g) = found {
            Button("Edit Connection…") { editor = .profile(p, g) }
            Menu("Move to…") {
                ForEach(library.groups.filter { $0.id != g }) { other in
                    Button(other.name) {
                        modify { try library.move(p.id, to: other.id) }
                    }
                }
            }
        }
        if let targetGroup = group?.id ?? found?.1 {
            Menu("Sort Connections") {
                ForEach(ProfileSort.allCases, id: \.self) { key in
                    Button(key.rawValue) { modify { try library.sortConnections(in: targetGroup, by: key) } }
                }
            }
        }
        Button("Duplicate") {
            if let (p, g) = found {
                var copy = p; copy.id = UUID(); copy.name += " Copy"; copy.rememberPassword = false; copy.ssh?.rememberSecret = false
                editor = .profile(copy, g)
            }
        }.disabled(found == nil)
        Button("Copy as URL") {
            if let (p, _) = found {
                if let url = ProfileAddress.url(p) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
            }
        }.disabled(found == nil)
        Menu("Export Connections") {
            Button("All Groups…") { export(library.groups) }
            if let group { Button("This Group…") { export([group]) } }
            if let (p, g) = found, let parent = library.groups.first(where: { $0.id == g }) {
                Button("This Connection…") { export([ConnectionGroup(name: parent.name, connections: [p])]) }
            }
        }
        Button("Import Connections…") { importProfiles() }
        Divider()
        Button("Remove…", role: .destructive) { removal = id }.disabled(id == nil)
    }
    private func export(_ groups: [ConnectionGroup]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "connections.json"
        if panel.runModal() == .OK, let file = panel.url { modify { try library.exportGroups(groups, to: file) } }
    }
    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let file = panel.url { modify { try library.importGroups(from: file) } }
    }
    private func modify(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    private func remove(_ id: UUID) {
        modify {
            let profiles = library.groups.first(where: { $0.id == id })?.connections ?? findProfile(id).map { [$0.0] } ?? []
            try library.update { groups in
                groups.removeAll { $0.id == id }
                for index in groups.indices { groups[index].connections.removeAll { $0.id == id } }
            }
            for profile in profiles {
                if profile.rememberPassword { try ProfilePassword.write("", for: profile.id) }
                if profile.ssh?.rememberSecret == true { try ProfilePassword.write("", for: profile.id, ssh: true) }
            }
        }
    }
    private func connectSaved(_ profile: ConnectionProfile, group: UUID) async {
        let session = DatabaseSession()
        do {
            let password = profile.rememberPassword ? try ProfilePassword.read(profile.id) : ""
            let sshPassword = profile.ssh?.rememberSecret == true ? try ProfilePassword.read(profile.id, ssh: true) : ""
            let database = try await session.open(profile, password: password, sshPassword: sshPassword)
            showWorkspace(profile, session: session, database: database, password: password, sshPassword: sshPassword)
        } catch {
            editor = .profile(profile, group, error: error.localizedDescription)
        }
    }
    private func showWorkspace(_ profile: ConnectionProfile, session: DatabaseSession, database: String, password: String, sshPassword: String) {
        let workspace = Workspace(profile: profile, session: session, database: database, password: password, sshPassword: sshPassword, notebook: workspaces.notebook(for: profile.id, directory: library.directory))
        workspaces.sessions[workspace.id] = workspace
        openWindow(value: workspace.id)
    }
}

private struct ConnectionGroupSection: View {
    let group: ConnectionGroup
    let move: (UUID) -> Void
    @State private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(group.connections) { profile in
                HStack(spacing: 9) {
                    DriverBadge(driver: profile.driver)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(profile.name).font(.system(size: 14)).lineLimit(1)
                            EnvironmentBadge(profile: profile)
                            if let tag = profile.tagColor {
                                Circle().fill(profile.badgeColor).frame(width: 5, height: 5).accessibilityLabel(tag + " color tag")
                            }
                        }
                        Text(profile.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(height: 37).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 6)).draggable(profile.id.uuidString).tag(profile.id).listRowSeparator(.hidden)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.icon ?? "powerplug.fill").font(.system(size: 15, weight: .semibold)).rotationEffect(.degrees(group.icon == nil || group.icon == "powerplug.fill" ? -90 : 0)).frame(width: 30, height: 30)
                    .overlay { Circle().strokeBorder(lineWidth: 1.9) }.foregroundStyle(.orange).accessibilityHidden(true)
                Text(group.name).font(.system(size: 14, weight: .semibold))
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 37)
                .dropDestination(for: String.self) { values, _ in
                    guard values.count == 1, let id = UUID(uuidString: values[0]) else { return false }
                    move(id); return true
                }
        }.listRowInsets(EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 6)).tag(group.id).listRowSeparator(.hidden)
    }
}
