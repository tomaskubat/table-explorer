import Foundation
import SQLite3
import Observation

enum SQLScope { case current, selection, script }

enum SQLDocument {
    static func statements(in text: String, driver: DatabaseDriver) -> [(range: NSRange, sql: String)] {
        let source = text as NSString
        var result: [(NSRange, String)] = []
        var i = 0, start = 0
        var quote: unichar = 0
        var lineComment = false, blockComment = false, hasToken = false
        var delimiter = ";"
        func character(_ index: Int) -> unichar { index < source.length ? source.character(at: index) : 0 }
        func emit(_ end: Int) {
            guard hasToken, end > start else { return }
            let range = NSRange(location: start, length: end - start)
            result.append((range, source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        while i < source.length {
            let ch = character(i), next = character(i + 1)
            if lineComment { if ch == 10 || ch == 13 { lineComment = false }; i += 1; continue }
            if blockComment {
                if ch == 42 && next == 47 { blockComment = false; i += 2 } else { i += 1 }
                continue
            }
            if quote != 0 {
                if ch == 92 && driver == .mariaDB { i = min(i + 2, source.length); continue }
                if ch == quote {
                    if next == quote { i += 2; continue }
                    quote = 0
                }
                i += 1; continue
            }
            if driver == .mariaDB && !hasToken && (i == 0 || character(i - 1) == 10),
               i + 10 <= source.length, source.substring(with: NSRange(location: i, length: 10)).uppercased() == "DELIMITER " {
                let range = source.lineRange(for: NSRange(location: i, length: 0))
                let line = source.substring(with: range)
                let new = line.dropFirst(10).trimmingCharacters(in: .whitespacesAndNewlines)
                if !new.isEmpty {
                    delimiter = new; i = NSMaxRange(range); start = i; continue
                }
            }
            if ch == 45 && next == 45 && (driver == .sqlite || character(i + 2) <= 32) || (ch == 35 && driver == .mariaDB) {
                lineComment = true; i += 1; continue
            }
            if ch == 47 && next == 42 {
                if driver == .mariaDB && character(i + 2) == 33 { hasToken = true }
                blockComment = true; i += 2; continue
            }
            if ch == 39 || ch == 34 || ch == 96 || (ch == 91 && driver == .sqlite) {
                quote = ch == 91 ? 93 : ch; hasToken = true; i += 1; continue
            }
            let length = delimiter.utf16.count
            if i + length <= source.length && source.substring(with: NSRange(location: i, length: length)) == delimiter {
                if driver == .sqlite && hasToken && sqlite3_complete(source.substring(with: NSRange(location: start, length: i + 1 - start))) == 0 {
                    i += 1; continue
                }
                emit(delimiter == ";" ? i + length : i); i += length; start = i; hasToken = false; continue
            }
            if ch > 32 { hasToken = true }
            i += 1
        }
        emit(source.length)
        return result
    }

    static func commands(text: String, selection: NSRange, scope: SQLScope, driver: DatabaseDriver) -> [String] {
        let source = text as NSString
        if scope == .selection {
            guard selection.length > 0, NSMaxRange(selection) <= source.length else { return [] }
            return statements(in: source.substring(with: selection), driver: driver).map(\.sql)
        }
        let parts = statements(in: text, driver: driver)
        if scope == .script { return parts.map(\.sql) }
        let current = parts.first { selection.location <= NSMaxRange($0.range) } ?? parts.last
        return current.map { [$0.sql] } ?? []
    }

    @MainActor static func toggleBlockComment(in tab: WorkspaceTab) {
        let source = tab.sql as NSString
        let selected = NSIntersectionRange(tab.textSelection, NSRange(location: 0, length: source.length))
        let range = selected.length > 0 ? selected : source.lineRange(for: selected)
        let fragment = source.substring(with: range)
        let changed = fragment.hasPrefix("/*") && fragment.hasSuffix("*/") && fragment.count >= 4
            ? String(fragment.dropFirst(2).dropLast(2)) : "/*" + fragment + "*/"
        tab.sql = source.replacingCharacters(in: range, with: changed)
        tab.textSelection = NSRange(location: range.location, length: changed.utf16.count)
    }

    @MainActor static func toggleComment(in tab: WorkspaceTab) {
        let source = tab.sql as NSString
        let selection = tab.textSelection
        let start = min(source.length, selection.location)
        let extent = min(max(0, selection.length - 1), source.length - start)
        let range = source.lineRange(for: NSRange(location: start, length: extent))
        let segment = source.substring(with: range)
        let newline = segment.hasSuffix("\n")
        let body = newline ? String(segment.dropLast()) : segment
        let lines = body.components(separatedBy: "\n")
        let uncomment = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let changed = lines.map { line in
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let content = line.dropFirst(indent.count)
            if uncomment { return String(indent) + (content.hasPrefix("-- ") ? String(content.dropFirst(3)) : String(content.dropFirst(2))) }
            return String(indent) + "-- " + content
        }.joined(separator: "\n") + (newline ? "\n" : "")
        tab.sql = source.replacingCharacters(in: range, with: changed)
        tab.textSelection = NSRange(location: range.location, length: changed.utf16.count)
    }

    static func requiresConfirmation(_ sql: String) -> Bool {
        // Only trivially read-only statements bypass the direct-SQL prompt.
        // Compound scripts are checked statement by statement before any run.
        let upper = sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").uppercased()
        let token = upper.prefix { $0.isLetter }
        return !["SELECT", "SHOW", "EXPLAIN", "DESCRIBE"].contains(String(token))
            || upper.contains(" INTO ") || upper.contains("FOR UPDATE") || upper.contains("/*!")
    }
}

struct QueryRecord: Identifiable, Codable {
    let id: UUID
    let sql: String
    let date: Date
    let duration: TimeInterval
    let error: String?
}

struct FavoriteQuery: Identifiable, Codable {
    var id = UUID()
    var name: String
    var sql: String
    var keywords: String
}

@MainActor @Observable
final class QueryNotebook {
    private struct Archive: Codable {
        var history: [QueryRecord] = []
        var favorites: [FavoriteQuery] = []
        var pins: [String: [String]]?
        var panels: PanelLayout?
        var drafts: [String: RecoverableSQL]?
    }
    private var openDrafts: Set<UUID> = []
    func restoredTabID(_ id: UUID) -> UUID { openDrafts.contains(id) ? UUID() : id }
    let libraryDirectory: URL
    let workspaceState: WorkspaceStateFile
    var panels: PanelLayout { archive.panels ?? PanelLayout() }
    func saveLayout(_ layout: PanelLayout) {
        guard panels != layout else { return }
        archive.panels = layout; persist()
    }
    func openDraft(_ id: UUID) { openDrafts.insert(id) }
    func releaseDraft(_ id: UUID) { openDrafts.remove(id) }
    func availableDrafts(in database: String) -> [RecoverableSQL] {
        (archive.drafts ?? [:]).values.filter { $0.database == database && !openDrafts.contains($0.id) }.sorted { $0.date > $1.date }
    }
    func saveDraft(_ draft: RecoverableSQL) {
        var drafts = archive.drafts ?? [:]
        if let old = drafts[draft.id.uuidString], old.sql == draft.sql && old.title == draft.title && old.database == draft.database { return }
        drafts[draft.id.uuidString] = draft
        archive.drafts = drafts; persist()
    }
    func removeDraft(_ id: UUID) {
        guard archive.drafts?[id.uuidString] != nil else { return }
        archive.drafts?.removeValue(forKey: id.uuidString); persist()
    }
    private var archive = Archive()
    private let file: URL
    private(set) var error: String?
    private var readable = true
    var history: [QueryRecord] { archive.history }
    var favorites: [FavoriteQuery] { archive.favorites }

    init(directory: URL, profile: UUID) {
        libraryDirectory = directory
        workspaceState = WorkspaceStateFile(directory: directory, profile: profile)
        file = BrowserPreferences.folder("queryDirectory", fallback: directory).appending(path: "Queries").appending(path: profile.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file)) }
            catch { self.error = error.localizedDescription; readable = false }
        }
    }
    static func containsCredentials(_ sql: String) -> Bool {
        let upper = sql.uppercased()
        return upper.contains("IDENTIFIED") || upper.contains("PASSWORD")
    }
    func record(sql: String, duration: TimeInterval, error: String?) {
        if Self.containsCredentials(sql) { return }
        archive.history.insert(QueryRecord(id: UUID(), sql: sql, date: Date(), duration: duration, error: error), at: 0)
        if archive.history.count > 500 { archive.history.removeLast(archive.history.count - 500) }
        persist()
    }
    func isPinned(_ object: DatabaseObject, database: String) -> Bool {
        archive.pins?[database]?.contains(object.kind.rawValue + "/" + object.name) == true
    }
    func togglePin(_ object: DatabaseObject, database: String) {
        let id = object.kind.rawValue + "/" + object.name
        var pins = archive.pins ?? [:], names = pins[database] ?? []
        if names.contains(id) { names.removeAll { $0 == id } } else { names.append(id) }
        pins[database] = names; archive.pins = pins; persist()
    }
    func add(_ favorite: FavoriteQuery) { archive.favorites.append(favorite); persist() }
    func removeFavorite(_ id: UUID) { archive.favorites.removeAll { $0.id == id }; persist() }
    private func persist() {
        guard readable else { return }
        do {
            let fm = FileManager.default
            let directory = file.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temporary = directory.appending(path: "." + UUID().uuidString + ".partial")
            defer { try? fm.removeItem(at: temporary) }
            guard fm.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(archive), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            if fm.fileExists(atPath: file.path) { _ = try fm.replaceItemAt(file, withItemAt: temporary) }
            else { try fm.moveItem(at: temporary, to: file) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
