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
    var caPath = ""
    var filePath = ""
    var rememberPassword = false

    var detail: String {
        if driver == .sqlite { return filePath }
        return [usesSocket ? socketPath : "\(host):\(port)", database].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ConnectionGroup: Identifiable, Codable {
    var id = UUID()
    var name: String
    var connections: [ConnectionProfile] = []
}

struct BrowserError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ProfilePassword {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.connectionbrowser.database",
         kSecAttrAccount as String: id.uuidString]
    }

    static func read(_ id: UUID) throws -> String {
        var request = query(id)
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

    static func write(_ password: String, for id: UUID) throws {
        let request = query(id)
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
    private let file: URL
    var directory: URL { file.deletingLastPathComponent() }

    init() {
        var directory = URL.applicationSupportDirectory.appending(path: "ConnectionBrowser")
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["CONNECTION_BROWSER_LIBRARY"] {
            directory = URL(filePath: override)
        }
        #endif
        file = directory.appending(path: "connections.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                groups = try JSONDecoder().decode([ConnectionGroup].self, from: Data(contentsOf: file))
            } else {
                groups = [ConnectionGroup(name: "Connections")]
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--sample-connections") {
                    groups = [
                        ConnectionGroup(name: "Catalog", connections: [
                            ConnectionProfile(name: "catalog@local", database: "catalog"),
                            ConnectionProfile(name: "catalog@stage", environment: "stage", database: "catalog_stage")
                        ]),
                        ConnectionGroup(name: "Warehouse", connections: [
                            ConnectionProfile(name: "warehouse@local", database: "warehouse")
                        ])
                    ]
                }
                #endif
            }
        } catch { loadError = "Could not load your connections. \(error.localizedDescription)" }
    }

    func update(_ change: (inout [ConnectionGroup]) throws -> Void) throws {
        if let loadError { throw BrowserError(loadError) }
        var next = groups
        try change(&next)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        groups = next
    }

    func save(_ profile: ConnectionProfile, in group: UUID, password: String) throws {
        let old = groups.flatMap(\.connections).first { $0.id == profile.id }
        let touchesKeychain = profile.rememberPassword || old?.rememberPassword == true
        let original = touchesKeychain ? try ProfilePassword.read(profile.id) : ""
        if touchesKeychain { try ProfilePassword.write(profile.rememberPassword ? password : "", for: profile.id) }
        do {
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
            if touchesKeychain { try ProfilePassword.write(original, for: profile.id) }
            throw error
        }
    }
}
