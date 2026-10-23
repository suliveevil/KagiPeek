import XCTest
@testable import KagiPeekCore

/// The two halves of a stroke: what is physically down and what was ticked in the title bar.
///
/// The pair matters because the distinction is what answers "does this key have to be
/// swallowed?" — and answering that wrong runs a shortcut twice. So the two are never merged
/// into one set here, and `effective` is the only place the lone-⇧ rule applies.
final class PendingModifiersTests: XCTestCase {
    private func mods(_ members: ModifierSet...) -> ModifierSet {
        members.reduce(ModifierSet(rawValue: 0)) { $0.union($1) }
    }

    func testHeldIsWhatIsDown() {
        var pending = PendingModifiers()
        pending.held = .command
        XCTAssertEqual(pending.effective, .command)
        XCTAssertEqual(pending.union, .command)
    }

    /// A lone ⇧ arrives with every capital letter, so a *held* ⇧ is not a decision to narrow.
    func testLoneShiftIsIgnoredWhenHeld() {
        var pending = PendingModifiers()
        pending.held = .shift
        XCTAssertTrue(pending.effective.isEmpty)
        // The raw union still knows about it: a chord is built from what was pressed.
        XCTAssertEqual(pending.union, .shift)
    }

    /// A ⇧ the user clicked is explicit, so it counts.
    func testLatchedShiftCounts() {
        var pending = PendingModifiers()
        pending.latched = .shift
        XCTAssertEqual(pending.effective, .shift)
    }

    func testLatchedSurvivesThePhysicalKeyBeingReleased() {
        var pending = PendingModifiers()
        pending.held = [.option, .command]
        pending.latched = [.option, .command]
        pending.held = []
        XCTAssertEqual(pending.effective, [.option, .command])
    }

    func testHeldAndLatchedCombine() {
        var pending = PendingModifiers()
        pending.held = .command
        pending.latched = .option
        XCTAssertEqual(pending.effective, [.option, .command])
    }

    /// Ticking is owned by `LatchedTicks` now, because ⌫ has to undo the *last tick* and a
    /// set cannot say which that was — see `LatchedTicksTests`.

    func testEquatable() {
        XCTAssertEqual(PendingModifiers(), PendingModifiers())
        XCTAssertNotEqual(PendingModifiers(held: .command), PendingModifiers(latched: .command))
    }
}

/// Assembling a stroke from a tick plus a key press.
///
/// The load-bearing case is the second one below: an *ordinary* ⌥⌘C must come out as
/// `composed == false`, because that is what keeps the event passing through to the front app
/// exactly as it always has. Getting it wrong swallows keys the user never asked the panel to
/// touch.
final class ChordCompositionTests: XCTestCase {
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

    /// Click ⌥, click ⌘, press C → ⌥⌘C, and the panel supplied the modifiers.
    func testTickedModifiersComposeTheStroke() {
        var pending = PendingModifiers()
        pending.latched = [.option, .command]
        let resolution = ChordComposition.resolve(
            prefix: .empty, physical: [], pending: pending, key: c, in: catalog
        )
        guard case .complete(let hit) = resolution.outcome else {
            return XCTFail("expected a complete stroke, got \(resolution.outcome)")
        }
        XCTAssertEqual(hit.title, "Option Command C")
        XCTAssertEqual(resolution.probe, .combo([.option, .command], c))
        XCTAssertTrue(resolution.composed)
        // What the HUD shows: the assembled chord, never the bare key.
        XCTAssertEqual(resolution.displayChord, .combo([.option, .command], c))
        XCTAssertTrue(resolution.shouldSwallow)
    }

    /// The guard rail: physically holding ⌥⌘ and pressing C is *not* composed, so the key
    /// passes through untouched and nothing is injected.
    func testPhysicalModifiersAreNotComposed() {
        let pending = PendingModifiers()
        let resolution = ChordComposition.resolve(
            prefix: .empty, physical: [.option, .command], pending: pending, key: c, in: catalog
        )
        guard case .complete(let hit) = resolution.outcome else {
            return XCTFail("expected a complete stroke, got \(resolution.outcome)")
        }
        XCTAssertEqual(hit.title, "Option Command C")
        XCTAssertFalse(resolution.composed)
        XCTAssertFalse(resolution.shouldSwallow)
    }

    /// Holding every latched modifier as well is still an ordinary press: the panel is not
    /// contributing anything the event does not already carry.
    func testLatchedModifiersThatAreAlsoHeldAreNotComposed() {
        var pending = PendingModifiers()
        pending.latched = [.option, .command]
        pending.held = [.option, .command]
        let resolution = ChordComposition.resolve(
            prefix: .empty, physical: [.option, .command], pending: pending, key: c, in: catalog
        )
        XCTAssertFalse(resolution.composed)
        XCTAssertFalse(resolution.shouldSwallow)
    }

    /// A ticked ⌘ plus C on the second level of a chord completes ⌘K ⌘C.
    func testTickedModifierCompletesTheLastStrokeOfAChord() {
        var pending = PendingModifiers()
        pending.latched = .command
        let resolution = ChordComposition.resolve(
            prefix: .combo([.command], k), physical: [], pending: pending, key: c, in: catalog
        )
        guard case .complete(let hit) = resolution.outcome else {
            return XCTFail("expected a complete stroke, got \(resolution.outcome)")
        }
        XCTAssertEqual(hit.title, "Chord")
        XCTAssertEqual(resolution.probe, KeyChord([.combo([.command], k), .combo([.command], c)]))
        XCTAssertTrue(resolution.composed)
    }

    /// A ticked ⌘ plus K opens the ⌘K level rather than completing anything.
    func testTickedModifierCanDescend() {
        var pending = PendingModifiers()
        pending.latched = .command
        let resolution = ChordComposition.resolve(
            prefix: .empty, physical: [], pending: pending, key: k, in: catalog
        )
        XCTAssertEqual(resolution.outcome, .descend)
        XCTAssertEqual(resolution.probe, .combo([.command], k))
        XCTAssertTrue(resolution.composed)
        XCTAssertTrue(resolution.shouldSwallow)
    }

    /// A ticked modifier that matches nothing leaves the sequence alone: the key is not
    /// swallowed, so the app still receives it and the user does not lose the press.
    func testNoMatchKeepsTheTickAndDoesNotSwallow() {
        var pending = PendingModifiers()
        pending.latched = .control
        let resolution = ChordComposition.resolve(
            prefix: .empty, physical: [], pending: pending, key: c, in: catalog
        )
        XCTAssertEqual(resolution.outcome, .noMatch)
        XCTAssertTrue(resolution.composed)
        XCTAssertFalse(resolution.shouldSwallow)
    }

    func shouldSwallow(_ composed: Bool, _ outcome: ChordComposition.Outcome) -> Bool {
        ChordComposition.Resolution(probe: .empty, outcome: outcome, composed: composed).shouldSwallow
    }

    /// The whole truth table in one place: composed alone is not enough, a match is required.
    func testShouldSwallowTruthTable() {
        let complete = ChordComposition.Outcome.complete(item(.combo([.command], c)))
        XCTAssertTrue(shouldSwallow(true, complete))
        XCTAssertTrue(shouldSwallow(true, .descend))
        XCTAssertFalse(shouldSwallow(true, .noMatch))
        XCTAssertFalse(shouldSwallow(false, complete))
        XCTAssertFalse(shouldSwallow(false, .descend))
        XCTAssertFalse(shouldSwallow(false, .noMatch))
    }
}

/// Narrowing must keep working exactly as it did, with or without a tick.
final class NarrowingStillWorksTests: XCTestCase {
    private func item(_ chord: KeyChord) -> BindingItem {
        BindingItem(chord: chord, title: "T", group: ["Edit"], source: .menu)
    }

    /// Holding ⌘ keeps ⇧⌘A: the rule is "carries every held modifier", not "equals it".
    func testHeldModifiersNarrowBySuperset() {
        let items = [
            item(.combo([.command], KeyToken("c"))),
            item(.combo([.command, .shift], KeyToken("a")))
        ]
        let hits = PrefixResolver.hits(for: .modifiers([.command]), in: items)
        XCTAssertEqual(hits.count, 2)
    }

    /// Ticking ⌥ narrows the same way — it is the same modifier-only prefix, one source
    /// transient and one sticky.
    func testLatchedModifiersNarrowTheSameWay() {
        let items = [
            item(.combo([.option], KeyToken("c"))),
            item(.combo([.command], KeyToken("c")))
        ]
        var pending = PendingModifiers()
        pending.latched = .option
        let hits = PrefixResolver.hits(for: .modifiers(pending.effective), in: items)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].item.chord, .combo([.option], KeyToken("c")))
    }
}

/// The keys the panel consumes as itself, which the event tap has to leave alone.
///
/// This is the seam where a ticked modifier could eat a key press. A ticked ⌥ is not in the
/// event, so `;` arrives carrying nothing and `⌥;` is a real binding — the composition would
/// swallow it as the first stroke of `⌥;` while the engine pages the list. Both sides read
/// this one list, so these cases pin it.
final class PanelKeyIntakeTests: XCTestCase {
    private let run = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [])
    private let copy = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.command])

    private func intake(
        _ keyCode: UInt16,
        modifiers: ModifierSet = [],
        held: ModifierSet = []
    ) -> Bool {
        PanelKeyIntake.isConsumedBeforeComposition(
            keyCode: keyCode, modifiers: modifiers, held: held, run: run, copy: copy
        )
    }

    /// The bug this list exists for: `⌥;` is a binding, but the `;` was pressed to page.
    ///
    /// The two spellings of "⌥ is down" behave differently on purpose, and the difference is
    /// the whole point of the tick:
    ///
    /// - **ticked** — the modifier is in the panel, not in the event, so `;` arrives bare and
    ///   *is* a page key. Without this list the tap would swallow it as `⌥;` while the engine
    ///   paged, and the press would vanish.
    /// - **held** — the modifier is in the event, so `;` is not a page key and the
    ///   composition is free to run `⌥;`. That is the ordinary shortcut path, untouched.
    func testPageKeyIsIntakeWhenTheModifierIsTicked() {
        // Ticked: the event carries nothing.
        XCTAssertTrue(intake(KeyCode.semicolon))
        XCTAssertTrue(intake(KeyCode.quote))
        // Held and stripped back out — the event carried ⌥ and the user is holding it.
        XCTAssertTrue(intake(KeyCode.semicolon, modifiers: [.option], held: [.option]))
        // Held and *not* stripped: a physical ⌥ the panel does not know about is part of the
        // stroke, so `;` is not navigation and must not be claimed here.
        XCTAssertFalse(intake(KeyCode.semicolon, modifiers: [.option]))
    }

    func testArrowsAreIntake() {
        for keyCode in KeyCode.arrows {
            XCTAssertTrue(intake(keyCode))
        }
        // ⌃F and friends are the Emacs spellings of the arrows.
        XCTAssertTrue(intake(KeyCode.ctrlF, modifiers: [.control]))
    }

    func testRowKeysAreIntake() {
        XCTAssertTrue(intake(KeyCode.returnKey))
        // ⌘↩ is copy while nothing is held, so it is intake as well.
        XCTAssertTrue(intake(KeyCode.returnKey, modifiers: [.command]))
        XCTAssertTrue(intake(KeyCode.keypadEnter))
    }

    func testSlashAndEscapeAreIntake() {
        XCTAssertTrue(intake(KeyCode.slash))
        // Esc is claimed by key code, never by token: a virtual keyboard (Caps Lock
        // remapped to Esc by Karabiner) can send the key with no character attached.
        XCTAssertTrue(intake(KeyCode.escape))
        XCTAssertTrue(intake(KeyCode.escape, modifiers: [.command]))
        // ⌘/ is macOS's Help shortcut and a shortcut of its own in plenty of apps, so only
        // the bare slash opens the search palette — and only the bare one is intake.
        XCTAssertFalse(intake(KeyCode.slash, modifiers: [.command]))
        XCTAssertFalse(intake(KeyCode.slash, modifiers: [.option]))
    }

    /// ⌫ is deliberately *not* on the list: the engine owns it, because while a sequence is
    /// being composed it undoes a tick and must be swallowed, and otherwise it belongs to
    /// the front app.
    func testBackspaceIsNotIntake() {
        XCTAssertFalse(intake(KeyCode.delete))
    }

    /// An ordinary key is not intake, which is what lets a composed stroke be swallowed.
    func testOrdinaryKeysAreNotIntake() {
        XCTAssertFalse(intake(8))
        XCTAssertFalse(intake(KeyCode.delete))
    }
}
