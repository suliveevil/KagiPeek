import XCTest
@testable import KagiPeekCore

final class PagingKeyPlanTests: XCTestCase {
    /// Each of the four pairs maps its first character to previous and its second to next.
    func testEachPairMapsBothDirections() {
        let expected: [(PagingPair, Character, Character)] = [
            (.commaPeriod, ",", "."),
            (.brackets, "[", "]"),
            (.minusEqual, "-", "="),
            (.semicolonQuote, ";", "'")
        ]
        for (pair, previous, next) in expected {
            XCTAssertEqual(
                PagingKeyPlan.step(pairs: [pair], keyCode: 0, modifiers: [], characters: String(previous)),
                -1
            )
            XCTAssertEqual(
                PagingKeyPlan.step(pairs: [pair], keyCode: 0, modifiers: [], characters: String(next)),
                1
            )
        }
    }

    /// Default is the pair the app used to hard-code: `;` / `'`. Comma/period starts unchecked.
    func testDefaultIsSemicolonQuoteOnly() {
        XCTAssertEqual(AppSettingsSnapshot().pagingPairs, [.semicolonQuote])
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: [.semicolonQuote], keyCode: 0, modifiers: [], characters: ";"),
            -1
        )
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: [.semicolonQuote], keyCode: 0, modifiers: [], characters: "'"),
            1
        )
        XCTAssertNil(
            PagingKeyPlan.step(pairs: [.semicolonQuote], keyCode: 0, modifiers: [], characters: ",")
        )
    }

    /// All pairs unchecked: only the arrows page.
    func testEmptySetNoPaging() {
        for character in [",", ".", "[", "]", "-", "=", ";", "'"] {
            XCTAssertNil(PagingKeyPlan.step(pairs: [], keyCode: 0, modifiers: [], characters: character))
        }
    }

    /// Several pairs at once: all eight keys work and none swallows another.
    func testSeveralPairsAllKeysPage() {
        let pairs: Set<PagingPair> = [.commaPeriod, .semicolonQuote]
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: pairs, keyCode: 0, modifiers: [], characters: ","), -1
        )
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: pairs, keyCode: 0, modifiers: [], characters: "."), 1
        )
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: pairs, keyCode: 0, modifiers: [], characters: ";"), -1
        )
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: pairs, keyCode: 0, modifiers: [], characters: "'"), 1
        )
    }

    /// A Pinyin layout types full-width punctuation; the same physical key must still page.
    func testFullWidthPunctuationPages() {
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: [.semicolonQuote], keyCode: 0, modifiers: [], characters: "；"), -1
        )
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: [.commaPeriod], keyCode: 0, modifiers: [], characters: "，"), -1
        )
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: [.commaPeriod], keyCode: 0, modifiers: [], characters: "。"), 1
        )
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: [.brackets], keyCode: 0, modifiers: [], characters: "［"), -1
        )
    }

    /// A character-bearing event never falls back to the physical code: `,` typed on a key
    /// whose ANSI code is the semicolon must not page as `;`.
    func testCharacterBeatsTheKeyCode() {
        XCTAssertNil(
            PagingKeyPlan.step(
                pairs: [.semicolonQuote],
                keyCode: KeyCode.semicolon,
                modifiers: [],
                characters: ","
            )
        )
        XCTAssertEqual(
            PagingKeyPlan.step(
                pairs: [.semicolonQuote],
                keyCode: KeyCode.comma,
                modifiers: [],
                characters: ";"
            ),
            -1
        )
    }

    /// The physical fallback is only for events with no decoded character.
    func testPhysicalFallback() {
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: [.commaPeriod], keyCode: KeyCode.comma, modifiers: [], characters: nil),
            -1
        )
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: [.minusEqual], keyCode: KeyCode.equal, modifiers: [], characters: nil),
            1
        )
        XCTAssertNil(
            PagingKeyPlan.step(pairs: [.minusEqual], keyCode: KeyCode.equal, modifiers: [.shift], characters: nil)
        )
        XCTAssertNil(
            PagingKeyPlan.step(pairs: [.semicolonQuote], keyCode: KeyCode.comma, modifiers: [], characters: nil)
        )
    }

    /// ⌘/⌥/⌃ are shortcut layers and never page; Shift is tolerated so a layout that
    /// spells punctuation with it still works.
    func testModifierGuard() {
        XCTAssertNil(
            PagingKeyPlan.step(pairs: [.semicolonQuote], keyCode: 0, modifiers: [.command], characters: ";")
        )
        XCTAssertNil(
            PagingKeyPlan.step(pairs: [.semicolonQuote], keyCode: 0, modifiers: [.option], characters: ";")
        )
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: [.minusEqual], keyCode: 0, modifiers: [.shift], characters: "="),
            1
        )
    }

    /// `+` is not a paging character: Shift+= belongs to no pair and no hint label, so it
    /// neither pages nor is mistaken for a `0`–`9` / `a`–`z` label.
    func testShiftEqualsIsNeitherPageNorHint() {
        XCTAssertNil(
            PagingKeyPlan.step(pairs: [.minusEqual], keyCode: 0, modifiers: [.shift], characters: "+")
        )
        XCTAssertNil(PagingKeyPlan.step(pairs: [.minusEqual], keyCode: KeyCode.equal, modifiers: [.shift], characters: nil))
        XCTAssertNil(ShiftHintLayer.index(forCharacter: "+"))
        XCTAssertEqual(ShiftHintLayer.index(forCharacter: "9"), 9)
        // `=` itself still pages, including when a layout needs Shift to produce it.
        XCTAssertEqual(
            PagingKeyPlan.step(pairs: [.minusEqual], keyCode: 0, modifiers: [], characters: "="),
            1
        )
    }

    /// The capture set covers every enabled key, including the full-width spellings.
    func testCapturedCharactersCoverEnabledPairs() {
        let both = PagingKeyPlan.characters(for: [.semicolonQuote, .commaPeriod])
        XCTAssertTrue(both.contains(";"))
        XCTAssertTrue(both.contains("；"))
        XCTAssertTrue(both.contains("'"))
        XCTAssertTrue(both.contains(","))
        XCTAssertTrue(both.contains("，"))

        let none = PagingKeyPlan.characters(for: [])
        XCTAssertTrue(none.isEmpty)
    }
}
