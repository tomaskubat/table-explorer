import Foundation

extension WorkspaceFeedback {
    @MainActor static func filterCompletion() throws {
        func column(_ name: String, _ type: String, nullable: Bool = true) -> ColumnInfo {
            ColumnInfo(name: name, type: type, nullable: nullable, defaultSQL: nil, keyOrder: 0, generated: false, automatic: false)
        }
        let columns = [column("id", "INTEGER", nullable: false), column("name", "TEXT"), column("nickname", "VARCHAR(80)"),
                       column("quantity", "DECIMAL(10,2)", nullable: false), column("enabled", "BOOLEAN"), column("created_at", "DATETIME"),
                       column("order total", "INTEGER"), column("odd`name", "TEXT"), column("město", "TEXT"), column("payload", "BLOB")]
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) {
            if condition { print("PASS: " + label) }
            else { print("FAIL: " + label); failures.append(label) }
        }
        func suggestions(_ text: String, cursor: Int? = nil, driver: DatabaseDriver = .sqlite) -> [SQLFilterCompletion] {
            SQLFilterCompleter.suggestions(in: text, selection: NSRange(location: cursor ?? text.utf16.count, length: 0), columns: columns, driver: driver)
        }
        let names = suggestions("n")
        check(names.map(\.title) == ["name", "nickname"], "the first typed character offers all matching columns")
        let completed = names.first!.applying(to: "n")
        check(completed.text == "`name` " && completed.selection == NSRange(location: 7, length: 0), "accepting a column quotes it and places the caret after a space")
        check(suggestions("N").map(\.title) == names.map(\.title), "column completion is case insensitive")
        check(suggestions("me").first?.title == "město", "column completion handles accented names")
        check(suggestions("order").first?.applying(to: "order").text == "`order total` ", "column names containing spaces are quoted")
        check(suggestions("odd").first?.applying(to: "odd").text == "`odd``name` ", "backticks inside a column name are escaped")
        let textOperators = suggestions("`name` ").map(\.title), numberOperators = suggestions("`quantity` ").map(\.title)
        check(textOperators.contains("LIKE") && textOperators.contains("NOT LIKE") && textOperators.contains("IS NULL"), "text and nullable columns offer appropriate predicates")
        check(numberOperators.contains("BETWEEN") && numberOperators.contains(">=") && !numberOperators.contains("LIKE") && !numberOperators.contains("IS NULL"),
              "numeric and nonnullable columns use their metadata for operator suggestions")
        let comparison = suggestions("`quantity`>").first { $0.title == ">=" }
        check(comparison?.applying(to: "`quantity`>").text == "`quantity` >= ", "accepting a partial comparison completes the operator with proper spacing")
        let textValue = suggestions("`name` = ").first!
        let quoted = textValue.applying(to: "`name` = ")
        check(quoted.text == "`name` = '' " && quoted.selection == NSRange(location: 10, length: 0), "text value completion leaves the caret inside quotes")
        let number = suggestions("`quantity` = ").first!.applying(to: "`quantity` = ")
        check(number.text == "`quantity` = 0 " && number.selection.length == 1, "numeric value completion selects the value for replacement")
        check(suggestions("`enabled` = f").map(\.title) == ["FALSE"], "boolean columns offer SQL boolean values")
        let dates = suggestions("`created_at` >= C").map(\.title)
        check(dates.contains("CURRENT_DATE") && dates.contains("CURRENT_TIMESTAMP"), "date columns offer SQL date values")
        check(suggestions("`payload` = ").first?.insertion == "X'' ", "binary columns offer a hex literal")
        check(suggestions("`name` = 'na").isEmpty && suggestions("`name` = 'it''s na").isEmpty, "completion stays out of quoted string values")
        check(suggestions("`name` = 'a\\'b", driver: .mariaDB).isEmpty,
              "MariaDB escaped quotes remain inside their string literal")
        check(suggestions("id = 1 -- n").isEmpty && suggestions("id = 1 /* n").isEmpty && suggestions("id = 1 # n", driver: .mariaDB).isEmpty,
              "completion stays out of SQL comments")
        check(suggestions("`quantity` = 2").isEmpty && suggestions("`name` = 'Brno' ").isEmpty, "a finished predicate leaves Return available to apply the filter")
        let and = suggestions("id = 1 A").first
        check(and?.title == "AND" && and?.applying(to: "id = 1 A").text == "id = 1 AND ", "AND completion preserves the previous predicate")
        check(suggestions("id = 1 AND n").map(\.title) == ["name", "nickname"], "column completion resumes after a boolean connector")
        check(suggestions("`quantity` BETWEEN 1 ").map(\.title) == ["AND"] && suggestions("`quantity` BETWEEN 1 AND 10").isEmpty,
              "BETWEEN predicts its bound separator without treating it as a new predicate")
        check(suggestions("`quantity` IN (").first?.title == "number" && suggestions("`quantity` IN (1").first?.title == ")",
              "IN predicts a value and the closing list delimiter")
        check(suggestions("`quantity` IN (1, ").first?.title == "number" && suggestions("`quantity` IN (1, 2) A").first?.title == "AND",
              "IN supports additional values and continuation after its closing parenthesis")
        check(suggestions("`name` NOT ").map(\.title) == ["BETWEEN", "IN", "LIKE"], "NOT predicts the remaining operator without duplicating NOT")
        check(suggestions("`name` IS N").map(\.title) == ["NULL", "NOT NULL"] && suggestions("`name` IS NOT N").map(\.title) == ["NULL"],
              "IS and IS NOT predict null predicates")
        check(suggestions("(n").map(\.title) == names.map(\.title) && suggestions("(id = 1").first?.title == ")", "grouped conditions offer columns and their closing parenthesis")
        let middle = "name = 'kept'"
        check(suggestions(middle, cursor: 2).first?.applying(to: middle).text == "`name` = 'kept'", "completion replaces the full token while preserving the rest of the predicate")
        check(suggestions("`name` = '🙂' AND n").first?.applying(to: "`name` = '🙂' AND n").text == "`name` = '🙂' AND `name` ",
              "replacement ranges remain correct after non-BMP characters")
        check(suggestions("`na").first?.insertion == "`name` ", "completion supports an unfinished quoted identifier")
        check(suggestions("`name`", cursor: 3).first?.applying(to: "`name`").text == "`name` ", "editing inside a quoted identifier does not duplicate its closing quote")
        check(suggestions("LOWER(name) L").isEmpty, "unsupported expression contexts retain normal text editing")
        check(SQLFilterCompleter.suggestions(in: "n", selection: NSRange(location: 1, length: 0), columns: [column("new_table_column", "TEXT")], driver: .sqlite).map(\.title) == ["new_table_column"],
              "suggestions always use the active table's columns")
        if !failures.isEmpty { throw BrowserError("SQL filter completion checks failed: " + failures.joined(separator: "; ")) }
    }
}
