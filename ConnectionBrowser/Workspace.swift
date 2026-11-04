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
