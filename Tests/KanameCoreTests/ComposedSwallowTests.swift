import XCTest
@testable import KanameCore

/// The composed-stroke swallow decision, now answered on the tap thread from a published
/// snapshot. The rules are verbatim from the old `ShortcutEngine.shouldSwallowComposed`;
/// what the tests add is the contract with the snapshot: everything the decision reads is
/// in `ComposedSwallowState`, and nothing reaches for the engine or the main actor.
final class ComposedSwallowTests: XCTestCase {
    private let c = KeyToken("c")
    private let k = KeyToken("k")

    private func item(_ chord: KeyChord, _ title: String = "T") -> BindingItem {
        BindingItem(chord: chord, title: title, group: ["Edit"], source: .menu)
    }

    private var catalog: [BindingItem] {
        [
            item(.combo([.option, .command], c), "Option Command C"),
            item(.combo([.command], c), "Copy"),
            item(KeyChord([.combo([.command], k), .combo([.command], c)]), "Chord")
        ]
    }

    private func event(key: KeyToken?, keyCode: UInt16 = 8, modifiers: ModifierSet = []) -> KeyEvent {
        KeyEvent(kind: .keyDown, modifiers: modifiers, key: key, keyCode: keyCode, isRepeat: false, happenedAt: Date())
    }

    /// The active panel with a ticked ⌥⌘ and a press of C: the panel supplied the
    /// modifiers, so the event is consumed.
    func testComposedStrokeIsSwallowed() {
        var state = ComposedSwallowState()
        state.panelIsActive = true
        state.hasLatchedModifiers = true
        state.pending.latched = [.option, .command]
        state.catalogItems = catalog

        XCTAssertTrue(ComposedSwallow.decide(state, event: event(key: c)))
    }

    /// The guard rail: no ticked modifiers, no composed stroke, answer is no — the cheap
    /// refusal that keeps the decision free for every ordinary keystroke.
    func testWithoutLatchedModifiersNothingIsEverSwallowed() {
        var state = ComposedSwallowState()
        state.panelIsActive = true
        state.pending.latched = []
        state.catalogItems = catalog

        XCTAssertFalse(ComposedSwallow.decide(state, event: event(key: c, modifiers: [.option, .command])))
    }

    /// ⌥⌘M while ⌥⌘ is narrowing the list: the token queue is non-empty but the letter
    /// carries physical modifiers, so it belongs to a chord and has to reach the system.
    /// A bare letter is still filter input and must be eaten.
    func testModifiedLetterPassesThroughWhileFilterIsUp() {
        var state = ComposedSwallowState()
        state.panelIsActive = true
        state.filter = PanelFilter(tokens: [.modifier(.option), .modifier(.command)])
        state.catalogItems = catalog

        XCTAssertFalse(ComposedSwallow.decide(
            state,
            event: event(key: KeyToken("m"), modifiers: [.option, .command])
        ))
        XCTAssertTrue(ComposedSwallow.decide(state, event: event(key: KeyToken("m"))))
    }

    func testInactivePanelSwallowsNothing() {
        var state = ComposedSwallowState()
        state.panelIsActive = false
        state.hasLatchedModifiers = true
        state.pending.latched = .command
        state.catalogItems = catalog

        XCTAssertFalse(ComposedSwallow.decide(state, event: event(key: c)))
    }

    func testTheLiveTestNeverSwallows() {
        var state = ComposedSwallowState()
        state.isTestingShortcut = true
        state.panelIsActive = true
        state.hasLatchedModifiers = true
        state.pending.latched = .command
        state.catalogItems = catalog

        XCTAssertFalse(ComposedSwallow.decide(state, event: event(key: c)))
    }

    /// ⌫ while composing belongs to the panel (it undoes a tick): swallowed even though it
    /// is not part of any chord.
    func testBackspaceWhileComposingIsSwallowed() {
        var state = ComposedSwallowState()
        state.panelIsActive = true
        state.hasLatchedModifiers = true
        state.pending.latched = .command
        state.catalogItems = catalog

        XCTAssertTrue(ComposedSwallow.decide(state, event: event(key: .backspace, keyCode: KeyCode.delete)))
    }

    /// The panel's own navigation keys are refused before composition: a ticked ⌥ plus `;`
    /// pages the list, and `⌥;` remains a perfectly good binding.
    func testPanelNavigationIsNotTreatedAsAStroke() {
        var state = ComposedSwallowState()
        state.panelIsActive = true
        state.hasLatchedModifiers = true
        state.pending.latched = .option
        state.heldModifiers = []
        state.runRowKey = HotkeySpec(keyCode: 36, modifiers: [])  // Return
        state.copyRowKey = HotkeySpec(keyCode: 8, modifiers: [])   // C
        state.catalogItems = catalog

        // `;` pages the list, so even though ⌥; would complete nothing, it is not a stroke.
        XCTAssertFalse(ComposedSwallow.decide(state, event: event(key: KeyToken(";"), keyCode: KeyCode.semicolon)))
    }

    /// The second stroke of a chord, answered from the published prefix: the tap decides
    /// without the engine, which is the whole point of the snapshot.
    func testSecondStrokeOfAChordIsSwallowedFromThePublishedPrefix() {
        var state = ComposedSwallowState()
        state.panelIsActive = true
        state.hasLatchedModifiers = true
        state.prefix = .combo([.command], k)
        state.pending.latched = .command
        state.catalogItems = catalog

        // ⌘K ⌘C 的第二个笔画：C 的键码是 8，k 是 40；给 run/copy 不同的键码。
        XCTAssertTrue(ComposedSwallow.decide(state, event: event(key: c, keyCode: 8)))
    }

    /// A snapshot one event stale can only be wrong about one keystroke — here the chord
    /// that would have completed is missed because the prefix has not arrived yet. The
    /// point is not that this is good, but that it is the bounded worst case.
    func testAStaleSnapshotMissesAStrokeInsteadOfFreezing() {
        var state = ComposedSwallowState()
        state.panelIsActive = true
        state.hasLatchedModifiers = true
        state.prefix = .empty  // the ⌘K publish has not landed yet
        state.pending.latched = .command
        state.catalogItems = catalog

        // `z` 不在 catalog 里：⌘Z 不构成任何绑定，快照再旧也只会漏掉这一笔，不会误吞。
        XCTAssertFalse(ComposedSwallow.decide(state, event: event(key: KeyToken("z"), keyCode: 6)))
    }

    /// A tap of Shift raises the hint layer; the address that follows is a bare glyph. It
    /// has to be eaten or the front app receives a stray character.
    func testBareHintGlyphIsSwallowedWhileHintsAreUp() {
        var state = ComposedSwallowState()
        state.panelIsActive = true
        state.shiftHintsActive = true
        state.hintRowCount = 36

        XCTAssertTrue(ComposedSwallow.decide(state, event: event(key: KeyToken("0"))))
        XCTAssertTrue(ComposedSwallow.decide(state, event: event(key: KeyToken("a"))))
        XCTAssertTrue(ComposedSwallow.decide(state, event: event(key: KeyToken("z"))))
    }

    /// A glyph past the last visible row addresses nothing. Swallowing it would make the
    /// key vanish without running a row, so the tap and the key handler share one page
    /// boundary instead of each applying their own.
    func testGlyphPastThePageIsNotSwallowed() {
        var state = ComposedSwallowState()
        state.panelIsActive = true
        state.shiftHintsActive = true
        state.hintRowCount = 10

        XCTAssertTrue(ComposedSwallow.decide(state, event: event(key: KeyToken("9"))))
        XCTAssertFalse(ComposedSwallow.decide(state, event: event(key: KeyToken("a"))))
        XCTAssertFalse(ComposedSwallow.decide(state, event: event(key: KeyToken("z"))))
    }

    /// A press still carrying a modifier is not a hint address: Shift was tapped to raise
    /// the layer, not held into the addressing keystroke.
    func testModifiedGlyphIsNotABareHintAddress() {
        var state = ComposedSwallowState()
        state.panelIsActive = true
        state.shiftHintsActive = true
        state.hintRowCount = 36

        XCTAssertFalse(ComposedSwallow.decide(state, event: event(key: KeyToken("a"), modifiers: [.shift])))
    }

    /// With the panel closed (the search palette is its own surface) the glyph belongs to
    /// the text field, so nothing is swallowed even if a stale snapshot still says hints
    /// are up.
    func testHintLayerStaysOutOfTheSearchPalette() {
        var state = ComposedSwallowState()
        state.panelIsActive = false
        state.shiftHintsActive = true
        state.hintRowCount = 36

        XCTAssertFalse(ComposedSwallow.decide(state, event: event(key: KeyToken("a"))))
    }
}
