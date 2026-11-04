import XCTest
@testable import KagiPeekCore

/// The decision every keystroke of every session passes through: does the tap eat it?
///
/// These are the cases that used to be unanswerable — the logic lived inside a class that
/// owns a run loop and a thread, so nothing could construct the situation. The three
/// channels and the tolerant-rule branch are each pinned here, because getting any of them
/// wrong is invisible: the shortcut stops firing, or the front app gets a key it never
/// asked for.
final class KeySwallowRulesTests: XCTestCase {
    // MARK: - The cheap refusal

    func testNothingCapturedMeansNothingSwallowed() {
        let rules = KeySwallowRules()
        XCTAssertTrue(rules.isEmpty)
        XCTAssertFalse(rules.shouldSwallow(keyCode: 8, modifiers: [.command]))
    }

    /// Escape is captured by key code with no rules and no identifiers around it. A guard
    /// that only looked at rules and identifiers would return false here and Escape would
    /// start reaching the front app — the bug this channel exists to prevent.
    func testKeyCodeChannelAloneIsEnough() {
        var rules = KeySwallowRules()
        rules.capturedKeyCodes = [KeyCode.escape]
        XCTAssertFalse(rules.isEmpty)
        XCTAssertTrue(rules.shouldSwallow(keyCode: KeyCode.escape, modifiers: []))
        XCTAssertTrue(rules.shouldSwallow(keyCode: KeyCode.escape, modifiers: [.shift]))
        XCTAssertFalse(rules.shouldSwallow(keyCode: KeyCode.delete, modifiers: []))
    }

    // MARK: - Identifiers

    func testIdentifierChannelIsModifierSensitive() {
        var rules = KeySwallowRules()
        rules.capturedIdentifiers = [
            KeySwallowRules.identifier(keyCode: KeyCode.slash, modifiers: [])
        ]
        XCTAssertTrue(rules.shouldSwallow(keyCode: KeyCode.slash, modifiers: []))
        // `⌥;` is a real binding, so a captured plain `;` must not eat it.
        XCTAssertFalse(rules.shouldSwallow(keyCode: KeyCode.slash, modifiers: [.option]))
    }

    /// Two events that differ only in modifiers must not share an identifier.
    func testIdentifierSeparatesModifierMasks() {
        let plain = KeySwallowRules.identifier(keyCode: 40, modifiers: [])
        let command = KeySwallowRules.identifier(keyCode: 40, modifiers: [.command])
        let option = KeySwallowRules.identifier(keyCode: 40, modifiers: [.option])
        XCTAssertNotEqual(plain, command)
        XCTAssertNotEqual(command, option)
        XCTAssertEqual(command, KeySwallowRules.identifier(keyCode: 40, modifiers: [.command]))
    }

    func testDifferentKeyCodesWithTheSameModifiersDiffer() {
        XCTAssertNotEqual(
            KeySwallowRules.identifier(keyCode: 8, modifiers: [.command]),
            KeySwallowRules.identifier(keyCode: 9, modifiers: [.command])
        )
    }

    // MARK: - Rules

    func testExactRuleMatchesOnlyTheRecordedSpelling() {
        let rules = KeySwallowRules(
            rules: [SwallowRule(keyCode: 40, modifiers: [.command], tolerant: false)]
        )
        XCTAssertTrue(rules.shouldSwallow(keyCode: 40, modifiers: [.command]))
        XCTAssertFalse(rules.shouldSwallow(keyCode: 40, modifiers: [.command, .shift]))
        XCTAssertFalse(rules.shouldSwallow(keyCode: 41, modifiers: [.command]))
    }

    func testTolerantRuleAcceptsASuperset() {
        let rules = KeySwallowRules(
            rules: [SwallowRule(keyCode: 8, modifiers: [.command], tolerant: true)]
        )
        XCTAssertTrue(rules.shouldSwallow(keyCode: 8, modifiers: [.command, .shift]))
        // A superset, not an overlap: ⌘ without the recorded ⌥ is a different binding.
        XCTAssertFalse(
            KeySwallowRules(rules: [SwallowRule(keyCode: 8, modifiers: [.command, .option], tolerant: true)])
                .shouldSwallow(keyCode: 8, modifiers: [.command])
        )
    }

    /// A tolerant rule only widens its own key code — it must not become a wildcard.
    func testTolerantRuleDoesNotLeakToOtherKeys() {
        let rules = KeySwallowRules(
            rules: [SwallowRule(keyCode: 8, modifiers: [], tolerant: true)]
        )
        XCTAssertFalse(rules.shouldSwallow(keyCode: 9, modifiers: [.command]))
    }

    /// The character channel exists for layouts that type something other than ASCII: the
    /// semicolon key on a Pinyin layout sends `；`, and the tap must eat it, not pass it to
    /// the front app while the panel pages.
    func testCharacterChannelFoldsCJKPunctuation() {
        var rules = KeySwallowRules()
        rules.capturedCharacters = PagingKeyPlan.characters(for: [.semicolonQuote, .commaPeriod])
        XCTAssertFalse(rules.isEmpty)
        XCTAssertTrue(rules.shouldSwallow(keyCode: KeyCode.semicolon, modifiers: [], characters: "；"))
        XCTAssertTrue(rules.shouldSwallow(keyCode: KeyCode.comma, modifiers: [], characters: "，"))
        XCTAssertTrue(rules.shouldSwallow(keyCode: KeyCode.comma, modifiers: [], characters: ","))
        // A shortcut layer is not the paging key, even if the character is the same.
        XCTAssertFalse(
            rules.shouldSwallow(keyCode: KeyCode.semicolon, modifiers: [.command], characters: ";")
        )
        // `=` is the unshifted page key; `+` (Shift+=) is not part of any pair.
        rules.capturedCharacters.formUnion(PagingKeyPlan.characters(for: [.minusEqual]))
        XCTAssertTrue(rules.shouldSwallow(keyCode: KeyCode.equal, modifiers: [], characters: "="))
        XCTAssertFalse(rules.shouldSwallow(keyCode: KeyCode.equal, modifiers: [.shift], characters: "+"))
    }

    func testRulesAndCapturesAreIndependentChannels() {
        var rules = KeySwallowRules(
            rules: [SwallowRule(keyCode: 8, modifiers: [.command], tolerant: false)]
        )
        rules.capturedKeyCodes = [KeyCode.escape]
        rules.capturedIdentifiers = [
            KeySwallowRules.identifier(keyCode: KeyCode.down, modifiers: [])
        ]
        XCTAssertTrue(rules.shouldSwallow(keyCode: 8, modifiers: [.command]))
        XCTAssertTrue(rules.shouldSwallow(keyCode: KeyCode.escape, modifiers: []))
        XCTAssertTrue(rules.shouldSwallow(keyCode: KeyCode.down, modifiers: []))
        XCTAssertFalse(rules.shouldSwallow(keyCode: KeyCode.up, modifiers: []))
    }
}
