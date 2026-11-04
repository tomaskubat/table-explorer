import Darwin
import Foundation

struct SSHSettings: Codable, Hashable {
    var host = ""
    var port = "" // An empty override lets OpenSSH choose the configured port.
    var user = ""
    var identityFile = ""
    var knownHostsFile = ""
    var rememberSecret = false
    var keyOnly: Bool?
    var databaseFingerprint = ""

    var isValid: Bool {
        // OpenSSH can substitute these values into a configured ProxyCommand.
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+@\\")
        return !host.isEmpty && !host.hasPrefix("-") && host.unicodeScalars.allSatisfy(hostCharacters.contains)
            && !user.hasPrefix("-") && user.unicodeScalars.allSatisfy(userCharacters.contains)
            && (port.isEmpty || UInt16(port).map { $0 > 0 } == true)
    }
}

/// The socket is private to this application session. OpenSSH performs host
/// verification and authentication before creating the forwarding listener.
final class SSHTunnel {
    private let process = Process()
    private let lifetime = Pipe()
    private let directory: URL
    private let logFile: URL
    let socket: String

    init() throws {
        var template = Array("/tmp/cb-ssh-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw BrowserError("Could not create the private SSH socket directory.") }
        directory = URL(filePath: String(decoding: template.dropLast().map(UInt8.init(bitPattern:)), as: UTF8.self))
        logFile = directory.appending(path: "diagnostics")
        socket = directory.appending(path: "db.sock").path
    }
    deinit {
        try? lifetime.fileHandleForWriting.close()
        if process.isRunning { _ = kill(process.processIdentifier, SIGTERM); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }

    func start(profile: ConnectionProfile, settings: SSHSettings, secret: String) throws {
        guard settings.isValid else { throw BrowserError("Enter a valid SSH host or config alias. If set, the SSH port must be between 1 and 65535.") }
        guard !secret.contains("\0"), !secret.contains("\n"), !secret.contains("\r"), secret.utf8.count < 2048 else {
            throw BrowserError("The SSH password or passphrase must fit on a single line.")
        }
        let target: String
        if profile.usesSocket {
            guard profile.socketPath.hasPrefix("/"), !profile.socketPath.contains(":") else { throw BrowserError("Enter the absolute remote socket path.") }
            target = profile.socketPath
        } else {
            let remoteHost = profile.host.contains(":") && !profile.host.hasPrefix("[") ? "[" + profile.host + "]" : profile.host
            guard !remoteHost.isEmpty, UInt16(profile.port).map({ $0 > 0 }) == true else { throw BrowserError("Enter the database host and port as seen from the SSH server.") }
            target = remoteHost + ":" + profile.port
        }
        var arguments = ["-N", "-T", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
                         "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
                         "-o", "NumberOfPasswordPrompts=1", "-o", "ForwardAgent=no", "-o", "ServerAliveInterval=15",
                         "-o", "ServerAliveCountMax=2", "-o", "ControlPath=none", "-o", "ControlMaster=no",
                         "-o", "ForkAfterAuthentication=no", "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none"]
        // Normally ssh reads ~/.ssh/config itself, including Host, Match and Include.
        if let config = ProcessInfo.processInfo.environment["TABLE_EXPLORER_SSH_CONFIG"], !config.isEmpty {
            arguments += ["-F", config]
        }
        if !settings.port.isEmpty { arguments += ["-p", settings.port] }
        if !settings.user.isEmpty { arguments += ["-l", settings.user] }
        if settings.keyOnly == true { arguments += ["-o", "PreferredAuthentications=publickey"] }
        if !settings.identityFile.isEmpty {
            arguments += ["-o", "IdentitiesOnly=yes", "-i", (settings.identityFile as NSString).expandingTildeInPath]
        }
        if !settings.knownHostsFile.isEmpty {
            let path = (settings.knownHostsFile as NSString).expandingTildeInPath
            guard !path.contains("\n") && !path.contains("\r") else { throw BrowserError("Invalid known_hosts path.") }
            let quoted = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            arguments += ["-o", "UserKnownHostsFile=\"" + quoted + "\"", "-o", "GlobalKnownHostsFile=/dev/null"]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        let fifo = directory.appending(path: "askpass").path
        var descriptor: Int32 = -1
        defer {
            if descriptor >= 0 { Darwin.close(descriptor); unlink(fifo) }
        }
        if secret.isEmpty {
            arguments += ["-o", "BatchMode=yes"]
        } else {
            guard let helper = Bundle.main.url(forResource: "ssh-askpass", withExtension: nil),
                  mkfifo(fifo, mode_t(0o600)) == 0 else { throw BrowserError("Could not prepare SSH authentication.") }
            descriptor = Darwin.open(fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            let bytes = Data((secret + "\n").utf8)
            guard descriptor >= 0, bytes.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == bytes.count else {
                throw BrowserError("Could not pass credentials to OpenSSH.")
            }
            // A key supplied by the host's config may need the entered passphrase.
            arguments += ["-o", "BatchMode=no"]
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["SSH_ASKPASS"] = helper.path
            environment["CB_ASKPASS_FIFO"] = fifo
            environment["DISPLAY"] = "connection-browser"
        }
        arguments += ["-L", socket + ":" + target, "--", settings.host]
        guard FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BrowserError("Could not create the SSH diagnostics file.")
        }
        let errors = try FileHandle(forWritingTo: logFile)
        defer { try? errors.close() }
        guard let launcher = Bundle.main.url(forResource: "ssh-tunnel", withExtension: nil) else { throw BrowserError("The SSH tunnel helper is missing.") }
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [launcher.path] + arguments; process.environment = environment
        process.standardError = errors; process.standardOutput = FileHandle.nullDevice; process.standardInput = lifetime
        _ = fcntl(lifetime.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        try process.run()
        let deadline = Date().addingTimeInterval(12)
        while process.isRunning && Date() < deadline {
            if FileManager.default.fileExists(atPath: socket) { return }
            Thread.sleep(forTimeInterval: 0.04)
        }
        let diagnostic = try FileHandle(forReadingFrom: logFile)
        defer { try? diagnostic.close() }
        let size = try diagnostic.seekToEnd()
        try diagnostic.seek(toOffset: size > 4096 ? size - 4096 : 0)
        let detail = String(decoding: try diagnostic.readToEnd() ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw BrowserError("Could not open SSH tunnel. " + (detail.isEmpty ? "Authentication or forwarding timed out." : detail))
    }
}
