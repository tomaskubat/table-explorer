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
    var cancellation: QueryCancellation?
    var stopRequested = false
    var offset = 0
    var limit = BrowserPreferences.pageSize
    var selectedRows: Set<Int> = []
    var focusedRow: Int?
    var selected: Int? {
        get { if let focusedRow, selectedRows.contains(focusedRow) { return focusedRow }; return selectedRows.min() }
        set { selectedRows = newValue.map { [$0] } ?? []; focusedRow = newValue }
    }
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
    var deletionReview: [RowChange] = []
    var transfer: GridTransfer?
    var cellEditor: CellEdit?
    var previewShown = false
    var commitError: String?
    var editHistory: [[RowChange]] = []

    var displayed: QueryResult {
        guard !changes.isEmpty else { return result }
        var display = result
        for i in result.rows.indices {
            guard let change = draft(at: i) else { continue }
            for (c, column) in result.columns.enumerated() {
                if change.defaults.contains(column) { display.rows[i][c] = .text("DEFAULT") }
                else if let value = change.changes[column] { display.rows[i][c] = value }
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
            } else {
                markers[i] = change.changes.mapValues { _ in "pencil" }
                for name in change.defaults { markers[i]?[name] = "arrow.counterclockwise" }
            }
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

    func stage(_ change: RowChange) { stage([change]) }

    func stage(_ batch: [RowChange]) {
        guard !batch.isEmpty else { return }
        editHistory.append(changes)
        for change in batch { apply(change) }
    }

    private func apply(_ change: RowChange) {
        if let i = changes.firstIndex(where: { $0.id == change.id }) { changes.remove(at: i) }
        if change.original == nil && change.deleted { selected = nil; return }
        if change.deleted || change.original == nil || !change.changes.isEmpty || !change.defaults.isEmpty { changes.append(change) }
    }

    var canInsert: Bool { object?.kind == .table && schema?.transactional == true && !busy }
    func canEdit(_ index: Int) -> Bool {
        guard canInsert, let draft = editRow(at: index), let schema else { return false }
        return draft.original == nil || (!schema.key.isEmpty && schema.key.allSatisfy { draft.original?[$0.name] != nil && draft.original?[$0.name] != .null })
    }
    func duplicate(_ indices: Set<Int>) {
        guard canInsert, let schema else { return }
        let displayedRows = displayed.rows
        let omitted = Set(schema.columns.filter { $0.generated || $0.automatic || $0.keyOrder > 0 }.map(\.name))
        let copies: [RowChange] = indices.sorted().compactMap { index in
            guard displayedRows.indices.contains(index) else { return nil }
            let pairs = zip(result.columns, displayedRows[index]).filter { !omitted.contains($0.0) }
            return RowChange(original: nil, changes: Dictionary(uniqueKeysWithValues: pairs))
        }
        stage(copies)
    }
    func deletions(_ indices: Set<Int>) -> [RowChange] {
        indices.sorted().compactMap { i in
            guard canEdit(i), var draft = editRow(at: i) else { return nil }
            draft.deleted = true
            return draft
        }
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
    private let sshPassword: String
    var objects: [DatabaseObject] = []
    var tabs: [WorkspaceTab] = []
    var activeID: UUID?
    var active: WorkspaceTab? { tabs.first { $0.id == activeID } }
    var log: [String] = []
    var error: String?
    var connected = true
    var reconnecting = false
    var showItems = true
    enum FocusArea { case grid, sql }
    var focusArea: FocusArea?
    var showDetails = true
    var showConsole = true
    var schemaDraft: SchemaDraft?
    var serverTool: ServerTool?
    var overviewShown = false
    var operation: ObjectOperationTarget?
    var maintenance: MaintenanceAction?
    var maintenanceBusy = false
    var objectSearchShown = false
    var databaseSelectorShown = false
    var hasDrafts: Bool { tabs.contains { !$0.changes.isEmpty } }
    var hasRunningTasks: Bool { maintenanceBusy || tabs.contains { $0.busy } }

    init(profile: ConnectionProfile, session: DatabaseSession, database: String, password: String, sshPassword: String, notebook: QueryNotebook) {
        self.notebook = notebook; self.password = password; self.sshPassword = sshPassword
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
            database = try await session.open(target, password: password, sshPassword: sshPassword)
            connected = true
            await reloadObjects()
            if let active, active.object != nil && active.changes.isEmpty { await load(active) }
        } catch { record(error) }
    }

    func switchDatabase(to name: String) async throws {
        guard !hasDrafts && !hasRunningTasks else { throw BrowserError("Finish pending changes and queries before switching databases.") }
        _ = try await session.query("USE " + DatabaseSession.identifier(name))
        clearDatabaseResults()
        database = name
        await reloadObjects()
    }

    func clearDatabaseResults() {
        tabs.removeAll { $0.object != nil }
        for tab in tabs { tab.result = QueryResult(); tab.executions = []; tab.error = nil; tab.selected = nil }
        if !tabs.contains(where: { $0.id == activeID }) { activeID = tabs.last?.id }
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
            if profile.driver == .mariaDB && database.isEmpty { objects = []; databaseSelectorShown = true; return }
            objects = try await session.objects()
            if profile.driver == .mariaDB { objects += try await session.routines() }
            error = nil
        } catch { record(error) }
    }
    func open(_ object: DatabaseObject, newTab: Bool = false, structure: Bool = false) async {
        if !newTab, let existing = tabs.first(where: { $0.object == object }) {
            activeID = existing.id
            if structure { existing.showStructure = true }
            return
        }
        let tab = WorkspaceTab(title: object.name, object: object)
        tab.showStructure = structure
        tabs.append(tab)
        activeID = tab.id
        if object.kind == .procedure || object.kind == .function {
            tab.section = "DDL"; tab.showStructure = true
            return
        }
        var metadataError: String?
        do { tab.schema = try await session.schema(of: object, driver: profile.driver) }
        catch { metadataError = error.localizedDescription }
        await load(tab)
        if let metadataError, tab.error == nil { tab.error = metadataError }
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
        let keyColumns = tab.schema?.key.map(\.name) ?? []
        let oldIndices = keyColumns.compactMap(tab.result.columns.firstIndex)
        func key(at index: Int) -> [SQLValue]? {
            guard !oldIndices.isEmpty, tab.result.rows.indices.contains(index) else { return nil }
            return oldIndices.map { tab.result.rows[index][$0] }
        }
        let previousKeys = Set(tab.selectedRows.compactMap(key))
        let focusedKey = tab.focusedRow.flatMap(key)
        let request = UUID()
        tab.requestID = request; tab.busy = true; tab.error = nil
        defer { if tab.requestID == request { tab.busy = false } }
        do {
            let page = try await session.page(of: object, filters: tab.appliedFilters, sortColumn: tab.sortColumn,
                                              descending: tab.descending, offset: tab.offset, limit: tab.limit, keyColumns: keyColumns)
            guard request == tab.requestID else { return }
            log.append(page.sql)
            tab.result = page.result; tab.totalCount = page.count; tab.offset = page.offset
            let keyIndices = keyColumns.compactMap(page.result.columns.firstIndex)
            tab.selectedRows = Set(page.result.rows.indices.filter { index in
                previousKeys.contains(keyIndices.map { page.result.rows[index][$0] })
            })
            tab.focusedRow = focusedKey.flatMap { key in tab.selectedRows.first { index in keyIndices.map { page.result.rows[index][$0] } == key } }
        } catch {
            guard request == tab.requestID else { return }
            tab.error = error.localizedDescription; log.append(error.localizedDescription); record(error)
        }
    }
    func stop(_ tab: WorkspaceTab) async {
        guard let cancellation = tab.cancellation else { return }
        tab.stopRequested = true
        do { try await Task.detached { try cancellation.stop() }.value }
        catch {
            if tab.cancellation === cancellation {
                tab.error = "The query is still running. Stop request failed: " + error.localizedDescription
            }
        }
    }
    func run(_ statements: [String], on tab: WorkspaceTab) async {
        guard connected, !tab.busy else { return }
        let cancellation = QueryCancellation()
        tab.busy = true; tab.stopRequested = false; tab.cancellation = cancellation
        tab.error = nil; tab.executions = []; tab.result = QueryResult(); tab.selected = nil
        defer { tab.busy = false; tab.cancellation = nil; tab.stopRequested = false }
        for sql in statements {
            if cancellation.wasRequested { break }
            guard connected else { tab.error = "This workspace is disconnected."; return }
            let start = Date()
            var result = QueryResult()
            var failure: String?
            do { result = try await session.runUserSQL(sql, cancellation: cancellation, limit: BrowserPreferences.queryLimit) }
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
    private var notebooks: [URL: QueryNotebook] = [:]
    func notebook(for id: UUID, directory: URL) -> QueryNotebook {
        let key = directory.appending(path: id.uuidString)
        if let existing = notebooks[key] { return existing }
        let notebook = QueryNotebook(directory: directory, profile: id)
        notebooks[key] = notebook
        return notebook
    }
}
