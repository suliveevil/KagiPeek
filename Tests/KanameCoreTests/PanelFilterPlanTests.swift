import XCTest
@testable import KanameCore

/// The filter's key decisions: what a key-down appends or pops, and which rows survive.
final class PanelFilterPlanTests: XCTestCase {
    private let fill = BindingItem(
        chord: .combo([.function, .control], KeyToken("f")),
        title: "填充",
        group: ["System"],
        source: .system
    )

    private let print = BindingItem(
        chord: .combo([.command], KeyToken("p")),
        title: "打印",
        group: ["Edit"],
        source: .menu
    )

    private var items: [BindingItem] { [fill, print] }

    private var corpus: SearchCorpus {
        SearchCorpus(items: items, style: .symbols)
    }

    private func event(
        _ key: KeyToken?,
        keyCode: UInt16 = 3,
        modifiers: ModifierSet = [],
        kind: KeyEventKind = .keyDown,
        isRepeat: Bool = false
    ) -> KeyEvent {
        KeyEvent(
            kind: kind,
            modifiers: modifiers,
            key: key,
            keyCode: keyCode,
            isRepeat: isRepeat,
            happenedAt: Date()
        )
    }

    private func decision(
        _ event: KeyEvent,
        filter: PanelFilter,
        phase: EnginePhase = .active,
        shiftHintActive: Bool = false,
        triggerPending: Bool = false
    ) -> PanelFilterPlan.Decision {
        PanelFilterPlan.decision(
            for: event,
            filter: filter,
            phase: phase,
            shiftHintActive: shiftHintActive,
            triggerPending: triggerPending,
            triggerKey: .rightCommand
        )
    }

    private func filter(_ modifiers: [ModifierSet], letters: [Character] = []) -> PanelFilter {
        var filter = PanelFilter()
        for modifier in modifiers { filter.toggleModifier(modifier) }
        for letter in letters { filter.appendLetter(letter) }
        return filter
    }

    func testControlThenFMatchesTheControlFShortcutOnly() {
        let ids = PanelFilterPlan.matchingIDs(
            filter: filter([.control], letters: ["f"]),
            corpus: corpus
        )
        XCTAssertEqual(ids, [fill.id])
        XCTAssertEqual(ids?.contains(print.id), false)
    }

    func testReleasingTheModifierLeavesTheLatchedFilterAlone() {
        let latched = filter([.control])
        let before = latched

        // A release carries no key token; the decision must not mutate the queue.
        _ = decision(event(nil, keyCode: 59, kind: .keyUp), filter: latched)

        XCTAssertEqual(latched, before)
        XCTAssertEqual(latched.query, "⌃")
    }

    func testBackspacePopsTheTailOneTokenAtATime() {
        var queue = filter([.control, .option], letters: ["f"])
        XCTAssertEqual(queue.query, "⌃ ⌥ f")

        XCTAssertEqual(decision(event(KeyToken("delete"), keyCode: KeyCode.delete), filter: queue), .popToken)
        queue.popLastToken()
        XCTAssertEqual(queue.query, "⌃ ⌥")

        XCTAssertEqual(decision(event(KeyToken("delete"), keyCode: KeyCode.delete), filter: queue), .popToken)
        queue.popLastToken()
        XCTAssertEqual(queue.query, "⌃")

        XCTAssertEqual(decision(event(KeyToken("delete"), keyCode: KeyCode.delete), filter: queue), .popToken)
        queue.popLastToken()
        XCTAssertTrue(queue.isEmpty)

        // With nothing left to pop, ⌫ belongs to the old "go up a level" path.
        XCTAssertEqual(decision(event(KeyToken("delete"), keyCode: KeyCode.delete), filter: queue), .none)
    }

    func testEmptyFilterMeansNoFilteringAndPageZero() {
        XCTAssertNil(PanelFilterPlan.matchingIDs(filter: PanelFilter(), corpus: corpus))
        XCTAssertEqual(PaginationPlan.clamped(3, pageCount: 2), 1)
    }

    func testShiftHintLayerOwnsTheGlyph() {
        let active = filter([.control])
        // A bare letter is a row address while hints are up, not another filter token.
        XCTAssertEqual(
            decision(event(KeyToken("f")), filter: active, shiftHintActive: true),
            .none
        )
        // With hints off the same letter belongs to the filter again: the guard is what
        // keeps the two layers from fighting over it.
        XCTAssertEqual(decision(event(KeyToken("f")), filter: active), .append("f"))
    }

    func testSearchPaletteAndIdlePhasesDoNotFilter() {
        let active = filter([.control])
        XCTAssertEqual(decision(event(KeyToken("f")), filter: active, phase: .idle), .none)
        XCTAssertEqual(decision(event(KeyToken("f")), filter: active, phase: .armed), .none)
    }

    func testNavigationAndPageKeysAreNeverFilterInput() {
        let active = filter([.control])
        for keyCode in [KeyCode.left, KeyCode.right, KeyCode.semicolon, KeyCode.quote] {
            XCTAssertEqual(decision(event(nil, keyCode: keyCode), filter: active), .none)
        }
    }

    func testTogglingTheSameModifierOffAndOnAgainStillAppendsTheLetter() {
        var queue = PanelFilter()
        queue.toggleModifier(.control)
        queue.toggleModifier(.control)   // off
        queue.toggleModifier(.control)   // back on, at the tail

        // Filter letters are bare: the modifier was released before F was typed.
        XCTAssertEqual(decision(event(KeyToken("f")), filter: queue), .append("f"))
        queue.appendLetter("f")
        XCTAssertEqual(queue.query, "⌃ f")
    }

    /// A letter pressed while the narrowing modifiers are still physically down is a chord,
    /// not the next filter token. ⌥⌘M is "Minimize All": the queue used to claim `m`
    /// because `filter.modifiers` held ⌥ and ⌘, so the tap swallowed a keystroke the
    /// system never saw and the panel had no row to complete.
    func testModifiedLetterIsAChordNotAFilterToken() {
        let narrowed = filter([.option, .command])
        XCTAssertEqual(
            decision(event(KeyToken("m"), modifiers: [.option, .command]), filter: narrowed),
            .none
        )
        // Released first, the same letter is filter input again.
        XCTAssertEqual(decision(event(KeyToken("m")), filter: narrowed), .append("m"))
        // A modifier the filter does not hold was always a chord and still is.
        XCTAssertEqual(
            decision(event(KeyToken("m"), modifiers: [.command, .control]), filter: narrowed),
            .none
        )
    }

    /// Shift is the hint layer, not a filter dimension: a capital letter is still a letter.
    /// `KeyToken` lowercases it, so the queue stores "f" either way.
    func testShiftStillAllowsAFilterLetter() {
        XCTAssertEqual(
            decision(event(KeyToken("F"), modifiers: [.shift]), filter: filter([.control])),
            .append("f")
        )
    }

    func testBareLetterWithAnEmptyFilterStaysAChordStroke() {
        XCTAssertEqual(decision(event(KeyToken("f")), filter: PanelFilter()), .none)
        XCTAssertEqual(decision(event(KeyToken("c"), modifiers: [.command]), filter: PanelFilter()), .none)
    }

    func testBackspaceWithAnEmptyFilterBelongsToTheOldRoute() {
        XCTAssertEqual(
            decision(event(KeyToken("delete"), keyCode: KeyCode.delete), filter: PanelFilter()),
            .none
        )
    }

    func testExtraCommandIsNotSteppedOn() {
        let active = filter([.control])
        XCTAssertEqual(
            decision(event(KeyToken("f"), modifiers: [.control, .command]), filter: active),
            .none
        )
    }
}
