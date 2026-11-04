import Foundation

/// Only the information needed to reopen a workspace. Query results, staged row
/// changes and authentication data never belong in this file.
struct RememberedWorkspace: Codable {
    var initialDatabase: String
    var database: String
    var tabs: [RememberedTab]
    var active: UUID?
    var panels: PanelLayout
    var consoleHeight: CGFloat
    var navigator: String
}

struct RememberedTab: Codable {
    var id: UUID
    var title: String
    var object: DatabaseObject?
    var sql: String?
    var savedSQL: String?
    var fileURL: URL?
    var textSelection: NSRange?
    var structure: Bool
    var section: String
    var limit: Int
    var offset: Int
    var filters: [ColumnFilter]
    var applied: [ColumnFilter]
    var filterEditor: Bool
    var hidden: Set<String>
    var sort: String?
    var descending: Bool
    var widths: [String: CGFloat]

    @MainActor init(_ tab: WorkspaceTab) {
        id = tab.id; title = tab.title; object = tab.object
        if object == nil, !QueryNotebook.containsCredentials(tab.sql), !QueryNotebook.containsCredentials(tab.savedSQL) {
            sql = tab.sql
            if tab.unsavedSQL { savedSQL = tab.savedSQL }
            fileURL = tab.fileURL
            textSelection = tab.textSelection
        }
        structure = tab.showStructure; section = tab.section
        limit = tab.limit; offset = tab.offset
        // Keep raw SQL editable, but never run a saved raw expression on reopen.
        filters = tab.filters.filter { !QueryNotebook.containsCredentials($0.column + " " + $0.value) }
        applied = tab.appliedFilters.filter { $0.operation != .raw && !QueryNotebook.containsCredentials($0.column + " " + $0.value) }
        filterEditor = tab.filterEditorVisible
        hidden = tab.hiddenColumns; sort = tab.sortColumn; descending = tab.descending
        widths = tab.gridWidths
        for column in tab.grid?.tableColumns ?? [] { widths[column.title] = column.width }
    }

    @MainActor func makeTab(id: UUID) -> WorkspaceTab {
        let tab = WorkspaceTab(id: id, title: title, object: object)
        tab.sql = sql ?? ""; tab.savedSQL = savedSQL ?? tab.sql
        if let fileURL, fileURL.isFileURL {
            if let current = try? String(contentsOf: fileURL, encoding: .utf8) {
                tab.fileURL = fileURL
                if savedSQL == nil { tab.sql = current; tab.savedSQL = current }
            } else { tab.savedSQL = "" } // A missing file can still be saved elsewhere.
        }
        if let textSelection {
            let count = tab.sql.utf16.count, start = min(count, max(0, textSelection.location))
            tab.textSelection = NSRange(location: start, length: min(count - start, max(0, textSelection.length)))
        }
        tab.showStructure = structure; tab.section = section
        tab.limit = min(10000, max(1, limit)); tab.offset = max(0, offset)
        tab.filters = filters; tab.appliedFilters = applied; tab.filterEditorVisible = filterEditor
        tab.hiddenColumns = hidden; tab.sortColumn = sort; tab.descending = descending
        tab.gridWidths = widths; tab.needsTableLoad = object != nil
        return tab
    }
}

struct WorkspaceStateFile {
    let url: URL
    init(directory: URL, profile: UUID) {
        url = directory.appending(path: "Workspaces").appending(path: profile.uuidString + ".json")
    }
    func read() throws -> RememberedWorkspace? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RememberedWorkspace.self, from: Data(contentsOf: url))
    }
    func write(_ state: RememberedWorkspace) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
