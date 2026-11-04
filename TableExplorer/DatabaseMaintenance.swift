import Foundation
import SQLite3

enum MaintenanceAction: String, Identifiable { case backup = "Backup", restore = "Restore"; var id: Self { self } }

struct NativeDatabaseTool: Sendable {
    let path: String
    let version: String
    var maria: Bool { version.localizedCaseInsensitiveContains("MariaDB") }

    static func discover(_ action: MaintenanceAction, chosen: String) throws -> Self {
        let names = action == .backup ? ["mariadb-dump", "mysqldump"] : ["mariadb", "mysql"]
        let directories = ["/opt/homebrew/bin", "/opt/homebrew/opt/mariadb/bin", "/opt/homebrew/opt/mysql-client/bin", "/opt/homebrew/opt/mysql-client@8.4/bin", "/usr/local/bin"]
        let candidates = chosen.isEmpty ? directories.flatMap { dir in names.map { dir + "/" + $0 } } : [chosen]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw BrowserError("Choose a native \(names.joined(separator: " or ")) executable for this operation.")
        }
        let tool = URL(filePath: path).resolvingSymlinksInPath()
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/arch")
        process.arguments = ["-arm64", tool.path, "--no-defaults", "--version"]
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let version = String(decoding: data.prefix(2048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw BrowserError("Could not run this tool natively on Apple Silicon. " + version) }
        return Self(path: tool.path, version: version)
    }
}

struct MaintenanceRequest: Sendable {
    let action: MaintenanceAction
    let file: URL
    let database: String
    let tool: NativeDatabaseTool?
    var gzip = false
    var schemaOnly = false
    var routines = false
    var events = false
    var overwrite = false

    var arguments: [String] {
        if action == .restore { return ["--binary-mode", "--local-infile=0", "--skip-reconnect", "--", database] }
        var args = ["--single-transaction", "--quick", "--hex-blob", "--triggers"]
        if tool?.maria == false { args += ["--column-statistics=0", "--no-tablespaces", "--set-gtid-purged=OFF"] }
        if schemaOnly { args.append("--no-data") }
        if routines { args.append("--routines") }
        if events { args.append("--events") }
        return args + ["--", database]
    }
}

final class MaintenanceJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { _ = kill(process.processIdentifier, SIGTERM) }
        }
    }
    func run(_ executable: String, _ args: [String], input: FileHandle, output: FileHandle, diagnostics: URL) throws {
        let task = Process()
        task.executableURL = URL(filePath: executable); task.arguments = args
        task.standardInput = input; task.standardOutput = output
        let errors = try FileHandle(forWritingTo: diagnostics)
        defer { try? errors.close() }
        try errors.truncate(atOffset: 0); task.standardError = errors
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try task.run(); process = task
        }
        task.waitUntilExit()
        lock.withLock { process = nil }
        try check()
        if task.terminationStatus != 0 {
            let reader = try FileHandle(forReadingFrom: diagnostics)
            defer { try? reader.close() }
            let size = try reader.seekToEnd(); try reader.seek(toOffset: size > 4096 ? size - 4096 : 0)
            let message = String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self)
            throw BrowserError("Tool exited with status \(task.terminationStatus). " + message)
        }
    }
}

enum DatabaseMaintenance {
    static func perform(_ request: MaintenanceRequest, job: MaintenanceJob, sqlite: SQLiteHandle?, endpoint: (ConnectionProfile, String)?) throws -> String {
        try job.check()
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "db-maintenance-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let log = work.appending(path: "diagnostics")
        try create(log)
        let staged = request.file.deletingLastPathComponent().appending(path: "." + UUID().uuidString + ".partial")
        defer { if request.action == .backup { try? fm.removeItem(at: staged) } }
        let raw = work.appending(path: "snapshot")
        let compressed = request.action == .backup ? request.gzip : try isGzip(request.file)
        let snapshot = compressed ? raw : (request.action == .backup ? staged : request.file)
        if request.action == .restore && compressed {
            try create(raw)
            try transformGzip(job, source: request.file, into: raw, decompress: true, diagnostics: log)
        }
        if request.action == .backup { try create(snapshot) }

        if let sqlite {
            try sqliteSnapshot(request.action, source: sqlite, file: snapshot, job: job)
        } else if let (profile, password) = endpoint, let tool = request.tool {
            // The owner-only option file is removed with the operation directory.
            // No password appears in argv, the environment, or the command preview.
            let optionFile = work.appending(path: "client.cnf")
            let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t")
            try create(optionFile, data: Data(("[client]\npassword=\"" + escaped + "\"\n").utf8))
            var args = ["-arm64", tool.path, "--defaults-file=" + optionFile.path, "--user=" + profile.user, "--default-character-set=utf8mb4"]
            if profile.usesSocket { args += ["--protocol=SOCKET", "--socket=" + profile.socketPath] }
            else { args += ["--protocol=TCP", "--host=" + profile.host, "--port=" + profile.port] }
            if profile.verifyTLS, let ssh = profile.ssh {
                guard tool.maria else { throw BrowserError("Choose a MariaDB tool with --ssl-fp support for certificate-pinned SSH connections.") }
                args += ["--ssl", "--ssl-fp=" + ssh.databaseFingerprint]
            } else if profile.verifyTLS {
                args += tool.maria ? ["--ssl", "--ssl-verify-server-cert"] : ["--ssl-mode=VERIFY_IDENTITY"]
                args += ["--ssl-ca=" + (profile.caPath.isEmpty ? "/etc/ssl/cert.pem" : profile.caPath)]
            } else { args.append(tool.maria ? "--skip-ssl" : "--ssl-mode=DISABLED") }
            let handle = try request.action == .backup ? FileHandle(forWritingTo: snapshot) : FileHandle(forReadingFrom: snapshot)
            defer { try? handle.close() }
            do {
                try job.run("/usr/bin/arch", args + request.arguments,
                            input: request.action == .backup ? .nullDevice : handle,
                            output: request.action == .backup ? handle : .nullDevice, diagnostics: log)
            } catch {
                let detail = password.isEmpty ? error.localizedDescription : error.localizedDescription.replacingOccurrences(of: password, with: "••••")
                throw BrowserError(detail + (request.action == .restore ? "\nEarlier statements may already have committed." : ""))
            }
            if request.action == .backup { try handle.synchronize() }
        } else { throw BrowserError("A connected database is required.") }

        if request.action == .backup {
            if compressed {
                try create(staged)
                try transformGzip(job, source: raw, into: staged, decompress: false, diagnostics: log)
            }
            try job.check()
            if request.overwrite && fm.fileExists(atPath: request.file.path) {
                _ = try fm.replaceItemAt(request.file, withItemAt: staged)
            } else { try fm.moveItem(at: staged, to: request.file) }
        }
        return "\(request.action.rawValue) completed for \(request.database)."
    }

    private static func create(_ file: URL, data: Data = Data()) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw BrowserError("Could not create \(file.lastPathComponent).")
        }
    }
    private static func isGzip(_ file: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        return try input.read(upToCount: 2) == Data([0x1f, 0x8b])
    }
    private static func transformGzip(_ job: MaintenanceJob, source: URL, into target: URL, decompress: Bool, diagnostics: URL) throws {
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: target)
        defer { try? input.close(); try? output.close() }
        try job.run("/usr/bin/gzip", decompress ? ["-dc"] : ["-c"], input: input, output: output, diagnostics: diagnostics)
        try output.synchronize()
    }

    private static func sqliteSnapshot(_ action: MaintenanceAction, source: SQLiteHandle, file: URL, job: MaintenanceJob) throws {
        var other: OpaquePointer?
        let flags = action == .backup ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(file.path, &other, flags, nil) == SQLITE_OK, let other else {
            let detail = other.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open SQLite file."
            sqlite3_close(other); throw BrowserError(detail)
        }
        defer { sqlite3_close(other) }
        if action == .restore {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            guard try input.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else { throw BrowserError("The source is not a SQLite backup.") }
            var check: OpaquePointer?
            guard sqlite3_prepare_v2(other, "PRAGMA quick_check(1)", -1, &check, nil) == SQLITE_OK else { throw BrowserError(String(cString: sqlite3_errmsg(other))) }
            defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, let text = sqlite3_column_text(check, 0), String(cString: text) == "ok" else {
                throw BrowserError("The backup failed SQLite's integrity check.")
            }
        }
        let dest = action == .backup ? other : source.database
        let input = action == .backup ? source.database : other
        guard let backup = sqlite3_backup_init(dest, "main", input, "main") else { throw BrowserError(String(cString: sqlite3_errmsg(dest))) }
        var status: Int32 = SQLITE_OK
        var blockedSince: Date?
        repeat {
            do { try job.check() } catch { sqlite3_backup_finish(backup); throw error }
            status = sqlite3_backup_step(backup, 256)
            if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                if blockedSince == nil { blockedSince = Date() }
                if Date().timeIntervalSince(blockedSince!) > 5 { break }
                sqlite3_sleep(40)
            } else { blockedSince = nil }
        } while status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED
        let finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE && finish == SQLITE_OK else { throw BrowserError("SQLite backup: " + String(cString: sqlite3_errstr(status == SQLITE_DONE ? finish : status))) }
    }
}
