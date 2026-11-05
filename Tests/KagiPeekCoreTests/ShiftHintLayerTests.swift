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

    /// 提示层每页重新编号：超出本页行数的字号什么都不指向。
    /// 页 1 有 10 行时 Shift+A..Z（10…35）全部无效，不能执行下一页的行。
    func testPageScopedAddressingStopsAtTheLastVisibleRow() {
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "9", pageRowCount: 10), 9)
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "a", pageRowCount: 10))
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "o", pageRowCount: 10))
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "z", pageRowCount: 10))
    }

    /// 页 2 的编号从 0 开始，Shift+A 指向本页第 11 行，而不是页 1 的任何行。
    func testPageTwoNumberingRestartsWithItsOwnFirstRow() {
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "0", pageRowCount: 26), 0)
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "a", pageRowCount: 26), 10)
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "z", pageRowCount: 26))
    }
}
