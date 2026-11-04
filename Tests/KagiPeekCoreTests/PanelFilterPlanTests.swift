import XCTest
@testable import KagiPeekCore

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
        XCTAssertEqual(
            decision(event(KeyToken("f"), modifiers: [.shift]), filter: active, shiftHintActive: true),
            .none
        )
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

        XCTAssertEqual(decision(event(KeyToken("f"), modifiers: [.control]), filter: queue), .append("f"))
        queue.appendLetter("f")
        XCTAssertEqual(queue.query, "⌃ f")
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
