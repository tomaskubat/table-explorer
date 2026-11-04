import Foundation
import Security
import Observation

enum DatabaseDriver: String, Codable, CaseIterable {
    case mariaDB = "MariaDB"
    case sqlite = "SQLite"
}

struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var driver = DatabaseDriver.mariaDB
    var environment = "local"
    var host = "127.0.0.1"
    var port = "3306"
    var user = ""
    var database = ""
    var socketPath = ""
    var usesSocket = false
    var verifyTLS = true
    var preferTLS: Bool? // Optional for profiles saved before preferred TLS was supported.
    var usesPreferredTLS: Bool { !verifyTLS && preferTLS == true }
    var caPath = ""
    var filePath = ""
    var rememberPassword = false
    var rememberOpenTabs: Bool?
    var remembersWorkspace: Bool {
        get { rememberOpenTabs ?? true }
        set { rememberOpenTabs = newValue }
    }
    var ssh: SSHSettings?
    var bootstrapSQL: String?
    var tagColor: String?

    var detail: String {
        if driver == .sqlite { return filePath }
        let address = ssh != nil ? "SSH" : usesSocket ? socketPath : host + (port == "3306" ? "" : ":" + port)
        return [address, database].filter { !$0.isEmpty }.joined(separator: " : ")
    }
}

struct ConnectionGroup: Identifiable, Codable {
    var id = UUID()
    var name: String
    var connections: [ConnectionProfile] = []
    var icon: String?
}

struct BrowserError: LocalizedError {
    var message: String
    var disconnected: Bool
    init(_ message: String, disconnected: Bool = false) { self.message = message; self.disconnected = disconnected }
    static func maria(_ code: UInt32, _ detail: String) -> Self {
        BrowserError("MariaDB \(code): \(detail)", disconnected: [1927, 2006, 2013, 2055].contains(code))
    }
    var errorDescription: String? { message }
}

enum ProfilePassword {
    private static func query(_ id: UUID, ssh: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: ssh ? "local.connectionbrowser.ssh" : "local.connectionbrowser.database",
         kSecAttrAccount as String: id.uuidString]
    }

    static func read(_ id: UUID, ssh: Bool = false) throws -> String {
        var request = query(id, ssh: ssh)
        request[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw BrowserError("Could not read the database password from Keychain (\(status)).")
        }
        return password
    }

    static func write(_ password: String, for id: UUID, ssh: Bool = false) throws {
        let request = query(id, ssh: ssh)
        let status: OSStatus
        if password.isEmpty {
            status = SecItemDelete(request as CFDictionary)
            if status == errSecItemNotFound { return }
        } else {
            let values = [kSecValueData as String: Data(password.utf8)]
            let update = SecItemUpdate(request as CFDictionary, values as CFDictionary)
            if update == errSecItemNotFound {
                var new = request.merging(values) { _, latest in latest }
                new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(new as CFDictionary, nil)
            } else { status = update }
        }
        guard status == errSecSuccess else { throw BrowserError("Could not update the database password in Keychain (\(status)).") }
    }
}

@MainActor @Observable
final class ConnectionLibrary {
    private(set) var groups: [ConnectionGroup] = []
    var loadError: String?
    private var file: URL
    var directory: URL { file.deletingLastPathComponent() }

    nonisolated static func defaultDirectory(in support: URL = .applicationSupportDirectory) -> URL {
        let current = support.appending(path: "TableExplorer", directoryHint: .isDirectory)
        let legacy = support.appending(path: "ConnectionBrowser", directoryHint: .isDirectory)
        // Existing installations keep their profiles, SQL history and drafts together.
        if !FileManager.default.fileExists(atPath: current.path), FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return current
    }

    init() {
        var directory = BrowserPreferences.defaults.string(forKey: "libraryDirectory").map { URL(filePath: $0) }
            ?? Self.defaultDirectory()
        if let override = ProcessInfo.processInfo.environment["CONNECTION_BROWSER_LIBRARY"], override.hasPrefix("/") {
            directory = URL(filePath: override)
        }
        file = directory.appending(path: "connections.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                groups = try JSONDecoder().decode([ConnectionGroup].self, from: Data(contentsOf: file))
            } else {
                groups = [ConnectionGroup(name: "Connections")]
            }
        } catch { loadError = "Could not load your connections. \(error.localizedDescription)" }
    }

    func useDirectory(_ folder: URL) throws {
        let next = folder.appending(path: "connections.json")
        let loaded: [ConnectionGroup]
        if FileManager.default.fileExists(atPath: next.path) {
            loaded = try JSONDecoder().decode([ConnectionGroup].self, from: Data(contentsOf: next))
        } else {
            loaded = [ConnectionGroup(name: "Connections")]
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(loaded).write(to: next, options: .withoutOverwriting)
        }
        file = next; groups = loaded; loadError = nil
        BrowserPreferences.defaults.set(folder.path, forKey: "libraryDirectory")
    }

    func update(_ change: (inout [ConnectionGroup]) throws -> Void) throws {
        if let loadError { throw BrowserError(loadError) }
        var next = groups
        try change(&next)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        groups = next
    }

    func move(_ profileID: UUID, to groupID: UUID) throws {
        try update { groups in
            guard let to = groups.firstIndex(where: { $0.id == groupID }),
                  let from = groups.firstIndex(where: { $0.connections.contains { $0.id == profileID } }),
                  let row = groups[from].connections.firstIndex(where: { $0.id == profileID }) else {
                throw BrowserError("The connection or destination group is no longer in the library.")
            }
            guard from != to else { return }
            let profile = groups[from].connections.remove(at: row)
            groups[to].connections.append(profile)
        }
    }

    func sortConnections(in groupID: UUID, by key: ProfileSort) throws {
        try update { groups in
            guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[index].connections.sort { lhs, rhs in
                let order = key.value(lhs).localizedStandardCompare(key.value(rhs))
                return order == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : order == .orderedAscending
            }
        }
    }

    func save(_ profile: ConnectionProfile, in group: UUID, password: String, sshPassword: String = "") throws {
        if let script = profile.bootstrapSQL, QueryNotebook.containsCredentials(script) {
            throw BrowserError("Remove credential statements from the bootstrap script before saving the profile.")
        }
        let old = groups.flatMap(\.connections).first { $0.id == profile.id }
        let touchesKeychain = profile.rememberPassword || old?.rememberPassword == true
        let original = touchesKeychain ? try ProfilePassword.read(profile.id) : ""
        let touchesSSH = profile.ssh?.rememberSecret == true || old?.ssh?.rememberSecret == true
        let originalSSH = touchesSSH ? try ProfilePassword.read(profile.id, ssh: true) : ""
        do {
            if touchesKeychain { try ProfilePassword.write(profile.rememberPassword ? password : "", for: profile.id) }
            if touchesSSH { try ProfilePassword.write(profile.ssh?.rememberSecret == true ? sshPassword : "", for: profile.id, ssh: true) }
            try update { groups in
                guard let destination = groups.firstIndex(where: { $0.id == group }) else { throw BrowserError("Choose a connection group.") }
                if let row = groups[destination].connections.firstIndex(where: { $0.id == profile.id }) {
                    groups[destination].connections[row] = profile
                } else {
                    for index in groups.indices { groups[index].connections.removeAll { $0.id == profile.id } }
                    groups[destination].connections.append(profile)
                }
            }
        } catch {
            if touchesSSH { try ProfilePassword.write(originalSSH, for: profile.id, ssh: true) }
            if touchesKeychain { try ProfilePassword.write(original, for: profile.id) }
            throw error
        }
        if !profile.remembersWorkspace {
            try WorkspaceStateFile(directory: directory, profile: profile.id).clear()
        }
    }
}
