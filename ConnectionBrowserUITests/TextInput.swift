import AppKit
import XCTest

extension XCUIElement {
    @MainActor
    func setChecked(_ expected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let target = expected ? 1 : 0
        func state() -> Int? {
            if let number = value as? NSNumber { return number.intValue }
            return (value as? String).flatMap(Int.init)
        }
        if state() != target {
            XCTAssertTrue(isHittable, "Checkbox must be visible before changing it", file: file, line: line)
            coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).click()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in state() == target }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed, file: file, line: line)
    }

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

extension XCUIApplication {
    @MainActor
    func newProfile(driver: String) {
        activate()
        let createProfile = windows["Saved Connections"].buttons["New Connection"]
        XCTAssertTrue(createProfile.waitForExistence(timeout: 5))
        createProfile.click()
        let choice = buttons["driver-" + driver]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertFalse(buttons["Create"].isEnabled)
        choice.click()
        let create = buttons["Create"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 4), .completed)
        typeKey(.return, modifierFlags: [])
        XCTAssertTrue(textFields["Connection Name"].waitForExistence(timeout: 5))
    }
}
