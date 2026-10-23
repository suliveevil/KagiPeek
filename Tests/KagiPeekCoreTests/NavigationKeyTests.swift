import XCTest
@testable import KagiPeekCore

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

    func testSemicolonAndQuotePage() {
        XCTAssertEqual(NavigationKey.pageStep(keyCode: 41, modifiers: []), -1)
        XCTAssertEqual(NavigationKey.pageStep(keyCode: 39, modifiers: []), 1)
        XCTAssertNil(NavigationKey.pageStep(keyCode: 41, modifiers: [.shift]))
        XCTAssertNil(NavigationKey.pageStep(keyCode: 40, modifiers: []))
    }
}
