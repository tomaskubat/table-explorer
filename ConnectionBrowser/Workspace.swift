import AppKit
import Foundation
import Observation

@MainActor @Observable
final class WorkspaceTab: Identifiable {
    let id: UUID
    var title: String
    let object: DatabaseObject?
    var sql = ""
    var fileURL: URL?
    var savedSQL = ""
    @ObservationIgnored var draftSave: Task<Void, Never>?
    var unsavedSQL: Bool { object == nil && sql != savedSQL }
    var textSelection = NSRange(location: 0, length: 0)
    var runRequest: UUID?
    var executions: [(title: String, sql: String, result: QueryResult, error: String?, duration: TimeInterval)] = []
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
    var columnsShown = false
    func toggleFilters() {
        filterEditorVisible.toggle()
        if filters.isEmpty, let column = result.columns.first { filters.append(ColumnFilter(column: column)) }
    }
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
    var closeAfterCommit = false
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
    init(id: UUID = UUID(), title: String, object: DatabaseObject? = nil) { self.id = id; self.title = title; self.object = object }
}

@MainActor @Observable
final class Workspace: Identifiable {
    let id = UUID()
    @ObservationIgnored weak var window: NSWindow?
    let profile: ConnectionProfile
    let notebook: QueryNotebook
    let session: DatabaseSession
    var database: String
    private let password: String
    private let sshPassword: String
    var objects: [DatabaseObject] = []
    var tabs: [WorkspaceTab] = []
    private var nextQueryNumber = 1
    var activeID: UUID?
    var active: WorkspaceTab? { tabs.first { $0.id == activeID } }
    var log: [String] = []
    var error: String?
    var connected = true
    var reconnecting = false
    var showItems = true { didSet { panelChanged(.items, visible: showItems) } }
    enum FocusArea: Hashable { case grid, sql, filter, items, detail, console }
    var focusArea: FocusArea?
    var showDetails = true { didSet { panelChanged(.detail, visible: showDetails) } }
    var showConsole = true { didSet { panelChanged(.console, visible: showConsole) } }
    var recoveryShown = false
    var bootstrapReview: [String] = []
    private var offeredBootstrap = false
    var schemaDraft: SchemaDraft?
    var serverTool: ServerTool?
    var maintenance: MaintenanceAction?
    var maintenanceBusy = false
    var csvImportShown = false
    var transferBusy = false
    var overviewShown = false
    var operation: ObjectOperationTarget?
    var objectSearchShown = false
    var databaseSelectorShown = false
    var unsavedQueries: [WorkspaceTab] { tabs.filter(\.unsavedSQL) }
    var hasDrafts: Bool { tabs.contains { !$0.changes.isEmpty } }
    var hasRunningTasks: Bool { maintenanceBusy || transferBusy || tabs.contains { $0.busy } }

    init(profile: ConnectionProfile, session: DatabaseSession, database: String, password: String, sshPassword: String, notebook: QueryNotebook) {
        self.notebook = notebook; self.password = password; self.sshPassword = sshPassword
        self.profile = profile; self.session = session; self.database = database
        let layout = notebook.panels
        showItems = layout.items; showDetails = layout.detail; showConsole = layout.console
    }

    private func panelChanged(_ area: FocusArea, visible: Bool) {
        notebook.saveLayout(PanelLayout(items: showItems, detail: showDetails, console: showConsole))
        guard !visible && focusArea == area else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let window, let root = window.contentView, let active else { return }
            @MainActor func content(in view: NSView) -> NSView? {
                if view.isHidden { return nil }
                if active.object == nil, let editor = view as? NSTextView, editor.accessibilityIdentifier() == "SQL Editor" { return editor }
                if active.object != nil && view is DataGrid.GridTable { return view }
                for child in view.subviews { if let found = content(in: child) { return found } }
                return nil
            }
            if let view = content(in: root) { window.makeFirstResponder(view) }
        }
    }

    func updateRecovery(_ tab: WorkspaceTab) {
        tab.draftSave?.cancel()
        tab.draftSave = Task { [weak self, weak tab] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            if let self, let tab { self.saveRecovery(tab) }
        }
    }

    func saveRecovery(_ tab: WorkspaceTab) {
        guard tab.object == nil && tabs.contains(where: { $0.id == tab.id }) else { return }
        if tab.unsavedSQL && !tab.sql.isEmpty && !QueryNotebook.containsCredentials(tab.sql) {
            notebook.saveDraft(RecoverableSQL(id: tab.id, database: database, title: tab.title, sql: tab.sql, date: Date()))
        } else { notebook.removeDraft(tab.id) }
    }
    func releaseRecovery() {
        for tab in tabs where tab.object == nil {
            tab.draftSave?.cancel(); saveRecovery(tab); notebook.releaseDraft(tab.id)
        }
    }
    func recover(_ draft: RecoverableSQL) {
        guard notebook.availableDrafts(in: database).contains(where: { $0.id == draft.id }) else { return }
        let tab = WorkspaceTab(id: draft.id, title: draft.title)
        tab.sql = draft.sql; tabs.append(tab); activeID = tab.id; notebook.openDraft(tab.id)
    }

    func offerBootstrap() {
        guard connected, !database.isEmpty, !offeredBootstrap else { return }
        offeredBootstrap = true
        if let sql = profile.bootstrapSQL { bootstrapReview = SQLDocument.statements(in: sql, driver: profile.driver).map(\.sql) }
    }

    func runBootstrap() async {
        let statements = bootstrapReview
        bootstrapReview = []
        guard !statements.isEmpty else { return }
        newQuery(text: profile.bootstrapSQL ?? "")
        guard let tab = active else { return }
        tab.title = "Bootstrap SQL"
        await run(statements, on: tab)
        await reloadObjects()
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
            offeredBootstrap = false
            await reloadObjects()
            offerBootstrap()
            if let active, active.object != nil && active.changes.isEmpty { await load(active) }
        } catch { record(error) }
    }

    func switchDatabase(to name: String) async throws {
        guard !hasDrafts && !hasRunningTasks else { throw BrowserError("Finish pending changes and queries before switching databases.") }
        try await session.selectDatabase(name)
        clearDatabaseResults()
        database = name
        await reloadObjects()
        offerBootstrap()
    }

    func clearDatabaseResults() {
        tabs.removeAll { $0.object != nil }
        for tab in tabs { tab.result = QueryResult(); tab.executions = []; tab.error = nil; tab.selected = nil }
        if !tabs.contains(where: { $0.id == activeID }) { activeID = tabs.last?.id }
    }

    func saveActiveTab() {
        guard let tab = active else { return }
        if tab.object == nil {
            do { try saveSQL(tab) } catch { self.error = error.localizedDescription }
        } else if connected && !tab.changes.isEmpty {
            tab.previewShown = true
        }
    }

    @discardableResult func saveSQL(_ tab: WorkspaceTab, saveAs: Bool = false) throws -> Bool {
        guard tab.object == nil else { return false }
        var target = tab.fileURL
        if saveAs || target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.connectionSQL]; panel.nameFieldStringValue = tab.title + ".sql"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            target = url
        }
        guard let target else { return false }
        try tab.sql.write(to: target, atomically: true, encoding: .utf8)
        tab.fileURL = target; tab.savedSQL = tab.sql; tab.title = target.lastPathComponent
        tab.draftSave?.cancel(); notebook.removeDraft(tab.id)
        return true
    }

    func closeTab(_ tab: WorkspaceTab) {
        guard !tab.busy else { return }
        tab.draftSave?.cancel(); notebook.removeDraft(tab.id); notebook.releaseDraft(tab.id)
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
            let closeAfterCommit = tab.closeAfterCommit
            tab.discard(); tab.previewShown = false
            if closeAfterCommit {
                tab.busy = false; closeTab(tab)
            } else { await load(tab) }
        } catch { tab.commitError = error.localizedDescription; record(error) }
        tab.busy = false
    }

    func newQuery(text: String = "", file: URL? = nil) {
        let tab = WorkspaceTab(title: file?.lastPathComponent ?? "Query \(nextQueryNumber)")
        nextQueryNumber += 1
        tab.sql = text; tab.savedSQL = text; tab.fileURL = file
        notebook.openDraft(tab.id)
        tabs.append(tab); activeID = tab.id
    }
    func applyFilters(_ tab: WorkspaceTab) async {
        tab.appliedFilters = tab.filters; tab.offset = 0
        await load(tab)
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
        for (index, sql) in statements.enumerated() {
            if cancellation.wasRequested { break }
            guard connected else { tab.error = "This workspace is disconnected."; return }
            let start = Date()
            var results = [QueryResult()]
            var failure: String?
            do {
                let outcome = try await session.runUserSQL(sql, on: database, cancellation: cancellation, limit: BrowserPreferences.queryLimit)
                if let changed = outcome.changedDatabase {
                    let accept = !hasDrafts && !transferBusy && !maintenanceBusy && !tabs.contains { $0.id != tab.id && $0.busy }
                    // DatabaseSession holds subsequent database work until this
                    // workspace has reconciled the contents of its object tabs.
                    if accept { clearDatabaseResults(); database = changed }
                    try await session.finishDatabaseChange(to: changed, accept: accept)
                    await reloadObjects()
                }
                results = outcome.results
            } catch { failure = error.localizedDescription; if (error as? BrowserError)?.disconnected == true { record(error) } }
            let duration = Date().timeIntervalSince(start)
            let hidden = QueryNotebook.containsCredentials(sql)
            log.append(hidden ? "Statement containing credentials" : sql)
            if let failure { log.append(hidden ? "Statement failed" : failure) }
            notebook.record(sql: sql, duration: duration, error: failure)
            for (part, result) in results.enumerated() {
                let title = "Statement " + String(index + 1) + (results.count > 1 ? " · Result " + String(part + 1) : "")
                tab.executions.append((title, sql, result, failure, duration))
            }
            tab.selectExecution(tab.executions.count - 1)
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
