import XCTest
@testable import KanameCore

/// The token queue itself: order, toggling and ⌫.
final class PanelFilterTests: XCTestCase {
    func testTouchingTheSameModifierThreeTimesTogglesItBackInAtTheTail() {
        var filter = PanelFilter()
        filter.toggleModifier(.control)
        XCTAssertEqual(filter.tokens, [.modifier(.control)])
        XCTAssertEqual(filter.query, "⌃")

        filter.toggleModifier(.control)
        XCTAssertTrue(filter.isEmpty)

        filter.toggleModifier(.control)
        XCTAssertEqual(filter.tokens, [.modifier(.control)])
        XCTAssertEqual(filter.query, "⌃")
    }

    func testThirdPressBecomesTheTailEvenAfterALetter() {
        var filter = PanelFilter()
        filter.toggleModifier(.control)
        filter.appendLetter("f")
        filter.toggleModifier(.control)     // removes the ⌃ from the middle
        XCTAssertEqual(filter.query, "f")

        filter.toggleModifier(.control)     // a new token, at the tail
        XCTAssertEqual(filter.query, "f ⌃")
        XCTAssertEqual(filter.tokens, [.letter("f"), .modifier(.control)])
    }

    func testRemovingOneModifierLeavesTheOtherAlone() {
        var filter = PanelFilter()
        filter.toggleModifier(.control)
        filter.toggleModifier(.option)
        XCTAssertEqual(filter.modifiers, [.control, .option])

        filter.toggleModifier(.control)
        XCTAssertEqual(filter.modifiers, [.option])
        XCTAssertEqual(filter.tokens, [.modifier(.option)])
    }

    func testPoppingWorksFromTheTailAndYieldsModifiersInReverse() {
        var filter = PanelFilter()
        filter.toggleModifier(.control)
        filter.toggleModifier(.option)
        filter.appendLetter("f")

        XCTAssertEqual(filter.popLastToken(), .letter("f"))
        XCTAssertEqual(filter.popLastToken(), .modifier(.option))
        XCTAssertEqual(filter.popLastToken(), .modifier(.control))
        XCTAssertNil(filter.popLastToken())
        XCTAssertTrue(filter.isEmpty)
    }

    func testRemovingAMiddleModifierKeepsTheRemainingOrder() {
        var filter = PanelFilter()
        filter.toggleModifier(.control)
        filter.toggleModifier(.option)
        filter.toggleModifier(.command)
        XCTAssertEqual(filter.query, "⌃ ⌥ ⌘")

        filter.toggleModifier(.option)
        XCTAssertEqual(filter.tokens, [.modifier(.control), .modifier(.command)])
        XCTAssertEqual(filter.query, "⌃ ⌘")
    }

    func testClearResetsEverything() {
        var filter = PanelFilter()
        filter.toggleModifier(.control)
        filter.toggleModifier(.option)
        filter.appendLetter("f")
        XCTAssertFalse(filter.isEmpty)
        XCTAssertEqual(filter.query, "⌃ ⌥ f")

        filter.clear()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertEqual(filter.query, "")
        XCTAssertTrue(filter.modifiers.isEmpty)
        XCTAssertTrue(filter.letters.isEmpty)
    }
}
