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
            VStack(spacing: 8) {
                Image(systemName: "externaldrive.fill").font(.system(size: 46)).foregroundStyle(.orange).accessibilityHidden(true)
                Text("Connection Browser").font(.title2.weight(.light))
                Text("Saved connections").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(width: 190).frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            Divider()
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
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 32)
                Divider()
                HStack {
                    Button("New Connection", systemImage: "plus") { newProfile(in: selectedGroup) }
                        .disabled(library.groups.isEmpty)
                    Button("New Group", systemImage: "folder.badge.plus") { editor = .group(ConnectionGroup(name: "")) }
                    Spacer()
                    Menu("Library", systemImage: "ellipsis.circle") {
                        Button("Import Connections…") { importProfiles() }
                        Button("Export All Connections…") { export(library.groups) }
                    }.menuStyle(.borderlessButton).fixedSize()
                }.padding(8)
            }
        }
        .frame(minWidth: 560, minHeight: 300)
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
                    Text(profile.driver == .mariaDB ? "Mr" : "Sq").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 26, height: 26).background(profile.badgeColor, in: Circle())
                        .accessibilityLabel(profile.driver.rawValue)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(profile.name)
                            if !profile.environment.isEmpty {
                                Text(profile.environment).font(.caption2).padding(.horizontal, 3)
                                    .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 0.8) }
                                    .foregroundStyle(profile.environmentColor)
                            }
                        }
                        Text(profile.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(height: 33).draggable(profile.id.uuidString).tag(profile.id).listRowSeparator(.hidden)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.icon ?? "powerplug.fill").frame(width: 26, height: 26)
                    .overlay { Circle().strokeBorder(lineWidth: 1.4) }.foregroundStyle(.orange).accessibilityHidden(true)
                Text(group.name).font(.headline)
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
                .dropDestination(for: String.self) { values, _ in
                    guard values.count == 1, let id = UUID(uuidString: values[0]) else { return false }
                    move(id); return true
                }
        }.tag(group.id).listRowSeparator(.hidden)
    }
}
