import XCTest
@testable import KanameCore

final class KeyChordTests: XCTestCase {
    func testDescriptorParsing() {
        let chord = KeyChord(descriptor: "cmd+shift+3")
        XCTAssertEqual(chord.steps.count, 1)
        XCTAssertEqual(chord.steps[0].modifiers, [.command, .shift])
        XCTAssertEqual(chord.steps[0].key, KeyToken("3"))
        XCTAssertEqual(KeyFormatter.render(chord, style: .symbols), "⇧⌘3")
    }

    func testModifierOnlyPrefixIsCandidate() {
        let binding = KeyChord.combo([.command], KeyToken("c"))
        XCTAssertEqual(binding.relation(to: .modifiers([.command])), .candidate)
        XCTAssertEqual(binding.nextKey(after: .modifiers([.command])), KeyToken("c"))
    }

    func testNarrowingByAddingShift() {
        let plain = KeyChord.combo([.command], KeyToken("s"))
        let shifted = KeyChord.combo([.command, .shift], KeyToken("s"))
        let prefix = KeyChord.modifiers([.command, .shift])
        XCTAssertEqual(plain.relation(to: prefix), .unrelated)
        XCTAssertEqual(shifted.relation(to: prefix), .candidate)
    }

    func testChordDescent() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        let level1 = KeyChord.combo([.command], KeyToken("k"))
        let level2 = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        XCTAssertEqual(chord.relation(to: level1), .descend)
        XCTAssertEqual(chord.relation(to: level2), .exact)
        XCTAssertEqual(chord.nextKey(after: level1), KeyToken("c"))
        XCTAssertEqual(chord.remainingSteps(after: level1), 1)
        XCTAssertEqual(chord.relation(to: KeyChord.combo([.option], KeyToken("k"))), .unrelated)
    }

    /// Alternates are alternative *spellings* of the same physical key — `return` written on a
    /// binding that was recorded as `r`'s neighbour, and so on. The predicate that used to be
    /// tested here (`matchesKey`) ignored modifiers entirely, so it answered "yes" to a step
    /// whose only claim was that it named the same key; `matches` is the contract production
    /// actually consults, and it compares the modifier set as well.
    func testAlternatesAreAcceptedSpellingsOfTheSameKey() {
        let plain = KeyStep.combo([.command], KeyToken("r"))
        let withAlternate = KeyStep.combo(
            [.command],
            KeyToken("r"),
            alternates: [KeyToken("return")]
        )

        XCTAssertTrue(withAlternate.matches(KeyStep.combo([.command], KeyToken("return"))))
        XCTAssertTrue(withAlternate.matches(plain), "the recorded spelling still matches")
        XCTAssertTrue(plain.matches(withAlternate), "and the relation is symmetric")
        XCTAssertFalse(withAlternate.matches(KeyStep.combo([.command], KeyToken("t"))))
        XCTAssertFalse(
            withAlternate.matches(KeyStep.combo([.shift], KeyToken("return"))),
            "an alternate spelling does not excuse a different modifier set"
        )
    }

    func testDroppingLastStep() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        XCTAssertEqual(chord.droppingLastStep().steps.count, 1)
        XCTAssertEqual(KeyChord.empty.droppingLastStep(), .empty)
    }
}
