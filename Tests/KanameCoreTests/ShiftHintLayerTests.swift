import XCTest
@testable import KanameCore

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
        // Caps Lock, or a layout that reports capitals, must still name the same row.
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "A"), ShiftHintLayer.index(forCharacter: "a"))
    }

    func testCharactersOutsideTheTableAnswerNil() {
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "!"))
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "Return"))
        XCTAssertNil(ShiftHintLayer.index(forCharacter: ""))
    }

    /// 提示层每页重新编号：超出本页行数的字号什么都不指向。
    /// 页 1 有 10 行时 a..z（10…35）全部无效，不能执行下一页的行。
    func testPageScopedAddressingStopsAtTheLastVisibleRow() {
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "9", pageRowCount: 10), 9)
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "a", pageRowCount: 10))
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "o", pageRowCount: 10))
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "z", pageRowCount: 10))
    }

    /// 页 2 的编号从 0 开始，a 指向本页第 11 行，而不是页 1 的任何行。
    func testPageTwoNumberingRestartsWithItsOwnFirstRow() {
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "0", pageRowCount: 26), 0)
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "a", pageRowCount: 26), 10)
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "z", pageRowCount: 26))
    }

    // MARK: - Event addressing

    private func hintEvent(
        _ key: KeyToken?,
        keyCode: UInt16,
        modifiers: ModifierSet = []
    ) -> KeyEvent {
        KeyEvent(
            kind: .keyDown,
            modifiers: modifiers,
            key: key,
            keyCode: keyCode,
            isRepeat: false,
            happenedAt: Date()
        )
    }

    /// A tap of Shift raises the labels; the address that follows is a bare glyph.
    func testEventAddressesRowsByTheirBareGlyph() {
        XCTAssertEqual(ShiftHintLayer.index(for: hintEvent(KeyToken("0"), keyCode: 0x1D), pageRowCount: 36), 0)
        XCTAssertEqual(ShiftHintLayer.index(for: hintEvent(KeyToken("9"), keyCode: 0x19), pageRowCount: 36), 9)
        XCTAssertEqual(ShiftHintLayer.index(for: hintEvent(KeyToken("a"), keyCode: 0x00), pageRowCount: 36), 10)
        XCTAssertEqual(ShiftHintLayer.index(for: hintEvent(KeyToken("z"), keyCode: 0x06), pageRowCount: 36), 35)
    }

    /// A press that decodes no character still names a row through its virtual key code.
    func testEventWithoutACharacterFallsBackToThePhysicalKey() {
        XCTAssertEqual(ShiftHintLayer.index(for: hintEvent(nil, keyCode: 0x12), pageRowCount: 36), 1)
        XCTAssertEqual(ShiftHintLayer.index(for: hintEvent(nil, keyCode: 0x00), pageRowCount: 36), 10)
    }

    /// A character that is not a label — a shifted punctuation mark, or a non-ANSI
    /// layout's spelling of the digit key — falls back to the key the finger hit.
    func testNonLabelCharacterFallsBackToThePhysicalKey() {
        XCTAssertEqual(ShiftHintLayer.index(for: hintEvent(KeyToken("!"), keyCode: 0x12), pageRowCount: 36), 1)
        XCTAssertNil(ShiftHintLayer.index(for: hintEvent(KeyToken("!"), keyCode: 0x24), pageRowCount: 36))
    }

    /// Page scoping applies to the event resolver too: the tap's swallow decision and the
    /// engine's row lookup must agree about a glyph past the last visible row.
    func testEventAddressingStopsAtTheLastVisibleRow() {
        XCTAssertEqual(ShiftHintLayer.index(for: hintEvent(KeyToken("9"), keyCode: 0x19), pageRowCount: 10), 9)
        XCTAssertNil(ShiftHintLayer.index(for: hintEvent(KeyToken("a"), keyCode: 0x00), pageRowCount: 10))
    }
}
