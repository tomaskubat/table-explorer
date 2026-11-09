import QuartzCore
import SwiftUI

@main struct WorkspaceFeedback {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile = ConnectionProfile()
        profile.driver = .sqlite; profile.filePath = directory.appending(path: "feedback.sqlite").path
        profile.name = "Feedback"
        _ = try SQLiteHandle(path: profile.filePath, create: true)
        let session = DatabaseSession(), registry = WorkspaceRegistry()
        let database = try await session.open(profile, password: "")
        _ = try await session.query("CREATE TABLE cities(id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await session.query("INSERT INTO cities VALUES (1, 'Brno'), (2, 'Praha')")
        _ = try await session.query("CREATE TABLE countries(id INTEGER PRIMARY KEY, name TEXT)")
        let workspace = Workspace(profile: profile, session: session, database: database, password: "", sshPassword: "",
                                  notebook: registry.notebook(for: profile.id, directory: directory))
        registry.sessions[workspace.id] = workspace
        await workspace.start()
        await workspace.open(DatabaseObject(name: "cities", kind: .table))
        let city = workspace.active!
        await workspace.open(DatabaseObject(name: "countries", kind: .table))
        let country = workspace.active!
        workspace.activeID = city.id
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1150, height: 660),
                              styleMask: [.titled, .resizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(workspace: workspace, registry: registry))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func draw() async throws {
            try await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        }
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        try await draw()
        let grid = city.grid!
        let navigator = tables(in: window.contentView!).first { !($0 is DataGrid.GridTable) }!
        check(navigator.selectedRow == 0, "initially active table is selected in the navigator")
        let widths = grid.tableColumns.map(\.width)
        city.sortColumn = "name"; city.descending = false
        await workspace.load(city); try await draw()
        let nameColumn = grid.tableColumns.first { $0.title == "name" }!
        let ascending = grid.indicatorImage(in: nameColumn)
        check(ascending != nil, "ascending sort has a column header indicator")
        city.descending = true
        await workspace.load(city); try await draw()
        let descending = grid.indicatorImage(in: nameColumn)
        check(descending != nil && descending !== ascending, "descending sort changes the header indicator")
        city.sortColumn = nil; await workspace.load(city); try await draw()
        check(grid.tableColumns.allSatisfy { grid.indicatorImage(in: $0) == nil }, "clearing sort removes all indicators")
        grid.handler!.tableView(grid, didClick: nameColumn); try await draw()
        check(city.sortColumn == "name" && !city.descending && grid.indicatorImage(in: nameColumn) != nil,
              "clicking a header sets the sort and its indicator")
        grid.handler!.tableView(grid, didClick: nameColumn); try await draw()
        check(city.descending && city.result.rows.first?.last == .text("Praha") && grid.indicatorImage(in: nameColumn) === descending,
              "clicking the header again reverses both the rows and indicator")
        check(grid.tableColumns.map(\.width) == widths, "sorting preserves column widths")
        let frame = grid.enclosingScrollView!.convert(grid.enclosingScrollView!.bounds, to: nil)
        city.busy = true; try await draw()
        let loadingFrame = grid.enclosingScrollView!.convert(grid.enclosingScrollView!.bounds, to: nil)
        check(frame == loadingFrame, "loading leaves the grid position and size unchanged")
        if let path = ProcessInfo.processInfo.environment["WORKSPACE_FEEDBACK_SCREENSHOT"], let view = window.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
        }
        city.busy = false; try await draw()
        workspace.focusArea = .grid
        window.makeFirstResponder(grid)
        let responder = window.firstResponder
        workspace.activeID = country.id; try await draw()
        check(navigator.selectedRow == 1, "switching tabs selects the corresponding table")
        check(window.firstResponder === responder && workspace.focusArea == .grid, "navigator synchronization leaves focus in the grid")
        workspace.newQuery(); try await draw()
        check(navigator.selectedRow == -1, "SQL tabs clear the navigator selection")
        workspace.closeTab(workspace.active!); try await draw()
        check(navigator.selectedRow == 1, "closing a tab selects the newly active table")
        workspace.activeID = city.id; try await draw()
        check(navigator.selectedRow == 0, "switching back selects the first table")
        workspace.closeTab(country); try await draw()
        let singleGrid = city.grid!
        let singleFrame = singleGrid.enclosingScrollView!.convert(singleGrid.enclosingScrollView!.bounds, to: nil)
        city.busy = true; try await draw()
        check(singleGrid.enclosingScrollView!.convert(singleGrid.enclosingScrollView!.bounds, to: nil) == singleFrame,
              "loading a single open table also preserves the layout")
        city.busy = false
        workspace.rememberOnClose()
        let restored = Workspace(profile: profile, session: session, database: database, password: "", sshPassword: "",
                                 notebook: workspace.notebook)
        await restored.start()
        window.contentView = NSHostingView(rootView: WorkspaceView(workspace: restored, registry: registry))
        try await draw()
        let restoredNavigator = tables(in: window.contentView!).first { !($0 is DataGrid.GridTable) }!
        check(restoredNavigator.selectedRow == 0 && restored.active?.object?.name == "cities",
              "restored active tabs select the matching table on first display")
        for _ in 0..<25 {
            if restored.active?.grid?.tableColumns.isEmpty == false { break }
            try await draw()
        }
        check(restored.active?.grid?.tableColumns.contains { $0.title == "name" && restored.active?.grid?.indicatorImage(in: $0) != nil } == true,
              "restored sorting displays its header indicator")
        restored.newQuery(); restored.active!.sql = "SELECT 42;"; try await draw()
        window.performClose(nil); try await draw()
        if let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn); try await draw()
            check(window.isVisible && restored.active?.sql == "SELECT 42;", "canceling connection close preserves unsaved SQL")
            window.performClose(nil); try await draw()
            if let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .alertThirdButtonReturn); try await draw()
                check(!window.isVisible, "discarding SQL closes the connection on the first attempt")
            } else { check(false, "closing a connection still guards unsaved SQL after canceling") }
        } else { check(false, "closing a connection protects unsaved SQL") }
        await session.close()
        if failures > 0 { throw BrowserError("\(failures) workspace feedback checks failed") }
    }
}
