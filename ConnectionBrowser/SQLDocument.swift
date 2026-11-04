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
    private struct Archive: Codable { var history: [QueryRecord] = []; var favorites: [FavoriteQuery] = [] }
    private var archive = Archive()
    private let file: URL
    private(set) var error: String?
    private var readable = true
    var history: [QueryRecord] { archive.history }
    var favorites: [FavoriteQuery] { archive.favorites }

    init(directory: URL, profile: UUID) {
        file = directory.appending(path: "Queries").appending(path: profile.uuidString + ".json")
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
    func add(_ favorite: FavoriteQuery) { archive.favorites.append(favorite); persist() }
    func removeFavorite(_ id: UUID) { archive.favorites.removeAll { $0.id == id }; persist() }
    private func persist() {
        guard readable else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(archive).write(to: file, options: .atomic)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
