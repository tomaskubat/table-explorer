import SwiftUI

struct AccountEditor: View {
    let workspace: Workspace
    let change: AccountChange
    let applied: () async -> Void
    @State private var user: String
    @State private var host: String
    @State private var password = ""
    @State private var scope = AccountPlan.Scope.database
    @State private var database: String
    @State private var table = ""
    @State private var privileges: Set<String> = []
    @State private var grantOption = false
    @State private var review: AccountPlan?
    @State private var confirmation = ""
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    init(workspace: Workspace, change: AccountChange, account: MariaAccount?, applied: @escaping () async -> Void) {
        self.workspace = workspace; self.change = change; self.applied = applied
        _user = State(initialValue: account?.user ?? ""); _host = State(initialValue: account?.host ?? "localhost")
        _database = State(initialValue: workspace.database)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(change.rawValue).font(.title2)
            Text(workspace.profile.name + " · " + workspace.profile.detail).foregroundStyle(.secondary)
            if let review {
                Text("Account: " + review.account.display)
                Text((try? review.statement()) ?? "").textSelection(.enabled)
                    .font(.system(.body, design: .monospaced)).accessibilityIdentifier("accountPreview")
                if requiresName(review) {
                    TextField("Type the account to confirm", text: $confirmation).accessibilityIdentifier("Confirm Account")
                }
            } else {
                HStack {
                    TextField("Account Name", text: $user).accessibilityIdentifier("Account Name")
                    TextField("Account Host", text: $host).accessibilityIdentifier("Account Host")
                }.disabled(change != .create)
                if change.needsPassword { SecureField("New Password", text: $password).accessibilityIdentifier("New Password") }
                if change.changesGrants {
                    Picker("Privilege Scope", selection: $scope) { ForEach(AccountPlan.Scope.allCases, id: \.self) { Text($0.rawValue) } }
                    if scope != .server { TextField("Grant Database", text: $database).accessibilityIdentifier("Grant Database") }
                    if scope == .table { TextField("Grant Table", text: $table) }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading) {
                            ForEach(AccountPlan.permissions(scope), id: \.self) { name in
                                Toggle(name, isOn: Binding(get: { privileges.contains(name) }, set: { value in
                                    if value { privileges.insert(name) } else { privileges.remove(name) }
                                }))
                            }
                        }
                    }
                    if change == .grant { Toggle("Allow account to grant these privileges", isOn: $grantOption) }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("accountError") }
            Spacer()
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let review {
                    Button("Back") { self.review = nil; confirmation = "" }
                    Button("Apply Account Change") { Task { await apply(review) } }.disabled(requiresName(review) && confirmation != review.account.display)
                } else {
                    Button("Review Account Change") {
                        do {
                            let plan = AccountPlan(change: change, account: MariaAccount(user: user, host: host), scope: scope,
                                                   database: database, table: table, privileges: privileges, grantOption: grantOption)
                            _ = try plan.statement(); review = plan; error = nil
                        } catch { self.error = error.localizedDescription }
                    }.disabled(user.isEmpty || host.isEmpty || (change.needsPassword && password.isEmpty))
                }
            }.disabled(busy)
        }.padding(18).frame(width: 560, height: change.changesGrants ? 400 : 270)
        .onChange(of: scope) { privileges.formIntersection(Set(AccountPlan.permissions(scope))) }
        .interactiveDismissDisabled(busy)
    }
    private func requiresName(_ plan: AccountPlan) -> Bool { change == .drop || (change.changesGrants && scope == .server) }
    private func apply(_ plan: AccountPlan) async {
        busy = true; defer { busy = false }
        do {
            try await workspace.session.applyAccount(plan, password: password)
            password = ""; workspace.log.append(change.rawValue + " · " + plan.account.display)
            await applied(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
