import SwiftUI
import Sparkle

#if !arch(arm64)
#error("TableExplorer requires Apple Silicon.")
#endif

@main
struct TableExplorerApp: App {
    @State private var library = ConnectionLibrary()
    @State private var workspaces: WorkspaceRegistry
    @StateObject private var updates: ApplicationUpdates

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let registry = WorkspaceRegistry()
        _workspaces = State(initialValue: registry)
        _updates = StateObject(wrappedValue: ApplicationUpdates(workspaces: registry))
    }

    var body: some Scene {
        Window("Saved Connections", id: "connections") {
            SavedConnectionsView(library: library, workspaces: workspaces).modifier(BrowserAppearance())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1111, height: 826)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                if updates.controller != nil {
                    Button("Check for Updates…") { updates.controller?.checkForUpdates(nil) }
                        .disabled(!updates.canCheck)
                    Toggle("Automatically Check for Updates", isOn: Binding(
                        get: { updates.automaticChecks },
                        set: { updates.controller?.updater.automaticallyChecksForUpdates = $0 }
                    ))
                }
            }
        }

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

@MainActor private final class ApplicationUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    private let workspaces: WorkspaceRegistry

    init(workspaces: WorkspaceRegistry) {
        self.workspaces = workspaces
        super.init()
        // Only distribution builds have a signing key. Development and UI test builds stay offline.
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        controller.startUpdater()
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard workspaces.sessions.values.contains(where: { $0.hasRunningTasks || $0.hasDrafts || !$0.unsavedQueries.isEmpty || $0.window?.attachedSheet != nil }) else { return true }
        let alert = NSAlert()
        alert.messageText = "Finish your database work before updating"
        alert.informativeText = "Finish running operations, save or discard pending edits, and close any open dialogs. Then choose Check for Updates again."
        alert.runModal()
        return false
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
