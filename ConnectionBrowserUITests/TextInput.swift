import AppKit
import XCTest

extension XCUIElement {
    /// Paste in a single event. Character-by-character typing can interleave with
    /// other applications on a developer's shared macOS desktop.
    @MainActor
    func replaceText(with value: String) {
        let board = NSPasteboard.general
        let previous = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        click()
        typeKey("a", modifierFlags: .command)
        board.clearContents()
        board.setString(value, forType: .string)
        let changeCount = board.changeCount
        typeKey("v", modifierFlags: .command)
        if board.changeCount == changeCount {
            board.clearContents()
            if !previous.isEmpty { board.writeObjects(previous) }
        }
    }
}
