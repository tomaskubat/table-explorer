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
            Text(sshPage ? "SSH Tunnel" : profile.driver.rawValue + " Connection")
                .font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity)
            if profile.ssh != nil {
                Picker("Connection Options", selection: $sshPage) {
                    Text("Database").tag(false)
                    Text("SSH Tunnel").tag(true)
                }.pickerStyle(.segmented)
            }
            ScrollView {
                Form {
                    if sshPage, let ssh = Binding($profile.ssh) { sshFields(ssh) }
                    else { databaseFields }
                }.padding(.horizontal, 2)
            }.frame(minHeight: profile.driver == .sqlite ? 180 : (sshPage ? 245 : 332), maxHeight: profile.driver == .sqlite ? 205 : 355).disabled(busy)
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
        .padding(20).frame(width: 500).background(BrowserChrome.paper)
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
    private func sshFields(_ ssh: Binding<SSHSettings>) -> some View {
        Section("SSH tunnel") {
            TextField("SSH Host", text: ssh.host, prompt: Text("Hostname or ~/.ssh/config alias")).accessibilityIdentifier("SSH Host")
            TextField("SSH Port", text: ssh.port, prompt: Text("From SSH config")).accessibilityIdentifier("SSH Port")
            TextField("SSH User", text: ssh.user, prompt: Text("From SSH config")).accessibilityIdentifier("SSH User")
            HStack {
                TextField("Private Key File", text: ssh.identityFile).accessibilityIdentifier("Private Key File")
                Toggle("Key only", isOn: Binding(get: { ssh.wrappedValue.keyOnly == true }, set: { ssh.wrappedValue.keyOnly = $0 }))
            }
            SecureField("SSH Password or Key Passphrase", text: $sshPassword).accessibilityIdentifier("SSH Password")
            Toggle("Remember SSH secret in Keychain", isOn: ssh.rememberSecret)
            TextField("Known Hosts File", text: ssh.knownHostsFile).accessibilityIdentifier("Known Hosts File")
            if profile.verifyTLS {
                TextField("Database Certificate SHA-256", text: ssh.databaseFingerprint).accessibilityIdentifier("Database Fingerprint")
            }
        }
    }

    @ViewBuilder private var databaseFields: some View {
        TextField("Connection Name", text: $profile.name).accessibilityIdentifier("Connection Name")
        Picker("Group", selection: $groupID) {
            ForEach(library.groups) { Text($0.name).tag($0.id) }
        }
        HStack {
            TextField("Environment", text: $profile.environment).accessibilityIdentifier("Environment")
            Picker("Color Tag", selection: Binding(get: { profile.tagColor ?? "Teal" }, set: { profile.tagColor = $0 })) {
                if let custom = profile.tagColor, custom.hasPrefix("#") { Text(custom).tag(custom) }
                ForEach(["Teal", "Blue", "Purple", "Orange", "Red", "Green"], id: \.self) { Text($0) }
            }
        }
        Divider()
        if profile.driver == .mariaDB {
            Toggle("Over SSH", isOn: Binding(get: { profile.ssh != nil }, set: { enabled in
                profile.ssh = enabled ? SSHSettings() : nil; sshPage = enabled
            }))
            Toggle("Use Unix socket", isOn: $profile.usesSocket)
            if profile.usesSocket { TextField("Socket Path", text: $profile.socketPath).accessibilityIdentifier("Socket Path") }
            else {
                LabeledContent("Host") {
                    HStack {
                        TextField("Host", text: $profile.host).labelsHidden().accessibilityIdentifier("Host")
                        Text("Port")
                        TextField("Port", text: $profile.port).labelsHidden().frame(width: 70).accessibilityIdentifier("Port")
                    }
                }
            }
            TextField("User", text: $profile.user).accessibilityIdentifier("User")
            SecureField("Password", text: $password).accessibilityIdentifier("Password")
            Toggle("Remember password in Keychain", isOn: $profile.rememberPassword)
            TextField("Database", text: $profile.database).accessibilityIdentifier("Database")
            HStack {
                Toggle("Require verified TLS", isOn: $profile.verifyTLS)
                if !profile.verifyTLS {
                    Toggle("Prefer TLS when available", isOn: Binding(get: { profile.usesPreferredTLS }, set: { profile.preferTLS = $0 }))
                }
            }
            if profile.verifyTLS && profile.ssh == nil { TextField("CA Certificate Path", text: $profile.caPath).accessibilityIdentifier("CA Certificate Path") }

        } else {
            HStack {
                TextField("Database File", text: $profile.filePath).accessibilityIdentifier("Database File")
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK { profile.filePath = panel.url?.path ?? profile.filePath }
                }
            }
            Button("Create SQLite File…") {
                if profile.filePath.isEmpty {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "database.sqlite"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    profile.filePath = url.path
                }
                confirmCreate = true
            }
            if createdFile { Text("Database file created").foregroundStyle(.green) }
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
