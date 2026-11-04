import XCTest
@testable import KagiPeekCore

/// The trigger key is the only place that knows which side of a modifier was pressed.
final class TriggerKeyTests: XCTestCase {
    private let leftShift: UInt16 = 56
    private let capsLock: UInt16 = 57

    func testPhysicalKeyCodes() {
        XCTAssertEqual(TriggerKey.leftControl.keyCodes, [59])
        XCTAssertEqual(TriggerKey.leftOption.keyCodes, [58])
        XCTAssertEqual(TriggerKey.leftCommand.keyCodes, [55])
        XCTAssertEqual(TriggerKey.rightCommand.keyCodes, [54])
        XCTAssertEqual(TriggerKey.rightOption.keyCodes, [61])
        XCTAssertEqual(TriggerKey.anyModifier.keyCodes, [55, 54, 58, 61, 59, 62])
    }

    /// Left and right Command share the modifier bit; only the event key code separates them.
    func testLeftAndRightCommandAreDistinct() {
        XCTAssertTrue(TriggerKey.rightCommand.isPressed(keyCode: 54, modifiers: [.command]))
        XCTAssertFalse(TriggerKey.rightCommand.isPressed(keyCode: 55, modifiers: [.command]))
        XCTAssertTrue(TriggerKey.leftCommand.isPressed(keyCode: 55, modifiers: [.command]))
        XCTAssertFalse(TriggerKey.leftCommand.isPressed(keyCode: 54, modifiers: [.command]))
    }

    /// A release of the trigger key is not a press, even though the key code matches: the
    /// modifier bit is what says whether it is down.
    func testReleaseIsNotAPress() {
        XCTAssertFalse(TriggerKey.rightCommand.isPressed(keyCode: 54, modifiers: []))
    }

    func testAnyModifierAcceptsAnyNonShiftModifier() {
        XCTAssertTrue(TriggerKey.anyModifier.isPressed(keyCode: 55, modifiers: [.command]))
        XCTAssertTrue(TriggerKey.anyModifier.isPressed(keyCode: 61, modifiers: [.option]))
        XCTAssertTrue(TriggerKey.anyModifier.isPressed(keyCode: 59, modifiers: [.control]))
        XCTAssertTrue(TriggerKey.anyModifier.isPressed(keyCode: 55, modifiers: [.command, .shift]))
    }

    /// Shift alone is typing capitals, not a gesture.
    func testAnyModifierIgnoresShiftAndEmpty() {
        XCTAssertFalse(TriggerKey.anyModifier.isPressed(keyCode: leftShift, modifiers: [.shift]))
        XCTAssertFalse(TriggerKey.anyModifier.isPressed(keyCode: 0, modifiers: []))
    }

    /// Shift and Caps Lock must stay available to the front app: swallowing them would break
    /// capital letters and Caps Lock itself.
    func testSwallowedKeyCodesExcludeShiftAndCapsLock() {
        for key in TriggerKey.allCases {
            XCTAssertFalse(key.swallowedKeyCodes.contains(leftShift), "\(key) swallows left Shift")
            XCTAssertFalse(key.swallowedKeyCodes.contains(60), "\(key) swallows right Shift")
            XCTAssertFalse(key.swallowedKeyCodes.contains(capsLock), "\(key) swallows Caps Lock")
        }
    }
}
