import XCTest
@testable import KagiPeekCore

final class RowKeySpecTests: XCTestCase {
    func testSpaceRunsTheRow() {
        let spec = HotkeySpec.runRowDefault // Space, no modifiers
        XCTAssertTrue(spec.matches(keyCode: KeyCode.space, modifiers: []))
        XCTAssertFalse(spec.matches(keyCode: KeyCode.space, modifiers: [.shift]))
        XCTAssertFalse(spec.matches(keyCode: KeyCode.returnKey, modifiers: []))
    }

    func testReturnCopiesTheRow() {
        let spec = HotkeySpec.copyRowDefault // ↩, no modifiers
        XCTAssertTrue(spec.matches(keyCode: 36, modifiers: []))
        XCTAssertTrue(spec.matches(keyCode: 76, modifiers: []))
        XCTAssertFalse(spec.matches(keyCode: 36, modifiers: [.command]))
        XCTAssertFalse(spec.matches(keyCode: KeyCode.space, modifiers: []))
    }

    func testCapturedIdentifiersFollowEachBinding() {
        // Space is one identity; Return still answers to the keypad Enter alias.
        XCTAssertEqual(HotkeySpec.runRowDefault.capturedIdentifiers.map { $0.keyCode }, [KeyCode.space])
        let copy = HotkeySpec.copyRowDefault.capturedIdentifiers
        XCTAssertEqual(copy.count, 2)
        XCTAssertEqual(copy.map { $0.keyCode }, [36, 76])

        // A binding that is not Return has exactly one identity to swallow.
        XCTAssertEqual(HotkeySpec.panelDefault.capturedIdentifiers.count, 1)
    }
}
