import Foundation
import Observation

@MainActor @Observable
final class WorkspaceTab: Identifiable {
    let id = UUID()
    var title: String
    let object: DatabaseObject?
    var sql = ""
    var textSelection = NSRange(location: 0, length: 0)
    var executions: [(sql: String, result: QueryResult, error: String?, duration: TimeInterval)] = []
    var executionIndex = 0
    var lastDuration: TimeInterval? { executions.indices.contains(executionIndex) ? executions[executionIndex].duration : nil }
    func selectExecution(_ index: Int) {
        guard executions.indices.contains(index) else { return }
        executionIndex = index
        result = executions[index].result; error = executions[index].error; selected = nil
    }
    var result = QueryResult()
    var error: String?
    var busy = false
    var offset = 0
    var limit = 300
    var selected: Int?
    var totalCount = 0
    var filterEditorVisible = false
    var filters: [ColumnFilter] = []
    var appliedFilters: [ColumnFilter] = []
    var hiddenColumns: Set<String> = []
    var sortColumn: String?
    var descending = false
    var requestID = UUID()
    var schema: ObjectSchema?
    var changes: [RowChange] = []
    var showStructure = false
    var section = "Columns"
    var structureResult = QueryResult()
    var editor: RowChange?
    var previewShown = false
    var commitError: String?
    var editHistory: [[RowChange]] = []

    var displayed: QueryResult {
        guard !changes.isEmpty else { return result }
        var display = result
        for i in result.rows.indices {
            guard let change = draft(at: i) else { continue }
            for (c, column) in result.columns.enumerated() {
                if let value = change.changes[column] { display.rows[i][c] = value }
            }
        }
        for change in changes where change.original == nil {
            display.rows.append(result.columns.map { change.changes[$0] ?? .text("DEFAULT") })
        }
        return display
    }

    var cellMarkers: [Int: [String: String]] {
        guard !changes.isEmpty else { return [:] }
        var markers: [Int: [String: String]] = [:]
        let count = result.rows.count + changes.filter { $0.original == nil }.count
        for i in 0..<count {
            guard let change = draft(at: i) else { continue }
            if change.deleted || change.original == nil {
                markers[i] = Dictionary(uniqueKeysWithValues: result.columns.map { ($0, change.deleted ? "minus.circle" : "plus.circle") })
            } else { markers[i] = change.changes.mapValues { _ in "pencil" } }
        }
        return markers
    }

    func draft(at index: Int) -> RowChange? {
        if result.rows.indices.contains(index) {
            let original = Dictionary(uniqueKeysWithValues: zip(result.columns, result.rows[index]))
            return changes.first { $0.original == original }
        }
        let inserted = changes.filter { $0.original == nil }
        let position = index - result.rows.count
        return inserted.indices.contains(position) ? inserted[position] : nil
    }

    func editRow(at index: Int) -> RowChange? {
        if let draft = draft(at: index) { return draft }
        guard result.rows.indices.contains(index) else { return nil }
        return RowChange(original: Dictionary(uniqueKeysWithValues: zip(result.columns, result.rows[index])))
    }

    func stage(_ change: RowChange) {
        editHistory.append(changes)
        if let i = changes.firstIndex(where: { $0.id == change.id }) { changes.remove(at: i) }
        if change.original == nil && change.deleted { selected = nil; return }
        if change.deleted || change.original == nil || !change.changes.isEmpty { changes.append(change) }
    }

    func discard() { changes.removeAll(); editHistory.removeAll(); commitError = nil }
    func undoChange() { if let previous = editHistory.popLast() { changes = previous } }
    init(title: String, object: DatabaseObject? = nil) { self.title = title; self.object = object }
}

@MainActor @Observable
final class Workspace: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let notebook: QueryNotebook
    let session: DatabaseSession
    var database: String
    private let password: String
    var objects: [DatabaseObject] = []
    var tabs: [WorkspaceTab] = []
    var activeID: UUID?
    var active: WorkspaceTab? { tabs.first { $0.id == activeID } }
    var log: [String] = []
    var error: String?
    var connected = true
    var reconnecting = false
    var showItems = true
    var showDetails = true
    var showConsole = true
    var objectSearchShown = false
    var databaseSelectorShown = false
    var hasDrafts: Bool { tabs.contains { !$0.changes.isEmpty } }
    var hasRunningTasks: Bool { tabs.contains { $0.busy } }

    init(profile: ConnectionProfile, session: DatabaseSession, database: String, password: String, notebook: QueryNotebook) {
        self.notebook = notebook; self.password = password
        self.profile = profile; self.session = session; self.database = database
    }

    func disconnect() async {
        guard connected, !hasRunningTasks else { return }
        connected = false
        await session.close()
    }

    func reconnect() async {
        guard !connected, !reconnecting else { return }
        reconnecting = true
        defer { reconnecting = false }
        do {
            var target = profile
            if profile.driver == .mariaDB { target.database = database }
            database = try await session.open(target, password: password)
            connected = true
            await reloadObjects()
            if let active, active.object != nil && active.changes.isEmpty { await load(active) }
        } catch { record(error) }
    }

    func switchDatabase(to name: String) async throws {
        guard !hasDrafts && !hasRunningTasks else { throw BrowserError("Finish pending changes and queries before switching databases.") }
        _ = try await session.query("USE " + DatabaseSession.identifier(name))
        tabs = []; activeID = nil; database = name
        await reloadObjects()
    }

    func closeTab(_ tab: WorkspaceTab) {
        guard !tab.busy else { return }
        tabs.removeAll { $0.id == tab.id }
        if activeID == tab.id { activeID = tabs.last?.id }
    }

    private func record(_ error: Error) {
        self.error = error.localizedDescription
        if (error as? BrowserError)?.disconnected == true { connected = false }
    }

    func reloadObjects() async {
        do {
            objects = try await session.objects()
            error = nil
        } catch { record(error) }
    }
    func open(_ object: DatabaseObject) async {
        if let existing = tabs.first(where: { $0.object == object }) { activeID = existing.id; return }
        let tab = WorkspaceTab(title: object.name, object: object)
        tabs.append(tab)
        activeID = tab.id
        await load(tab)
        do { tab.schema = try await session.schema(of: object, driver: profile.driver) }
        catch { tab.error = error.localizedDescription }
    }

    func loadStructure(_ tab: WorkspaceTab) async {
        guard let object = tab.object else { return }
        let section = tab.section
        do {
            let result = try await session.structure(object, driver: profile.driver, section: section)
            if tab.section == section { tab.structureResult = result; tab.error = nil }
        } catch {
            if tab.section == section { tab.structureResult = QueryResult(); tab.error = error.localizedDescription }
        }
    }

    func commit(_ tab: WorkspaceTab) async {
        guard connected, !tab.busy, let object = tab.object else { return }
        tab.busy = true; tab.commitError = nil
        do {
            try await session.commit(tab.changes, object: object, driver: profile.driver)
            tab.discard(); tab.previewShown = false
            await load(tab)
        } catch { tab.commitError = error.localizedDescription; record(error) }
        tab.busy = false
    }

    func newQuery(text: String = "") {
        let tab = WorkspaceTab(title: "Query \(tabs.filter { $0.object == nil }.count + 1)")
        tab.sql = text
        tabs.append(tab); activeID = tab.id
    }
    func load(_ tab: WorkspaceTab) async {
        guard let object = tab.object else { return }
        let request = UUID()
        tab.requestID = request; tab.busy = true; tab.error = nil
        defer { if tab.requestID == request { tab.busy = false } }
        do {
            let page = try await session.page(of: object, filters: tab.appliedFilters, sortColumn: tab.sortColumn,
                                              descending: tab.descending, offset: tab.offset, limit: tab.limit)
            guard request == tab.requestID else { return }
            log.append(page.sql)
            tab.result = page.result; tab.totalCount = page.count; tab.offset = page.offset; tab.selected = nil
        } catch {
            guard request == tab.requestID else { return }
            tab.error = error.localizedDescription; log.append(error.localizedDescription); record(error)
        }
    }
    func run(_ statements: [String], on tab: WorkspaceTab) async {
        guard connected, !tab.busy else { return }
        tab.busy = true; tab.error = nil; tab.executions = []; tab.result = QueryResult(); tab.selected = nil
        defer { tab.busy = false }
        for sql in statements {
            guard connected else { tab.error = "This workspace is disconnected."; return }
            let start = Date()
            var result = QueryResult()
            var failure: String?
            do { result = try await session.query(sql) }
            catch { failure = error.localizedDescription; if (error as? BrowserError)?.disconnected == true { record(error) } }
            let duration = Date().timeIntervalSince(start)
            let hidden = QueryNotebook.containsCredentials(sql)
            log.append(hidden ? "Statement containing credentials" : sql)
            if let failure { log.append(hidden ? "Statement failed" : failure) }
            notebook.record(sql: sql, duration: duration, error: failure)
            tab.executions.append((sql, result, failure, duration)); tab.selectExecution(tab.executions.count - 1)
            if failure != nil { break }
        }
    }
}

@MainActor @Observable
final class WorkspaceRegistry {
    var sessions: [UUID: Workspace] = [:]
    private var notebooks: [UUID: QueryNotebook] = [:]
    func notebook(for id: UUID, directory: URL) -> QueryNotebook {
        if let existing = notebooks[id] { return existing }
        let notebook = QueryNotebook(directory: directory, profile: id)
        notebooks[id] = notebook
        return notebook
    }
}
