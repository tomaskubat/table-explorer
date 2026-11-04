import Foundation

enum SQLiteFixture {
    static func create(at url: URL) throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let input = try FileHandle(forReadingFrom: root.appending(path: "Tests/Fixtures/SQLite/seed.sql"))
        defer { try? input.close() }

        let sqlite = Process()
        sqlite.executableURL = URL(filePath: "/usr/bin/sqlite3")
        sqlite.arguments = ["-batch", "-bail", url.path]
        sqlite.standardInput = input
        try sqlite.run()
        sqlite.waitUntilExit()
        guard sqlite.terminationStatus == 0 else {
            throw NSError(domain: "SQLiteFixture", code: Int(sqlite.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create test database at \(url.path)"])
        }
    }
}
