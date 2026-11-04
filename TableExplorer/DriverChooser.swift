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
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(DatabaseDriver.allCases, id: \.self) { choice in
                        Button {
                            driver = choice
                        } label: {
                            VStack(spacing: 7) {
                                DriverBadge(driver: choice, diameter: 40)
                                Text(choice.rawValue).font(.system(size: 13))
                            }.frame(width: 88, height: 85)
                                .background(driver == choice ? Color.accentColor.opacity(0.13) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("driver-" + choice.rawValue)
                        .accessibilityAddTraits(driver == choice ? .isSelected : [])
                    }
                    Spacer()
                }.padding(10).frame(maxWidth: .infinity, minHeight: 115, alignment: .topLeading)
                    .background(BrowserChrome.paper).border(BrowserChrome.line, width: 0.6)
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Import from URL") { step = .address }
                    Button("New Group") { step = .group }
                    Button("Create") {
                        if let driver { profile.driver = driver; step = .settings }
                    }.keyboardShortcut(.defaultAction).disabled(driver == nil)
                }
            }.padding(18).frame(width: 480).background(BrowserChrome.paper)
        }
    }
}
