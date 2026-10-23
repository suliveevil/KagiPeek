import XCTest
@testable import KagiPeekCore

/// The row contract, the list selection and the header layout used to live inside AppKit
/// code, where nothing could assert them. These tests pin the rules that the panel, the
/// inline filter now share.
final class RowKeyRouterTests: XCTestCase {
    func testRunWinsWhenBothKeysShareAChord() {
        let shared = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [])
        XCTAssertEqual(
            RowKeyRouter.action(for: KeyCode.returnKey, modifiers: [], run: shared, copy: shared),
            .execute
        )
    }

    func testRoutesEachKeyToItsAction() {
        let run = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [])
        let copy = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.command])
        XCTAssertEqual(RowKeyRouter.action(for: 36, modifiers: [], run: run, copy: copy), .execute)
        XCTAssertEqual(RowKeyRouter.action(for: 36, modifiers: [.command], run: run, copy: copy), .copy)
    }

    /// A bare letter must not become a row key, or filtering and chord entry would break.
    func testUnboundKeyIsNotRouted() {
        XCTAssertNil(RowKeyRouter.action(
            for: 0,
            modifiers: [],
            run: .runRowDefault,
            copy: .copyRowDefault
        ))
    }

    func testExtraModifierIsNotARowKey() {
        XCTAssertNil(RowKeyRouter.action(
            for: 36,
            modifiers: [.shift],
            run: .runRowDefault,
            copy: .copyRowDefault
        ))
    }

    func testCapturedIdentifiersMatchTheAliasRule() {
        // The two lists must be derived from the same alias table: if `matches` accepts a key
        // that `capturedIdentifiers` does not swallow, the front app sees a chord the panel
        // has already acted on.
        for spec in [HotkeySpec.runRowDefault, HotkeySpec.copyRowDefault, .panelDefault] {
            XCTAssertEqual(
                spec.capturedIdentifiers.map { $0.keyCode },
                KeyAliases.enterCodes(for: spec.keyCode)
            )
        }
    }

    func testEnterAliasWorksInBothDirections() {
        let onKeypad = HotkeySpec(keyCode: KeyCode.keypadEnter, modifiers: [])
        XCTAssertTrue(onKeypad.matches(keyCode: KeyCode.returnKey, modifiers: []))
        XCTAssertTrue(onKeypad.matches(keyCode: KeyCode.keypadEnter, modifiers: []))
    }
}
