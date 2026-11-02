import XCTest
@testable import KagiPeekCore

final class KeyMapperTests: XCTestCase {
    func testSpecialKeys() {
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(123)), KeyToken("left"))
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(122)), KeyToken("f1"))
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(51)), KeyToken("delete"))
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(49)), KeyToken("space"))
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(53)), KeyToken("esc"))
    }

    func testOptionUsesPhysicalKey() {
        let token = KeyMapper.token(keyCode: UInt16(15), unicode: "´", modifiers: [.option])
        XCTAssertEqual(token, KeyToken("r"))
        let plain = KeyMapper.token(keyCode: UInt16(15), unicode: "r", modifiers: [])
        XCTAssertEqual(plain, KeyToken("r"))
    }

    func testPrivateUseCharactersAreRejected() {
        XCTAssertNil(KeyMapper.normalize(character: "\u{F700}"))
    }

    /// 真实按下 Esc 时事件带的是 U+001B，不是 "esc"。字符优先、键码兜底的顺序必须
    /// 让控制字符落到键码上，否则面板永远认不出 Esc（也就永远关不掉）。
    func testLiveEscapeResolvesToEscToken() {
        XCTAssertEqual(KeyMapper.token(keyCode: 53, unicode: "\u{1B}", modifiers: []), KeyToken("esc"))
    }

    /// 同一条路上的其它非打印键：Tab / Return / Delete 各自也带一个控制字符。
    func testOtherControlCharactersFallBackToKeyCode() {
        XCTAssertEqual(KeyMapper.token(keyCode: 48, unicode: "\u{9}", modifiers: []), KeyToken("tab"))
        XCTAssertEqual(KeyMapper.token(keyCode: 36, unicode: "\r", modifiers: []), KeyToken("return"))
        XCTAssertEqual(KeyMapper.token(keyCode: 51, unicode: "\u{7F}", modifiers: []), KeyToken("delete"))
    }
}
