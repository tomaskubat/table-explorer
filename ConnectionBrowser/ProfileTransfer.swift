import Foundation

enum ProfileAddress {
    static func parse(_ input: String) throws -> (ConnectionProfile, String) {
        guard let parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased() else { throw BrowserError("Enter a MariaDB or SQLite connection URL.") }
        var profile = ConnectionProfile()
        let options = parts.queryItems ?? []
        func option(_ name: String) -> String? { options.first { $0.name == name }?.value }
        switch scheme {
        case "mysql", "mariadb":
            guard let host = parts.host, !host.isEmpty else { throw BrowserError("The URL needs a database host.") }
            profile.host = host
            let port = parts.port ?? 3306
            guard (1...65535).contains(port) else { throw BrowserError("The URL contains an invalid port.") }
            profile.port = String(port); profile.user = parts.user ?? ""
            profile.database = String(parts.path.drop(while: { $0 == "/" }))
            profile.socketPath = option("socket") ?? ""; profile.usesSocket = !profile.socketPath.isEmpty
            profile.verifyTLS = option("tls") != "disabled"
            profile.name = option("name") ?? (profile.user.isEmpty ? host : profile.user + "@" + host)
        case "sqlite", "file":
            guard parts.host == nil || parts.host == "" || parts.host == "localhost", parts.path.hasPrefix("/") else {
                throw BrowserError("Use an absolute path to a local SQLite file.")
            }
            profile.driver = .sqlite; profile.filePath = parts.path
            profile.name = option("name") ?? URL(filePath: parts.path).deletingPathExtension().lastPathComponent
        default: throw BrowserError("This driver is not supported. Choose MariaDB or SQLite.")
        }
        return (profile, parts.password ?? "")
    }

    static func url(_ profile: ConnectionProfile) -> URL? {
        var parts = URLComponents()
        if profile.driver == .sqlite {
            parts.scheme = "sqlite"; parts.host = ""; parts.path = profile.filePath
        } else {
            parts.scheme = "mariadb"; parts.host = profile.usesSocket ? "localhost" : profile.host
            parts.user = profile.user.isEmpty ? nil : profile.user
            parts.port = profile.usesSocket ? nil : Int(profile.port)
            parts.path = "/" + profile.database
            var items: [URLQueryItem] = []
            if profile.usesSocket { items.append(URLQueryItem(name: "socket", value: profile.socketPath)) }
            if !profile.verifyTLS { items.append(URLQueryItem(name: "tls", value: "disabled")) }
            if !items.isEmpty { parts.queryItems = items }
        }
        return parts.url
    }
}

private struct ProfileArchive: Codable {
    var version = 1
    var groups: [ConnectionGroup]
}

extension ConnectionLibrary {
    func exportGroups(_ exported: [ConnectionGroup], to file: URL) throws {
        var copies = exported
        for i in copies.indices {
            for j in copies[i].connections.indices { copies[i].connections[j].rememberPassword = false }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ProfileArchive(groups: copies)).write(to: file, options: .atomic)
    }

    func importGroups(from file: URL) throws {
        let archive = try JSONDecoder().decode(ProfileArchive.self, from: Data(contentsOf: file))
        guard archive.version == 1 else { throw BrowserError("Unsupported connection archive version.") }
        try update { groups in
            for source in archive.groups {
                guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrowserError("The archive contains an unnamed group.") }
                let profiles = try source.connections.map { input in
                    guard !input.name.isEmpty, input.driver == .sqlite ? input.filePath.hasPrefix("/") : (input.usesSocket ? !input.socketPath.isEmpty : UInt16(input.port).map { $0 > 0 } == true) else {
                        throw BrowserError("The archive contains an invalid connection profile.")
                    }
                    var copy = input; copy.id = UUID(); copy.rememberPassword = false
                    return copy
                }
                groups.append(ConnectionGroup(name: source.name, connections: profiles))
            }
        }
    }
}
