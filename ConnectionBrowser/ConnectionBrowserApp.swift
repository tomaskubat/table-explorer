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
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1111, height: 826)
        .windowResizability(.contentMinSize)

        WindowGroup("Workspace", for: UUID.self) { $id in
            if let id, let workspace = workspaces.sessions[id] {
                WorkspaceView(workspace: workspace, registry: workspaces).modifier(BrowserAppearance())
                    .onDisappear {
                        workspace.releaseRecovery()
                        workspaces.sessions[id] = nil
                        Task { await workspace.session.close() }
                    }
            } else {
                ContentUnavailableView("Session Closed", systemImage: "bolt.slash", description: Text("Open a saved connection to reconnect."))
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 760)
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

    @State private var previews: [UUID: NSImage] = [:]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                ForEach(registry.sessions.values.sorted { $0.profile.name < $1.profile.name }) { workspace in
                    Button {
                        openWindow(value: workspace.id); dismissWindow(id: "workspaces")
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Group {
                                if let preview = previews[workspace.id] { Image(nsImage: preview).resizable().scaledToFit() }
                                else { Image(systemName: "macwindow").font(.largeTitle) }
                            }
                            .frame(maxWidth: .infinity).frame(height: 100)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            Text(workspace.profile.name).font(.headline)
                            Text(workspace.database + " · " + (workspace.connected ? workspace.profile.driver.rawValue : "Disconnected")).font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(workspace.profile.name + " / " + workspace.database)
                }
                Button {
                    openWindow(id: "connections"); dismissWindow(id: "workspaces")
                } label: {
                    VStack {
                        Image(systemName: "plus").font(.title)
                        Text("New Workspace")
                    }.frame(maxWidth: .infinity, minHeight: 135)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityLabel("New Workspace")
            }.padding(14)
        }.frame(minWidth: 400, minHeight: 220)
        .onAppear {
            previews.removeAll()
            for workspace in registry.sessions.values {
                guard let view = workspace.window?.contentView, !view.bounds.isEmpty,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let image = NSImage(size: view.bounds.size)
                image.addRepresentation(bitmap); previews[workspace.id] = image
            }
        }
    }
}
