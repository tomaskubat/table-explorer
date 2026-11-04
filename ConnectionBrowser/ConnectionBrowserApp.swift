import SwiftUI

@main
struct ConnectionBrowserApp: App {
    @State private var library = ConnectionLibrary()
    @State private var workspaces = WorkspaceRegistry()

    var body: some Scene {
        Window("Saved Connections", id: "connections") {
            SavedConnectionsView(library: library, workspaces: workspaces)
        }
        .defaultSize(width: 700, height: 420)
        .windowResizability(.contentMinSize)

        WindowGroup("Workspace", for: UUID.self) { $id in
            if let id, let workspace = workspaces.sessions[id] {
                WorkspaceView(workspace: workspace)
                    .onDisappear {
                        workspaces.sessions[id] = nil
                        Task { await workspace.session.close() }
                    }
            } else {
                ContentUnavailableView("Session Closed", systemImage: "bolt.slash", description: Text("Open a saved connection to reconnect."))
            }
        }
        .defaultSize(width: 1040, height: 650)
    }
}
