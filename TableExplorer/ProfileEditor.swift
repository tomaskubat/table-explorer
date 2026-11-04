import SwiftUI

struct GroupEditor: View {
    let library: ConnectionLibrary
    @State var group: ConnectionGroup
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                Image(systemName: group.icon ?? "powerplug.fill").font(.system(size: 23))
                    .frame(width: 43, height: 43).overlay { Circle().strokeBorder(lineWidth: 2.2) }.foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Group name").font(.callout)
                    TextField("Production servers…", text: $group.name).accessibilityIdentifier("Group Name")
                }
            }
            Picker("Group Icon", selection: Binding(get: { group.icon ?? "powerplug.fill" }, set: { group.icon = $0 })) {
                Label("Plug", systemImage: "powerplug.fill").tag("powerplug.fill")
                Label("Folder", systemImage: "folder.fill").tag("folder.fill")
                Label("Server", systemImage: "server.rack").tag("server.rack")
                Label("Team", systemImage: "person.2.fill").tag("person.2.fill")
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try library.update { groups in
                            if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index].name = group.name; groups[index].icon = group.icon }
                            else { groups.append(group) }
                        }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 340).background(BrowserChrome.paper)
    }
}

struct ProfileEditor: View {
    let library: ConnectionLibrary
    @State var profile: ConnectionProfile
    @State var groupID: UUID
    let onConnect: (ConnectionProfile, DatabaseSession, String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var sshPassword = ""
    @State private var sshPage = false
    @State private var error: String?
    @State private var bootstrapEditor = false
    @State private var createdFile = false
    @State private var confirmCreate = false
    @State private var succeeded = false
    @State private var busy = false

    init(library: ConnectionLibrary, profile: ConnectionProfile, groupID: UUID, initialPassword: String = "", initialSSHPassword: String = "", initialError: String? = nil,
         onConnect: @escaping (ConnectionProfile, DatabaseSession, String, String, String) -> Void) {
        self.library = library; self.onConnect = onConnect
        _profile = State(initialValue: profile); _groupID = State(initialValue: groupID)
        _password = State(initialValue: initialPassword)
        _sshPassword = State(initialValue: initialSSHPassword)
        _error = State(initialValue: initialError)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.driver.rawValue + " Connection")
                .font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity)
            if profile.ssh != nil {
                Picker("Connection Options", selection: $sshPage) {
                    Text("Database").tag(false)
                    Text("SSH Tunnel").tag(true)
                }.labelsHidden().pickerStyle(.segmented).fixedSize().frame(maxWidth: .infinity)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if sshPage, let ssh = Binding($profile.ssh) { sshFields(ssh) }
                    else { databaseFields }
                }.padding(2).frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true).frame(maxHeight: 410).disabled(busy)
            Divider()
            options { Toggle("Remember open tabs and workspace state", isOn: $profile.remembersWorkspace) }
                .padding(.horizontal, 2)
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("connectionError")
            } else if succeeded { Text("Connection succeeded").foregroundStyle(.green) }
            HStack {
                bootstrapButton
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Save") {
                    do { try library.save(profile, in: groupID, password: password, sshPassword: sshPassword); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(!canSave || busy)
                Button("Test") { Task { await connect(testOnly: true) } }
                    .accessibilityLabel("Test Connection").disabled(!canConnect || busy)
                Button("Connect") { Task { await connect(testOnly: false) } }
                    .accessibilityLabel("Save and Connect").keyboardShortcut(.defaultAction).disabled(!canSave || !canConnect || busy)
            }
        }
        .padding(20).frame(width: 534).background(BrowserChrome.paper)
        .confirmationDialog("Create a new SQLite database at this path?", isPresented: $confirmCreate) {
            Button("Create File") {
                do { try DatabaseSession.createSQLite(at: profile.filePath); createdFile = true; error = nil }
                catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(profile.filePath) }
        .onChange(of: profile.filePath) { createdFile = false }
        .interactiveDismissDisabled(busy)
        .onChange(of: profile) { succeeded = false; error = nil }
        .onChange(of: password) { succeeded = false; error = nil }
        .onChange(of: sshPassword) { succeeded = false; error = nil }
        .onAppear {
            if profile.ssh?.rememberSecret == true {
                do { sshPassword = try ProfilePassword.read(profile.id, ssh: true) }
                catch { self.error = error.localizedDescription }
            }
            if profile.rememberPassword {
                do { password = try ProfilePassword.read(profile.id) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    private let labelWidth: CGFloat = 88
    private let columnGap: CGFloat = 8

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: columnGap) {
            Text(title).frame(width: labelWidth, alignment: .trailing)
            content().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func options<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(.leading, labelWidth + columnGap)
    }

    private func endpoint(hostLabel: String, host: Binding<String>, port: Binding<String>, ssh: Bool = false) -> some View {
        row(hostLabel) {
            HStack(spacing: 8) {
                TextField(hostLabel, text: host, prompt: Text(ssh ? "Hostname or SSH config alias" : "Hostname"))
                    .accessibilityIdentifier(ssh ? "SSH Host" : "Host")
                Text("Port")
                TextField("Port", text: port, prompt: Text(ssh ? "Config" : "3306"))
                    .frame(width: 61).accessibilityIdentifier(ssh ? "SSH Port" : "Port")
                    .help(ssh ? "Uses the port from SSH config, or 22 if none is configured." : "Database server port")
            }
        }
    }

    private func sshFields(_ ssh: Binding<SSHSettings>) -> some View {
        Group {
            endpoint(hostLabel: "Server", host: ssh.host, port: ssh.port, ssh: true)
            row("User") { TextField("SSH User", text: ssh.user, prompt: Text("From SSH config")).accessibilityIdentifier("SSH User") }
            row("Password") { SecureField("SSH Password", text: $sshPassword, prompt: Text("Password or key passphrase")).accessibilityIdentifier("SSH Password") }
            options { Toggle("Remember SSH secret in Keychain", isOn: ssh.rememberSecret) }
            row("Private key") { TextField("Private Key File", text: ssh.identityFile, prompt: Text("From SSH config")).accessibilityIdentifier("Private Key File") }
            options { Toggle("Use SSH key only", isOn: Binding(get: { ssh.wrappedValue.keyOnly == true }, set: { ssh.wrappedValue.keyOnly = $0 })) }
            row("Known hosts") { TextField("Known Hosts File", text: ssh.knownHostsFile, prompt: Text("Default known_hosts file")).accessibilityIdentifier("Known Hosts File") }
            if profile.verifyTLS {
                row("DB fingerprint") { TextField("Database Certificate SHA-256", text: ssh.databaseFingerprint, prompt: Text("SHA-256 certificate fingerprint")).accessibilityIdentifier("Database Fingerprint") }
            }
        }
    }

    @ViewBuilder private var databaseFields: some View {
        row("Name") { TextField("Connection Name", text: $profile.name).accessibilityIdentifier("Connection Name") }
        row("Status color") {
            HStack(spacing: 6) {
                ColorPicker("Custom status color", selection: Binding(get: { profile.badgeColor }, set: { if let hex = $0.statusHex { profile.tagColor = hex } }), supportsOpacity: false)
                    .labelsHidden().fixedSize().accessibilityIdentifier("Custom Status Color")
                ForEach(StatusSwatch.allCases, id: \.self) { swatch in
                    let selected = (profile.tagColor ?? StatusSwatch.neutral.rawValue) == swatch.rawValue
                    Button { profile.tagColor = swatch.rawValue } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(statusHex: swatch.rawValue)!)
                            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.2)) }
                            .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.7)) } }
                            .frame(width: 19, height: 19)
                    }.buttonStyle(.plain).help(swatch.name).accessibilityLabel(swatch.name + " status color")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer(minLength: 6)
                Text("Tag")
                Picker("Tag", selection: $profile.connectionTag) {
                    ForEach(ConnectionTag.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                    if ConnectionTag(rawValue: profile.connectionTag) == nil {
                        Text(profile.connectionTag.isEmpty ? "None" : profile.connectionTag).tag(profile.connectionTag)
                    }
                }.labelsHidden().frame(width: 113).accessibilityIdentifier("Connection Tag")
            }
        }
        row("Group") {
            Picker("Group", selection: $groupID) { ForEach(library.groups) { Text($0.name).tag($0.id) } }
                .labelsHidden().accessibilityIdentifier("Connection Group")
        }
        Divider()
        if profile.driver == .mariaDB {
            options {
                HStack(spacing: 18) {
                    Toggle("Over SSH", isOn: Binding(get: { profile.ssh != nil }, set: { enabled in
                        profile.ssh = enabled ? SSHSettings() : nil; sshPage = enabled
                    }))
                    Toggle("Use Unix socket", isOn: $profile.usesSocket)
                }
            }
            if profile.usesSocket { row("Socket path") { TextField("Socket Path", text: $profile.socketPath).accessibilityIdentifier("Socket Path") } }
            else { endpoint(hostLabel: "Host", host: $profile.host, port: $profile.port) }
            row("User") { TextField("User", text: $profile.user).accessibilityIdentifier("User") }
            row("Password") { SecureField("Password", text: $password).accessibilityIdentifier("Password") }
            options { Toggle("Remember password in Keychain", isOn: $profile.rememberPassword) }
            row("Database") { TextField("Database", text: $profile.database).accessibilityIdentifier("Database") }
            options {
                HStack(spacing: 18) {
                    Toggle("Require verified TLS", isOn: $profile.verifyTLS)
                    if !profile.verifyTLS {
                        Toggle("Prefer TLS when available", isOn: Binding(get: { profile.usesPreferredTLS }, set: { profile.preferTLS = $0 }))
                    }
                }
            }
            if profile.verifyTLS && profile.ssh == nil { row("CA certificate") { TextField("CA Certificate Path", text: $profile.caPath).accessibilityIdentifier("CA Certificate Path") } }
        } else {
            row("Database file") {
                HStack {
                    TextField("Database File", text: $profile.filePath).accessibilityIdentifier("Database File")
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK { profile.filePath = panel.url?.path ?? profile.filePath }
                    }
                }
            }
            options {
                Button("Create SQLite File…") {
                    if profile.filePath.isEmpty {
                        let panel = NSSavePanel(); panel.nameFieldStringValue = "database.sqlite"
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        profile.filePath = url.path
                    }
                    confirmCreate = true
                }
            }
            if createdFile { options { Text("Database file created").foregroundStyle(.green) } }
        }
    }

    private var bootstrapButton: some View {
        Button("Bootstrap SQL…") { bootstrapEditor = true }
            .sheet(isPresented: $bootstrapEditor) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bootstrap SQL").font(.title2)
                    Text("Review these statements after connecting. Testing a connection skips this script. Profile archives omit bootstrap SQL.")
                    TextEditor(text: Binding(get: { profile.bootstrapSQL ?? "" }, set: { profile.bootstrapSQL = $0 }))
                        .font(.system(.body, design: .monospaced)).accessibilityIdentifier("Bootstrap Editor")
                    HStack { Spacer(); Button("Done") { bootstrapEditor = false }.keyboardShortcut(.defaultAction) }
                }.padding(16).frame(width: 480, height: 280)
            }
    }

    private var canSave: Bool { !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && canConnect }
    private var canConnect: Bool {
        if profile.driver == .sqlite { return !profile.filePath.isEmpty }
        if let ssh = profile.ssh, !ssh.isValid { return false }
        return !profile.user.isEmpty && (profile.usesSocket ? !profile.socketPath.isEmpty : !profile.host.isEmpty && UInt16(profile.port).map { $0 > 0 } == true)
    }

    private func connect(testOnly: Bool) async {
        busy = true; error = nil; succeeded = false
        defer { busy = false }
        let session = DatabaseSession()
        do {
            let database = try await session.open(profile, password: password, sshPassword: sshPassword)
            if testOnly { await session.close(); succeeded = true }
            else {
                try library.save(profile, in: groupID, password: password, sshPassword: sshPassword)
                dismiss()
                onConnect(profile, session, database, password, sshPassword)
            }
        } catch { await session.close(); self.error = error.localizedDescription }
    }
}
