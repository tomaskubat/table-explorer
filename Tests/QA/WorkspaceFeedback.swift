import QuartzCore
import SwiftUI

@main struct WorkspaceFeedback {
    @MainActor final class CloseCount { var value = 0 }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await removeFilters()
                if !CommandLine.arguments.contains("--filters-only") {
                    try await run(); try await refreshData(); try await sharedConnections()
                }
                exit(0)
            }
            catch { print(error.localizedDescription); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func removeFilters() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile = ConnectionProfile()
        profile.name = "Filters"; profile.driver = .sqlite; profile.filePath = directory.appending(path: "filters.sqlite").path
        _ = try SQLiteHandle(path: profile.filePath, create: true)
        let session = DatabaseSession()
        let database = try await session.open(profile, password: "")
        _ = try await session.query("CREATE TABLE cities(id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await session.query("INSERT INTO cities VALUES (1,'Brno'),(2,'Praha')")
        let workspace = Workspace(profile: profile, session: session, database: database, password: "", sshPassword: "",
                                  notebook: QueryNotebook(directory: directory, profile: profile.id))
        await workspace.start()
        await workspace.open(DatabaseObject(name: "cities", kind: .table))
        let tab = workspace.active!
        tab.filterEditorVisible = true
        tab.filters = [ColumnFilter(column: "name", operation: .equals, value: "Brno")]
        await workspace.applyFilters(tab)
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw BrowserError("FAIL: " + label) }
            print("PASS: " + label)
        }
        try check(tab.result.rows.count == 1, "filter removal starts with a filtered table")
        let controls = FilterConditions(workspace: workspace, tab: tab)
        let filters = Binding(get: { tab.filters }, set: { tab.filters = $0 })
        func remove(_ index: Int) async throws {
            let request = tab.requestID
            controls.removeCondition(filters[index])
            for _ in 0..<50 {
                if tab.requestID != request && !tab.busy { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw BrowserError("FAIL: removing an applied filter did not finish reloading data")
        }
        try await remove(0)
        try check(tab.filters.isEmpty, "removing the last filter leaves the filter editor alive")
        try check(tab.appliedFilters.isEmpty && tab.result.rows.count == 2, "removing an applied filter restores all rows")

        tab.filters = [ColumnFilter(column: "name", operation: .equals, value: "Brno"),
                       ColumnFilter(column: "id", operation: .greater, value: "0")]
        await workspace.applyFilters(tab)
        let remainingID = tab.filters[1].id
        try await remove(0)
        try check(tab.filters.map(\.id) == [remainingID] && tab.appliedFilters.map(\.id) == [remainingID] && tab.result.rows.count == 2,
                  "removing the first applied filter preserves remaining conditions")
        tab.filters.append(ColumnFilter(column: "name", operation: .equals, value: "Praha"))
        let request = tab.requestID
        controls.removeCondition(filters[1])
        try await Task.sleep(for: .milliseconds(20))
        try check(tab.filters.map(\.id) == [remainingID] && tab.appliedFilters.map(\.id) == [remainingID] && tab.requestID == request,
                  "removing a draft filter leaves the applied query unchanged")
        filters[0].value.wrappedValue = "1"
        await workspace.applyFilters(tab)
        try check(tab.result.rows == [[.integer("2"), .text("Praha")]], "remaining filter bindings stay editable after removal")
        tab.limit = 1; tab.offset = 1
        try await remove(0)
        try check(tab.offset == 0 && tab.totalCount == 2 && tab.result.rows.count == 1,
                  "removing the last applied filter resets pagination and restores the row count")
        await session.close()
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
        let closed = CloseCount()
        registry.onLastConnectionClosed = { closed.value += 1 }
        let database = try await session.open(profile, password: "")
        _ = try await session.query("CREATE TABLE cities(id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await session.query("INSERT INTO cities VALUES (1, 'Brno'), (2, 'Praha')")
        _ = try await session.query("CREATE TABLE countries(id INTEGER PRIMARY KEY, name TEXT)")
        let workspace = Workspace(profile: profile, session: session, database: database, password: "", sshPassword: "",
                                  notebook: registry.notebook(for: profile.id, directory: directory))
        registry.sessions[workspace.id] = workspace
        registry.activeID = workspace.id
        await workspace.start()
        await workspace.open(DatabaseObject(name: "cities", kind: .table))
        let city = workspace.active!
        await workspace.open(DatabaseObject(name: "countries", kind: .table))
        let country = workspace.active!
        workspace.activeID = city.id
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1150, height: 660),
                              styleMask: [.titled, .resizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceHostView(registry: registry))
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
        registry.sessions[workspace.id] = nil
        registry.add(restored)
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
                check(closed.value == 1, "closing the last connection requests application termination exactly once")
            } else { check(false, "closing a connection still guards unsaved SQL after canceling") }
        } else { check(false, "closing a connection protects unsaved SQL") }
        await session.close()
        if failures > 0 { throw BrowserError("\(failures) workspace feedback checks failed") }
    }

    @MainActor static func refreshData() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile = ConnectionProfile()
        profile.name = "Refresh"; profile.driver = .sqlite; profile.filePath = directory.appending(path: "refresh.sqlite").path
        _ = try SQLiteHandle(path: profile.filePath, create: true)
        let session = DatabaseSession()
        let database = try await session.open(profile, password: "")
        _ = try await session.query("CREATE TABLE cities(id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await session.query("INSERT INTO cities VALUES(1,'Brno'),(2,'Praha'),(3,'Ostrava')")
        _ = try await session.query("CREATE VIEW city_names AS SELECT name FROM cities")
        let workspace = Workspace(profile: profile, session: session, database: database, password: "", sshPassword: "",
                                  notebook: QueryNotebook(directory: directory, profile: profile.id))
        await workspace.start()
        await workspace.open(DatabaseObject(name: "cities", kind: .table))
        let tab = workspace.active!
        tab.appliedFilters = [ColumnFilter(column: "id", operation: .greater, value: "0")]
        tab.filters = [ColumnFilter(column: "id", operation: .equals, value: "99")]
        tab.sortColumn = "id"; tab.descending = true; tab.limit = 1; tab.offset = 1
        tab.hiddenColumns = ["id"]
        await workspace.load(tab)
        tab.selected = 0; tab.focusedColumn = "name"
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw BrowserError("FAIL: " + label) }
            print("PASS: " + label)
        }
        let map = Keymap(Data())
        try check(map[.refresh] == KeyBinding("r") && map.issue(map[.refresh], for: .refresh) == nil,
                  "refresh defaults to Command-R without a shortcut conflict")
        _ = try await session.query("UPDATE cities SET name='External update' WHERE id=2")
        await workspace.refresh(tab)
        try check(tab.result.rows == [[.integer("2"), .text("External update")]], "refresh fetches externally changed rows")
        try check(tab.offset == 1 && tab.limit == 1 && tab.sortColumn == "id" && tab.descending && tab.totalCount == 3,
                  "refresh preserves the current page, page size, and sorting")
        try check(tab.appliedFilters.first?.value == "0" && tab.filters.first?.value == "99" && tab.hiddenColumns == ["id"],
                  "refresh preserves applied filters, unapplied filter edits, and hidden columns")
        try check(tab.selectedRows == [0] && tab.focusedRow == 0 && tab.focusedColumn == "name",
                  "refresh preserves the selected row and column")
        let request = tab.requestID
        tab.busy = true; await workspace.refresh(tab); tab.busy = false
        try check(tab.requestID == request, "refresh does not start another request while data is loading")
        var draft = tab.editRow(at: 0)!
        draft.changes["name"] = .text("Local draft"); tab.stage(draft)
        await workspace.refresh(tab)
        try check(!workspace.canRefreshActiveTable && tab.requestID == request && tab.displayed.rows.first?.last == .text("Local draft"),
                  "refresh protects uncommitted row edits")
        tab.discard(); tab.showStructure = true; await workspace.refresh(tab)
        try check(!workspace.canRefreshActiveTable && tab.requestID == request, "data refresh is unavailable in structure mode")
        tab.showStructure = false; workspace.connected = false; await workspace.refresh(tab)
        try check(!workspace.canRefreshActiveTable && tab.requestID == request, "data refresh is unavailable while disconnected")
        workspace.connected = true
        workspace.newQuery(text: "UPDATE cities SET name='Never executed'")
        await workspace.refresh(workspace.active!)
        let result = try await session.query("SELECT name FROM cities WHERE id=2")
        try check(!workspace.canRefreshActiveTable && result.rows == [[.text("External update")]],
                  "refresh does not execute SQL editor text")
        await workspace.open(DatabaseObject(name: "city_names", kind: .view))
        let view = workspace.active!
        _ = try await session.query("UPDATE cities SET name='View update' WHERE id=2")
        await workspace.refresh(view)
        try check(workspace.canRefreshActiveTable && view.result.rows.contains([.text("View update")]),
                  "refresh also reloads database views")
        await session.close()
    }

    @MainActor static func sharedConnections() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = WorkspaceRegistry()
        let closed = CloseCount()
        registry.onLastConnectionClosed = { closed.value += 1 }
        func makeWorkspace(_ name: String) async throws -> Workspace {
            var profile = ConnectionProfile()
            profile.name = name; profile.driver = .sqlite
            profile.filePath = directory.appending(path: name + ".sqlite").path
            _ = try SQLiteHandle(path: profile.filePath, create: true)
            let session = DatabaseSession()
            let database = try await session.open(profile, password: "")
            let workspace = Workspace(profile: profile, session: session, database: database, password: "", sshPassword: "",
                                      notebook: registry.notebook(for: profile.id, directory: directory))
            await workspace.start()
            return workspace
        }
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw BrowserError("FAIL: " + label) }
            print("PASS: " + label)
        }
        let first = try await makeWorkspace("First"), second = try await makeWorkspace("Second")
        registry.add(first)
        first.newQuery(); first.active!.sql = "SELECT 'first draft';"
        let draftID = first.activeID
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 1150, height: 660),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceHostView(registry: registry))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func draw() async throws {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        try await draw()
        let number = window.windowNumber
        registry.add(second); try await draw()
        try check(registry.active === second && first.window === window && second.window === window && window.windowNumber == number,
                  "opening a second connection reuses the same window")
        registry.activate(first.id); try await draw()
        try check(first.activeID == draftID && first.active?.sql == "SELECT 'first draft';" && first.active?.unsavedSQL == true,
                  "switching connections preserves SQL tabs and unsaved text")
        registry.cycle(forward: true); try await draw()
        try check(registry.active === second, "workspace navigation cycles connections in the shared window")
        second.newQuery(); second.active!.busy = true
        window.performClose(nil); try await draw()
        let running = window.attachedSheet
        try check(running != nil && registry.sessions.count == 2, "closing the shared window guards a running background connection")
        window.endSheet(running!, returnCode: .alertFirstButtonReturn); try await draw()
        registry.requestClose(first); try await draw()
        let prompt = window.attachedSheet
        try check(prompt != nil && registry.active === first, "closing an inactive connection reviews that connection's unsaved SQL")
        window.endSheet(prompt!, returnCode: .alertFirstButtonReturn); try await draw()
        try check(registry.sessions.count == 2 && first.active?.unsavedSQL == true,
                  "canceling a connection close preserves both sessions")
        registry.requestClose(first); try await draw()
        window.endSheet(window.attachedSheet!, returnCode: .alertThirdButtonReturn); try await draw()
        try check(registry.sessions.count == 1 && registry.active === second && second.active?.busy == true && window.isVisible,
                  "closing one connection leaves the other connection and its running query open")
        try check(closed.value == 0, "closing one of several connections does not request application termination")
        second.active!.busy = false
        let third = try await makeWorkspace("Third")
        third.newQuery(); third.active!.sql = "SELECT 'third draft';"
        registry.add(third); registry.activate(second.id); try await draw()
        BrowserPreferences.defaults.set(true, forKey: "reopenWorkspaces")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        let startup = StartupWindowFile.consume(in: directory)
        try check(startup.count == 2 && startup.last?.profile == second.profile.id && startup.contains { $0.profile == third.profile.id },
                  "startup restoration remembers every shared-window connection and the active connection")
        window.performClose(nil); try await draw()
        try check(window.attachedSheet != nil && registry.active === third,
                  "closing the shared window also guards unsaved SQL in an inactive connection")
        window.endSheet(window.attachedSheet!, returnCode: .alertThirdButtonReturn); try await draw()
        try check(registry.sessions.isEmpty && !window.isVisible, "closing the shared window releases all approved connections")
    }
}
