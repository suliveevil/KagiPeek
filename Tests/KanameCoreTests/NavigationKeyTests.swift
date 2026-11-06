import XCTest
@testable import KanameCore

final class NavigationKeyTests: XCTestCase {
    func testPlainArrows() {
        XCTAssertEqual(NavigationKey.direction(keyCode: 126, modifiers: []), .up)
        XCTAssertEqual(NavigationKey.direction(keyCode: 125, modifiers: []), .down)
        XCTAssertEqual(NavigationKey.direction(keyCode: 123, modifiers: []), .left)
        XCTAssertEqual(NavigationKey.direction(keyCode: 124, modifiers: []), .right)
    }

    func testEmacsStyleKeys() {
        XCTAssertEqual(NavigationKey.direction(keyCode: 35, modifiers: [.control]), .up)
        XCTAssertEqual(NavigationKey.direction(keyCode: 45, modifiers: [.control]), .down)
        XCTAssertEqual(NavigationKey.direction(keyCode: 11, modifiers: [.control]), .left)
        XCTAssertEqual(NavigationKey.direction(keyCode: 3, modifiers: [.control]), .right)
    }

    func testExtraModifiersAreNotNavigation() {
        XCTAssertNil(NavigationKey.direction(keyCode: 45, modifiers: [.control, .shift]))
        XCTAssertNil(NavigationKey.direction(keyCode: 3, modifiers: [.command]))
        XCTAssertNil(NavigationKey.direction(keyCode: 126, modifiers: [.option]))
    }

    func testUnrelatedKeys() {
        XCTAssertNil(NavigationKey.direction(keyCode: 0, modifiers: []))
        XCTAssertNil(NavigationKey.direction(keyCode: 0, modifiers: [.control]))
    }

    /// `/` 同样先看字符；没有字符（未解码的事件）才退回 ANSI 键码。
    func testSlashPrefersTheCharacterOverTheKeyCode() {
        XCTAssertTrue(NavigationKey.isSlash(keyCode: KeyCode.slash, modifiers: []))
        XCTAssertTrue(NavigationKey.isSlash(keyCode: 12, modifiers: [], characters: "/"))
        XCTAssertFalse(NavigationKey.isSlash(keyCode: KeyCode.slash, modifiers: [], characters: ":"))
        XCTAssertFalse(NavigationKey.isSlash(keyCode: KeyCode.slash, modifiers: [.command], characters: "/"))
    }
}
