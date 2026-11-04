import SwiftUI

struct GroupEditor: View {
    let library: ConnectionLibrary
    @State var group: ConnectionGroup
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection Group").font(.title2)
            TextField("Group Name", text: $group.name).accessibilityIdentifier("Group Name")
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try library.update { groups in
                            if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index].name = group.name }
                            else { groups.append(group) }
                        }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 340)
    }
}

struct ProfileEditor: View {
    let library: ConnectionLibrary
    @State var profile: ConnectionProfile
    @State var groupID: UUID
    let onConnect: (ConnectionProfile, DatabaseSession, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?
    @State private var succeeded = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection Settings").font(.title2)
            Form {
                Picker("Driver", selection: $profile.driver) {
                    ForEach(DatabaseDriver.allCases, id: \.self) { Text($0.rawValue) }
                }.pickerStyle(.segmented)
                TextField("Connection Name", text: $profile.name).accessibilityIdentifier("Connection Name")
                Picker("Group", selection: $groupID) {
                    ForEach(library.groups) { Text($0.name).tag($0.id) }
                }
                TextField("Environment", text: $profile.environment)
                Divider()
                if profile.driver == .mariaDB {
                    Toggle("Use Unix socket", isOn: $profile.usesSocket)
                    if profile.usesSocket { TextField("Socket Path", text: $profile.socketPath) }
                    else {
                        TextField("Host", text: $profile.host).accessibilityIdentifier("Host")
                        TextField("Port", text: $profile.port).accessibilityIdentifier("Port")
                    }
                    TextField("User", text: $profile.user).accessibilityIdentifier("User")
                    SecureField("Password", text: $password).accessibilityIdentifier("Password")
                    Toggle("Remember password in Keychain", isOn: $profile.rememberPassword)
                    TextField("Database", text: $profile.database).accessibilityIdentifier("Database")
                    Toggle("Require verified TLS", isOn: $profile.verifyTLS)
                    if profile.verifyTLS { TextField("CA Certificate Path", text: $profile.caPath) }
                } else {
                    HStack {
                        TextField("Database File", text: $profile.filePath).accessibilityIdentifier("Database File")
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK { profile.filePath = panel.url?.path ?? profile.filePath }
                        }
                    }
                }
            }.disabled(busy)
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("connectionError")
            } else if succeeded { Text("Connection succeeded").foregroundStyle(.green) }
            HStack {
                Button("Test Connection") { Task { await connect(testOnly: true) } }.disabled(!canConnect || busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Save") {
                    do { try library.save(profile, in: groupID, password: password); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(!canSave || busy)
                Button("Save and Connect") { Task { await connect(testOnly: false) } }
                    .keyboardShortcut(.defaultAction).disabled(!canSave || !canConnect || busy)
            }
        }
        .padding(22).frame(width: 540)
        .interactiveDismissDisabled(busy)
        .onChange(of: profile) { succeeded = false; error = nil }
        .onChange(of: password) { succeeded = false; error = nil }
        .onAppear {
            if profile.rememberPassword {
                do { password = try ProfilePassword.read(profile.id) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    private var canSave: Bool { !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && canConnect }
    private var canConnect: Bool {
        if profile.driver == .sqlite { return !profile.filePath.isEmpty }
        return !profile.user.isEmpty && (profile.usesSocket ? !profile.socketPath.isEmpty : !profile.host.isEmpty && UInt16(profile.port).map { $0 > 0 } == true)
    }

    private func connect(testOnly: Bool) async {
        busy = true; error = nil; succeeded = false
        defer { busy = false }
        let session = DatabaseSession()
        do {
            let database = try await session.open(profile, password: password)
            if testOnly { await session.close(); succeeded = true }
            else {
                try library.save(profile, in: groupID, password: password)
                dismiss()
                onConnect(profile, session, database)
            }
        } catch { await session.close(); self.error = error.localizedDescription }
    }
}
