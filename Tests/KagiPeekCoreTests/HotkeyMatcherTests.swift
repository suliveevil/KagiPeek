import XCTest
@testable import KagiPeekCore

final class HotkeyMatcherTests: XCTestCase {
    private let hyper = HotkeySpec(keyCode: 40, modifiers: [.control, .option, .shift, .command])

    func testExactModifiers() {
        XCTAssertTrue(HotkeyMatcher.matches(keyCode: 40, modifiers: [.control, .option, .shift, .command], key: KeyToken("k"), spec: hyper))
    }

    func testHyperKeyToleratesExtraModifier() {
        let withFunction = ModifierSet([.control, .option, .shift, .command])
        let spec = HotkeySpec(keyCode: 40, modifiers: [.control, .option, .command])
        XCTAssertTrue(HotkeyMatcher.matches(keyCode: 40, modifiers: withFunction, key: KeyToken("k"), spec: spec))
    }

    func testTwoModifierHotkeyIsStrict() {
        let spec = HotkeySpec(keyCode: 40, modifiers: [.command, .option])
        XCTAssertFalse(HotkeyMatcher.matches(keyCode: 40, modifiers: [.command, .option, .shift], key: KeyToken("k"), spec: spec))
    }

    func testWrongKeyCode() {
        XCTAssertFalse(HotkeyMatcher.matches(keyCode: 41, modifiers: [.command], key: KeyToken("k"), spec: HotkeySpec(keyCode: 40, modifiers: [.command])))
    }
}
