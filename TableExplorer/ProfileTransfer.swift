import Foundation

enum ProfileAddress {
    typealias Imported = (profile: ConnectionProfile, password: String, sshPassword: String)

    static func parse(_ input: String) throws -> Imported {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = address.firstIndex(of: ":") else { throw BrowserError("Enter a MariaDB or SQLite connection URL.") }
        let scheme = address[..<colon].lowercased()
        let parts: URLComponents
        var tunnel: SSHSettings?
        var sshPassword = ""
        if scheme == "mariadb+ssh" || scheme == "mysql+ssh" {
            (parts, tunnel, sshPassword) = try parseSSH(address[address.index(after: colon)...])
        } else {
            guard let parsed = URLComponents(string: address) else { throw BrowserError("Invalid connection URL.") }
            parts = parsed
        }
        var profile = ConnectionProfile()
        let options = parts.queryItems ?? []
        func option(_ name: String) -> String? { options.first { $0.name == name }?.value }
        switch scheme {
        case "mysql", "mariadb", "mysql+ssh", "mariadb+ssh":
            guard let host = parts.host, !host.isEmpty else { throw BrowserError("The URL needs a database host.") }
            profile.host = host
            profile.port = try port(in: parts) ?? "3306"
            profile.user = parts.user ?? ""
            profile.database = String(parts.percentEncodedPath.dropFirst()).removingPercentEncoding ?? ""
            profile.socketPath = option("socket") ?? ""; profile.usesSocket = !profile.socketPath.isEmpty
            if let mode = option("tls") {
                profile.verifyTLS = mode != "disabled" && mode != "preferred"
                profile.preferTLS = mode == "preferred"
            } else if option("tLSMode") == "0" {
                profile.verifyTLS = false; profile.preferTLS = true
            }
            if let env = option("enviroment") ?? option("environment") ?? option("env") { profile.environment = env }
            if let color = option("statusColor"), color.utf8.count == 6, UInt32(color, radix: 16) != nil {
                profile.tagColor = "#" + color.uppercased()
            }
            if ["safeModeLevel", "advancedSafeModeLevel"].contains(where: { option($0).map { $0 != "0" } == true }) {
                throw BrowserError("This URL requires TablePlus Safe Mode, which TableExplorer does not support.")
            }
            if let host = option("ssh-host"), tunnel == nil {
                var ssh = SSHSettings()
                ssh.host = host; ssh.port = option("ssh-port") ?? ""; ssh.user = option("ssh-user") ?? ""
                tunnel = ssh
            }
            if var ssh = tunnel {
                guard ssh.isValid else { throw BrowserError("Invalid SSH host, user, or port in the connection URL.") }
                ssh.databaseFingerprint = option("db-fingerprint") ?? ""
                if option("usePrivateKey") == "true" { ssh.keyOnly = true }
                profile.ssh = ssh
            }
            let displayHost = tunnel?.host ?? host
            profile.name = option("name") ?? (profile.user.isEmpty ? displayHost : profile.user + "@" + displayHost)
        case "sqlite", "file":
            guard parts.host == nil || parts.host == "" || parts.host == "localhost", parts.path.hasPrefix("/") else {
                throw BrowserError("Use an absolute path to a local SQLite file.")
            }
            profile.driver = .sqlite; profile.filePath = parts.path
            profile.name = option("name") ?? URL(filePath: parts.path).deletingPathExtension().lastPathComponent
        default: throw BrowserError("This driver is not supported. Choose MariaDB or SQLite.")
        }
        return (profile, parts.password ?? "", sshPassword)
    }

    private static func port(in parts: URLComponents) throws -> String? {
        guard parts.rangeOfPort != nil else { return nil }
        guard let value = parts.port, (1...65535).contains(value) else { throw BrowserError("The URL contains an invalid port.") }
        return String(value)
    }

    private static func parseSSH(_ address: Substring) throws -> (URLComponents, SSHSettings, String) {
        let invalid = BrowserError("Use ssh-user@ssh-host/db-user:password@db-host:port/database. URL-encode special characters in credentials.")
        guard address.hasPrefix("//"), !address.contains("#") else { throw invalid }
        // Split the two authorities before URL decoding: %40, %2F and %3A in
        // credentials are data, and brackets around an inner IPv6 host are syntax.
        let resource = address.dropFirst(2)
        let query = resource.firstIndex(of: "?") ?? resource.endIndex
        let endpoints = resource[..<query]
        guard let slash = endpoints.firstIndex(of: "/"),
              let server = URLComponents(string: "ssh://" + endpoints[..<slash], encodingInvalidCharacters: false),
              let host = server.host, !host.isEmpty else { throw invalid }
        var ssh = SSHSettings()
        ssh.host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        ssh.port = try port(in: server) ?? ""
        ssh.user = server.user ?? ""

        let target = endpoints[endpoints.index(after: slash)...]
        let path = target.firstIndex(of: "/") ?? target.endIndex
        let login = target[..<path]
        guard !login.isEmpty, login.filter({ $0 == "@" }).count <= 1 else { throw invalid }
        // Without @db-host, MariaDB is on the SSH server's loopback interface.
        let authority = login.contains("@") ? String(login) : String(login) + "@127.0.0.1"
        guard let database = URLComponents(string: "mariadb://" + authority + target[path...] + resource[query...], encodingInvalidCharacters: false),
              database.host?.isEmpty == false else { throw invalid }
        return (database, ssh, server.password ?? "")
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
            if !profile.verifyTLS { items.append(URLQueryItem(name: "tls", value: profile.usesPreferredTLS ? "preferred" : "disabled")) }
            if !profile.name.isEmpty { items.append(URLQueryItem(name: "name", value: profile.name)) }
            if !profile.environment.isEmpty { items.append(URLQueryItem(name: "env", value: profile.environment)) }
            if let color = profile.tagColor, color.hasPrefix("#") { items.append(URLQueryItem(name: "statusColor", value: String(color.dropFirst()))) }
            if let ssh = profile.ssh {
                items += [URLQueryItem(name: "ssh-host", value: ssh.host), URLQueryItem(name: "ssh-port", value: ssh.port), URLQueryItem(name: "ssh-user", value: ssh.user)]
                if !ssh.databaseFingerprint.isEmpty { items.append(URLQueryItem(name: "db-fingerprint", value: ssh.databaseFingerprint)) }
                if ssh.keyOnly == true { items.append(URLQueryItem(name: "usePrivateKey", value: "true")) }
            }
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
            for j in copies[i].connections.indices { copies[i].connections[j].bootstrapSQL = nil; copies[i].connections[j].rememberPassword = false; copies[i].connections[j].ssh?.rememberSecret = false }
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
                    var copy = input; copy.bootstrapSQL = nil; copy.id = UUID(); copy.rememberPassword = false; copy.ssh?.rememberSecret = false
                    return copy
                }
                groups.append(ConnectionGroup(name: source.name, connections: profiles))
            }
        }
    }
}
