import SwiftUI

struct DriverChooser: View {
    private enum Step { case choose, address, settings, group }
    let library: ConnectionLibrary
    let groupID: UUID
    let onConnect: (ConnectionProfile, DatabaseSession, String, String, String) -> Void
    @State private var step = Step.choose
    @State private var driver: DatabaseDriver?
    @State private var profile = ConnectionProfile()
    @State private var password = ""
    @State private var address = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch step {
        case .settings: ProfileEditor(library: library, profile: profile, groupID: groupID, initialPassword: password, onConnect: onConnect)
        case .group: GroupEditor(library: library, group: ConnectionGroup(name: ""))
        case .address:
            VStack(alignment: .leading, spacing: 12) {
                Text("Connection URL").font(.title2)
                TextField("mariadb://user@localhost/catalog", text: $address).accessibilityIdentifier("Connection URL")
                if let error { Text(error).foregroundStyle(.red) }
                HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Import") {
                    do { (profile, password) = try ProfileAddress.parse(address); step = .settings }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(address.isEmpty) }
            }.padding(20).frame(width: 450)
        case .choose:
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose a database driver").font(.title2)
                HStack(spacing: 14) {
                    ForEach(DatabaseDriver.allCases, id: \.self) { choice in
                        Button {
                            driver = choice
                        } label: {
                            VStack(spacing: 8) {
                                Text(choice == .mariaDB ? "Mr" : "Sq").font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white).frame(width: 44, height: 44)
                                    .background(choice == .mariaDB ? Color.teal : .blue, in: Circle())
                                Text(choice.rawValue)
                            }.frame(width: 120, height: 85).contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .tint(driver == choice ? .accentColor : .secondary)
                        .accessibilityIdentifier("driver-" + choice.rawValue)
                        .accessibilityAddTraits(driver == choice ? .isSelected : [])
                    }
                }
                HStack {
                    Button("New Group") { step = .group }
                    Button("Import from URL") { step = .address }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        if let driver { profile.driver = driver; step = .settings }
                    }.keyboardShortcut(.defaultAction).disabled(driver == nil)
                }
            }.padding(20).frame(width: 470)
        }
    }
}
