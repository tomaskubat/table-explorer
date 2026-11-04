import SwiftUI

@main
struct ConnectionBrowserApp: App {
    var body: some Scene {
        Window("Uložená spojení", id: "connections") {
            SavedConnectionsView()
        }
        .defaultSize(width: 660, height: 370)
        .windowResizability(.contentMinSize)
    }
}
