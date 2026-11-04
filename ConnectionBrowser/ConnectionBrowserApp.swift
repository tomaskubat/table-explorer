import SwiftUI

@main
struct ConnectionBrowserApp: App {
    var body: some Scene {
        Window("Saved Connections", id: "connections") {
            SavedConnectionsView()
        }
        .defaultSize(width: 660, height: 370)
        .windowResizability(.contentMinSize)
    }
}
