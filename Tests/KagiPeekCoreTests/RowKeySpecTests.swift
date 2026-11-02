import XCTest
@testable import KagiPeekCore

final class RowKeySpecTests: XCTestCase {
    func testReturnBindingAcceptsKeypadEnter() {
        let spec = HotkeySpec.runRowDefault // ↩, no modifiers
        XCTAssertTrue(spec.matches(keyCode: 36, modifiers: []))
        XCTAssertTrue(spec.matches(keyCode: 76, modifiers: []))
    }

    func testBindingDoesNotAcceptExtraModifiers() {
        XCTAssertFalse(HotkeySpec.runRowDefault.matches(keyCode: 36, modifiers: [.shift]))
        XCTAssertTrue(HotkeySpec.copyRowDefault.matches(keyCode: 36, modifiers: [.command]))
        XCTAssertFalse(HotkeySpec.copyRowDefault.matches(keyCode: 36, modifiers: []))
    }

    func testCapturedIdentifiersFollowTheReturnAlias() {
        let copy = HotkeySpec.copyRowDefault.capturedIdentifiers
        XCTAssertEqual(copy.count, 2)
        XCTAssertEqual(copy.map { $0.keyCode }, [36, 76])

        // A binding that is not Return has exactly one identity to swallow.
        XCTAssertEqual(HotkeySpec.panelDefault.capturedIdentifiers.count, 1)
    }
}
