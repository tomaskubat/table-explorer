import QuartzCore
import SQLite3
import SwiftUI

/// Exercises a visible, release-optimized workspace without XCTest's wait-for-idle overhead.
@main struct WorkspacePerformance {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await measure(); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        app.run()
    }

    static func makeDatabase(at url: URL) throws {
        let db = try SQLiteHandle(path: url.path, create: true)
        let fields = (1..<24).map { "field_\($0) TEXT" }.joined(separator: ",")
        var sql = "BEGIN;"
        for i in 0..<160 {
            sql += "CREATE TABLE t_\(i)(id INTEGER PRIMARY KEY, \(fields));"
            if i < 8 {
                let cells = (1..<24).map { "printf('t\(i)-%d-\($0)', x)" }.joined(separator: ",")
                sql += "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<300) INSERT INTO t_\(i) SELECT x,\(cells) FROM n;"
            }
        }
        guard sqlite3_exec(db.database, sql + "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw BrowserError(String(cString: sqlite3_errmsg(db.database)))
        }
    }

    @MainActor static func measure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appending(path: "perf.sqlite")
        try makeDatabase(at: db)
        var profile = ConnectionProfile()
        profile.driver = .sqlite; profile.filePath = db.path; profile.name = "Performance"
        let registry = WorkspaceRegistry(), session = DatabaseSession()
        let database = try await session.open(profile, password: "")
        let workspace = Workspace(profile: profile, session: session, database: database, password: "", sshPassword: "",
                                  notebook: registry.notebook(for: profile.id, directory: directory))
        registry.sessions[workspace.id] = workspace
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1150, height: 660),
                              styleMask: [.titled, .resizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: WorkspaceView(workspace: workspace, registry: registry))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        func draw() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        func verify(_ index: Int) throws {
            guard let grid = workspace.active?.grid, grid.window === window, grid.numberOfRows == 300,
                  let cell = grid.view(atColumn: 1, row: 0, makeIfNecessary: false) as? NSTableCellView,
                  cell.textField?.stringValue == "t\(index)-1-1" else { throw BrowserError("Incorrect visible grid for t_\(index)") }
            if let header = grid.headerView {
                let center = CGPoint(x: cell.bounds.midX, y: cell.bounds.midY)
                if header.bounds.contains(header.convert(center, from: cell)) {
                    throw BrowserError("Column header covers the first record of t_\(index)")
                }
            }
        }
        func now() -> Double { CACurrentMediaTime() * 1000 }
        var open: [Double] = [], switches: [Double] = [], resize: [Double] = []
        for i in 0..<8 {
            let start = now()
            await workspace.open(DatabaseObject(name: "t_\(i)", kind: .table))
            draw(); open.append(now() - start)
            try verify(i)
        }
        for i in 0..<24 {
            let index = i % 8, start = now()
            workspace.activeID = workspace.tabs[index].id
            draw(); switches.append(now() - start)
            try verify(index)
        }
        let frame = window.frame
        for i in 0..<40 {
            let step = CGFloat(i < 20 ? i : 40 - i), start = now()
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width + step * 4,
                                   height: frame.height + step * 2), display: true)
            draw(); resize.append(now() - start)
        }
        for (name, values) in [("Open table", open), ("Switch tab", switches), ("Resize step", resize)] {
            let sorted = values.sorted()
            print(String(format: "%@: p50 %.1f ms, p95 %.1f ms (n=%d)", name, sorted[sorted.count / 2],
                         sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], sorted.count))
        }
    }
}
