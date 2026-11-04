import SwiftUI

private enum LibraryEditor: Identifiable {
    case group(ConnectionGroup), profile(ConnectionProfile, UUID)
    var id: UUID {
        switch self {
        case .group(let group): group.id
        case .profile(let profile, _): profile.id
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
            VStack(spacing: 8) {
                Image(systemName: "externaldrive.fill").font(.system(size: 46)).foregroundStyle(.orange).accessibilityHidden(true)
                Text("Connection Browser").font(.title2.weight(.light))
                Text("Saved connections").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(width: 190).frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(library.groups) { group in
                        ConnectionGroupSection(group: group)
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    libraryMenu(ids.first)
                } primaryAction: { ids in
                    if let id = ids.first, let (profile, group) = findProfile(id) {
                        Task { await connectSaved(profile, group: group) }
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 32)
                Divider()
                HStack {
                    Button("New Connection", systemImage: "plus") { newProfile(in: selectedGroup) }
                        .disabled(library.groups.isEmpty)
                    Button("New Group", systemImage: "folder.badge.plus") { editor = .group(ConnectionGroup(name: "")) }
                    Spacer()
                }.padding(8)
            }
        }
        .frame(minWidth: 560, minHeight: 300)
        .sheet(item: $editor) { editor in
            switch editor {
            case .group(let group): GroupEditor(library: library, group: group)
            case .profile(let profile, let group):
                ProfileEditor(library: library, profile: profile, groupID: group) { connection, session, database in
                    showWorkspace(connection, session: session, database: database)
                }
            }
        }
        .alert("Connection Library", isPresented: Binding(get: { error != nil || library.loadError != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? library.loadError ?? "") }
        .confirmationDialog("Remove from the library?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { id in
            Button("Remove", role: .destructive) { remove(id) }
            Button("Cancel", role: .cancel) {}
        } message: { id in
            if let group = library.groups.first(where: { $0.id == id }) {
                Text("Remove \(group.name) and its \(group.connections.count) saved profiles? Database files and servers are kept.")
            } else { Text("Remove this saved profile? Its database is kept.") }
        }
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
        if let group { editor = .profile(ConnectionProfile(), group) }
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
                        modify {
                            try library.update { groups in
                                for i in groups.indices { groups[i].connections.removeAll { $0.id == p.id } }
                                if let index = groups.firstIndex(where: { $0.id == other.id }) { groups[index].connections.append(p) }
                            }
                        }
                    }
                }
            }
        }
        Button("Duplicate") {
            if let (p, g) = found {
                var copy = p; copy.id = UUID(); copy.name += " Copy"; copy.rememberPassword = false
                editor = .profile(copy, g)
            }
        }.disabled(found == nil)
        Button("Copy as URL") {
            if let (p, _) = found {
                var parts = URLComponents()
                parts.scheme = p.driver == .mariaDB ? "mariadb" : "file"
                if p.driver == .mariaDB {
                    parts.host = p.host; parts.port = Int(p.port); parts.user = p.user
                    parts.path = "/" + p.database
                } else { parts.path = p.filePath }
                if let url = parts.url { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
            }
        }.disabled(found == nil || found?.0.usesSocket == true)
        Divider()
        Button("Remove…", role: .destructive) { removal = id }.disabled(id == nil)
    }
    private func modify(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    private func remove(_ id: UUID) {
        modify {
            let profiles = library.groups.first(where: { $0.id == id })?.connections ?? findProfile(id).map { [$0.0] } ?? []
            try library.update { groups in
                groups.removeAll { $0.id == id }
                for index in groups.indices { groups[index].connections.removeAll { $0.id == id } }
            }
            for profile in profiles where profile.rememberPassword { try ProfilePassword.write("", for: profile.id) }
        }
    }
    private func connectSaved(_ profile: ConnectionProfile, group: UUID) async {
        let session = DatabaseSession()
        do {
            let password = profile.rememberPassword ? try ProfilePassword.read(profile.id) : ""
            let database = try await session.open(profile, password: password)
            showWorkspace(profile, session: session, database: database)
        } catch {
            editor = .profile(profile, group)
            self.error = error.localizedDescription
        }
    }
    private func showWorkspace(_ profile: ConnectionProfile, session: DatabaseSession, database: String) {
        let workspace = Workspace(profile: profile, session: session, database: database, notebook: workspaces.notebook(for: profile.id, directory: library.directory))
        workspaces.sessions[workspace.id] = workspace
        openWindow(value: workspace.id)
    }
}

private struct ConnectionGroupSection: View {
    let group: ConnectionGroup
    @State private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(group.connections) { profile in
                HStack(spacing: 9) {
                    Text(profile.driver == .mariaDB ? "Mr" : "Sq").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 26, height: 26).background(.teal, in: Circle())
                        .accessibilityLabel(profile.driver.rawValue)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(profile.name)
                            if !profile.environment.isEmpty {
                                Text(profile.environment).font(.caption2).padding(.horizontal, 3)
                                    .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 0.8) }
                                    .foregroundStyle(profile.environment == "local" ? Color.green : .orange)
                            }
                        }
                        Text(profile.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(height: 33).tag(profile.id).listRowSeparator(.hidden)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "powerplug.fill").frame(width: 26, height: 26)
                    .overlay { Circle().strokeBorder(lineWidth: 1.4) }.foregroundStyle(.orange).accessibilityHidden(true)
                Text(group.name).font(.headline)
            }.frame(height: 32)
        }.tag(group.id).listRowSeparator(.hidden)
    }
}
