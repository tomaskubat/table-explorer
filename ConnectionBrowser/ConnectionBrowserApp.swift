import SwiftUI

#if !arch(arm64)
#error("Connection Browser requires Apple Silicon.")
#endif

@main
struct ConnectionBrowserApp: App {
    @State private var library = ConnectionLibrary()
    @State private var workspaces = WorkspaceRegistry()

    init() { NSWindow.allowsAutomaticWindowTabbing = false }

    var body: some Scene {
        Window("Saved Connections", id: "connections") {
            SavedConnectionsView(library: library, workspaces: workspaces).modifier(BrowserAppearance())
        }
        .defaultSize(width: 700, height: 420)
        .windowResizability(.contentMinSize)

        WindowGroup("Workspace", for: UUID.self) { $id in
            if let id, let workspace = workspaces.sessions[id] {
                WorkspaceView(workspace: workspace).modifier(BrowserAppearance())
                    .onDisappear {
                        workspaces.sessions[id] = nil
                        Task { await workspace.session.close() }
                    }
            } else {
                ContentUnavailableView("Session Closed", systemImage: "bolt.slash", description: Text("Open a saved connection to reconnect."))
            }
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .commands { WorkspaceCommands() }

        DocumentGroup(newDocument: SQLFileDocument()) { document in
            SQLFileView(file: document.$document, registry: workspaces)
        }
        .defaultLaunchBehavior(.suppressed)

        Window("Workspaces", id: "workspaces") {
            WorkspacesView(registry: workspaces).modifier(BrowserAppearance())
        }
        .defaultSize(width: 480, height: 300)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings { PreferencesView(library: library) }
    }
}

private struct WorkspacesView: View {
    let registry: WorkspaceRegistry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading) {
            if registry.sessions.isEmpty {
                ContentUnavailableView("No Open Workspaces", systemImage: "macwindow", description: Text("Open a saved connection to start a session."))
            } else {
                List(registry.sessions.values.sorted { $0.profile.name < $1.profile.name }) { workspace in
                    Button {
                        openWindow(value: workspace.id)
                        dismissWindow(id: "workspaces")
                    } label: {
                        HStack {
                            Label(workspace.profile.name + " / " + workspace.database, systemImage: "macwindow")
                            Spacer()
                            Text(workspace.connected ? workspace.profile.driver.rawValue : "Disconnected").foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityLabel(workspace.profile.name + " / " + workspace.database)
                }
            }
            HStack {
                Spacer()
                Button("Saved Connections") { openWindow(id: "connections") }
            }.padding(10)
        }.frame(minWidth: 380, minHeight: 220)
    }
}
