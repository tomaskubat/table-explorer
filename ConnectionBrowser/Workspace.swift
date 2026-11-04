import Foundation
import Observation

@MainActor @Observable
final class WorkspaceTab: Identifiable {
    let id = UUID()
    var title: String
    let object: DatabaseObject?
    var sql = ""
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
    let session: DatabaseSession
    let database: String
    var objects: [DatabaseObject] = []
    var tabs: [WorkspaceTab] = []
    var activeID: UUID?
    var active: WorkspaceTab? { tabs.first { $0.id == activeID } }
    var log: [String] = []
    var error: String?
    var connected = true

    init(profile: ConnectionProfile, session: DatabaseSession, database: String) {
        self.profile = profile; self.session = session; self.database = database
    }

    func reloadObjects() async {
        do {
            objects = try await session.objects()
            error = nil
        } catch { self.error = error.localizedDescription }
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
        } catch { tab.commitError = error.localizedDescription }
        tab.busy = false
    }

    func newQuery() {
        let tab = WorkspaceTab(title: "Query \(tabs.filter { $0.object == nil }.count + 1)")
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
            tab.error = error.localizedDescription; log.append(error.localizedDescription)
        }
    }
    func execute(_ sql: String, on tab: WorkspaceTab) async {
        guard connected, !tab.busy else { return }
        tab.busy = true; tab.error = nil
        defer { tab.busy = false }
        log.append(sql)
        do {
            tab.result = try await session.query(sql, limit: tab.object == nil ? 1000 : tab.limit)
            tab.selected = nil
        } catch { tab.error = error.localizedDescription; log.append(error.localizedDescription) }
    }
}

@MainActor @Observable
final class WorkspaceRegistry {
    var sessions: [UUID: Workspace] = [:]
}
