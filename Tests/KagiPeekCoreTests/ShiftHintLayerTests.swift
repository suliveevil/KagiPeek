import XCTest
@testable import KagiPeekCore

final class ShiftHintLayerTests: XCTestCase {
    func testLabelsRunFromZeroToNineThenALetter() {
        XCTAssertEqual(ShiftHintLayer.labels.count, 36)
        XCTAssertEqual(ShiftHintLayer.label(forIndex: 0), "0")
        XCTAssertEqual(ShiftHintLayer.label(forIndex: 9), "9")
        XCTAssertEqual(ShiftHintLayer.label(forIndex: 10), "a")
        XCTAssertEqual(ShiftHintLayer.label(forIndex: 35), "z")
    }

    func testPositionsPastTheTableHaveNoLabel() {
        XCTAssertNil(ShiftHintLayer.label(forIndex: 36))
        XCTAssertNil(ShiftHintLayer.label(forIndex: -1))
    }

    func testCharactersMapBackToTheirPosition() {
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "0"), 0)
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "9"), 9)
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "a"), 10)
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "z"), 35)
    }

    func testUpperAndLowerCaseAddressTheSameRow() {
        // The tap reports what the physical keyboard produced; Shift+A is a capital.
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "A"), ShiftHintLayer.index(forCharacter: "a"))
    }

    func testCharactersOutsideTheTableAnswerNil() {
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "!"))
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "Return"))
        XCTAssertNil(ShiftHintLayer.index(forCharacter: ""))
    }
}
