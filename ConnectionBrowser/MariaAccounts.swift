import Foundation

enum AccountChange: String, Identifiable {
    case create = "Create Account", password = "Change Password", grant = "Grant Privileges", revoke = "Revoke Privileges", drop = "Remove Account"
    var id: Self { self }
    var needsPassword: Bool { self == .create || self == .password }
    var changesGrants: Bool { self == .grant || self == .revoke }
}

struct MariaAccount: Hashable {
    let user: String
    let host: String
    var display: String { user + "@" + host }
    var sql: String { DatabaseSession.identifier(user) + "@" + DatabaseSession.identifier(host) }
}

struct AccountPlan {
    enum Scope: String, CaseIterable { case database = "Database", table = "Table", server = "Entire Server" }
    let change: AccountChange
    let account: MariaAccount
    let scope: Scope
    let database: String
    let table: String
    let privileges: Set<String>
    var grantOption: Bool

    static func permissions(_ scope: Scope) -> [String] {
        var list = ["SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "INDEX", "REFERENCES", "CREATE VIEW", "SHOW VIEW", "TRIGGER"]
        if scope != .table { list += ["CREATE ROUTINE", "ALTER ROUTINE", "EXECUTE", "EVENT", "LOCK TABLES", "CREATE TEMPORARY TABLES"] }
        if scope == .server { list += ["CREATE USER", "SHOW DATABASES", "PROCESS", "RELOAD", "REPLICATION SLAVE", "FILE"] }
        return list
    }

    func statement(passwordLiteral: String = "'••••'") throws -> String {
        guard [account.user, account.host].allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { throw BrowserError("Enter both an account name and a host.") }
        switch change {
        case .create: return "CREATE USER " + account.sql + " IDENTIFIED BY " + passwordLiteral
        case .password: return "ALTER USER " + account.sql + " IDENTIFIED BY " + passwordLiteral
        case .drop: return "DROP USER " + account.sql
        case .grant, .revoke:
            guard !privileges.isEmpty && privileges.isSubset(of: Set(Self.permissions(scope))) else { throw BrowserError("Select privileges available at this scope.") }
            let target: String
            if scope == .server { target = "*.*" }
            else {
                guard !database.isEmpty, !database.contains("\0") else { throw BrowserError("Enter the exact database name.") }
                if scope == .table {
                    guard !table.isEmpty, !table.contains("\0") else { throw BrowserError("Enter the exact table name.") }
                    target = DatabaseSession.identifier(database) + "." + DatabaseSession.identifier(table)
                } else {
                    // MariaDB treats database-level privilege names as LIKE patterns.
                    let literal = database.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "%", with: "\\%")
                    target = DatabaseSession.identifier(literal) + ".*"
                }
            }
            let permissions = privileges.sorted().joined(separator: ", ")
            if change == .revoke { return "REVOKE " + permissions + " ON " + target + " FROM " + account.sql }
            return "GRANT " + permissions + " ON " + target + " TO " + account.sql + (grantOption ? " WITH GRANT OPTION" : "")
        }
    }
}

extension DatabaseSession {
    func applyAccount(_ plan: AccountPlan, password: String) throws {
        guard !hasOpenTransaction else { throw BrowserError("Finish the current transaction before changing server accounts.") }
        var literal = "''"
        if plan.change.needsPassword {
            guard !password.isEmpty, !password.contains("\0") else { throw BrowserError("Enter a nonempty password without a NUL character.") }
            let modes = try query("SELECT @@SESSION.sql_mode").rows.first?.first?.display.components(separatedBy: ",") ?? []
            let text = modes.contains("NO_BACKSLASH_ESCAPES") ? password : password.replacingOccurrences(of: "\\", with: "\\\\")
            literal = "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        }
        do { _ = try query(plan.statement(passwordLiteral: literal)) }
        catch {
            if plan.change.needsPassword {
                let message = error.localizedDescription.replacingOccurrences(of: literal, with: "'••••'").replacingOccurrences(of: password, with: "••••")
                throw BrowserError(message, disconnected: (error as? BrowserError)?.disconnected == true)
            }
            throw error
        }
    }
}
