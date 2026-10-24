import XCTest
@testable import KagiPeekCore

/// Characterizes the key-down pipeline that `ShortcutEngine.handleKeyDown` used to walk
/// inline: hotkeys first, then the phase switch, then the panel's own keys, then chord
/// composition. Every case below pins an existing branch so a later refactor of the engine
/// cannot change what a key means without a test noticing.
final class KeyEventRouterTests: XCTestCase {
    /// A spec that can never match a real key press.
    private static let inert = HotkeySpec(keyCode: 999, modifiers: [])

    private static let neutralSettings: AppSettingsSnapshot = {
        var settings = AppSettingsSnapshot()
        settings.panelHotkey = inert
        settings.searchHotkey = inert
        settings.switchHotkey = inert
        settings.runRowKey = inert
        settings.copyRowKey = inert
        return settings
    }()

    private let c = KeyToken("c")
    private let k = KeyToken("k")

    private func item(_ chord: KeyChord, _ title: String = "T") -> BindingItem {
        BindingItem(chord: chord, title: title, group: ["Edit"], source: .menu)
    }

    private func route(
        keyCode: UInt16,
        key: KeyToken? = nil,
        modifiers: ModifierSet = [],
        isRepeat: Bool = false,
        phase: EnginePhase = .active,
        settings: AppSettingsSnapshot = KeyEventRouterTests.neutralSettings,
        panel: PanelState = .hidden,
        prefix: KeyChord = .empty,
        pending: PendingModifiers = PendingModifiers(),
        items: [BindingItem] = []
    ) -> KeyDownAction {
        KeyEventRouter.route(
            keyCode: keyCode,
            key: key,
            modifiers: modifiers,
            isRepeat: isRepeat,
            phase: phase,
            settings: settings,
            panel: panel,
            prefix: prefix,
            pending: pending,
            items: items
        )
    }

    // MARK: - Hotkeys answer in any phase

    func testPanelHotkeyMatchesEvenWhileIdle() {
        var settings = Self.neutralSettings
        settings.panelHotkey = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.command])
        let action = route(
            keyCode: KeyCode.returnKey,
            key: KeyToken("return"),
            modifiers: [.command],
            phase: .idle,
            settings: settings
        )
        XCTAssertEqual(action, .hotkey(.panel))
    }

    /// Two hotkeys sharing a chord answer to the first: `panelHotkey`, then `searchHotkey`,
    /// then `switchHotkey` — the order the engine used to ask them.
    func testHotkeyPrecedence() {
        var settings = Self.neutralSettings
        settings.panelHotkey = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.command])
        settings.searchHotkey = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.command])
        let action = route(
            keyCode: KeyCode.returnKey,
            key: KeyToken("return"),
            modifiers: [.command],
            phase: .active,
            settings: settings
        )
        XCTAssertEqual(action, .hotkey(.panel))
    }

    func testSearchHotkey() {
        var settings = Self.neutralSettings
        settings.searchHotkey = HotkeySpec(keyCode: KeyCode.slash, modifiers: [.option])
        let action = route(
            keyCode: KeyCode.slash,
            key: KeyToken("/"),
            modifiers: [.option],
            phase: .active,
            settings: settings
        )
        XCTAssertEqual(action, .hotkey(.search))
    }

    // MARK: - Phase routing

    func testIdleKeyIsIgnored() {
        XCTAssertEqual(route(keyCode: 3, key: "c", phase: .idle), .none)
    }

    /// A key pressed while a trigger is arming cancels the arm: the user is typing, not
    /// about to open the panel.
    func testArmedKeyCancelsArm() {
        XCTAssertEqual(route(keyCode: 3, key: "c", phase: .armed), .cancelArm)
    }

    // MARK: - The panel's own keys

    /// Escape is matched on the key code and before the token guard: a virtual keyboard
    /// (Caps Lock remapped to Esc) can send the key with no character attached.
    func testEscapeDismissesEvenWithoutAToken() {
        XCTAssertEqual(route(keyCode: KeyCode.escape, key: nil), .dismiss)
    }

    func testNilKeyIsIgnoredInActive() {
        XCTAssertEqual(route(keyCode: 200, key: nil), .none)
    }

    /// `/` alone is the panel's one text entry; the palette is where typing belongs.
    func testSlashAloneOpensSearch() {
        XCTAssertEqual(route(keyCode: KeyCode.slash, key: "/"), .showSearch)
    }

    /// `/` with a modifier is not the text-entry key: it falls through to composition.
    func testSlashWithModifiersIsNotShowSearch() {
        XCTAssertEqual(
            route(keyCode: KeyCode.slash, key: "/", modifiers: [.command]),
            .noMatch(heldModifiers: [.command])
        )
    }

    func testArrowKeysMoveSelectionOrPage() {
        XCTAssertEqual(route(keyCode: KeyCode.down, key: "down"), .moveSelection(1))
        XCTAssertEqual(route(keyCode: KeyCode.up, key: "up"), .moveSelection(-1))
        XCTAssertEqual(route(keyCode: KeyCode.left, key: "left"), .page(-1))
        XCTAssertEqual(route(keyCode: KeyCode.right, key: "right"), .page(1))
    }

    /// macOS text views have always bound ⌃F/⌃B/⌃N/⌃P, and the panel accepts them too.
    func testCtrlNavigation() {
        XCTAssertEqual(route(keyCode: KeyCode.ctrlN, key: "n", modifiers: [.control]), .moveSelection(1))
        XCTAssertEqual(route(keyCode: KeyCode.ctrlP, key: "p", modifiers: [.control]), .moveSelection(-1))
    }

    func testPageKeys() {
        XCTAssertEqual(route(keyCode: KeyCode.semicolon, key: ";"), .page(-1))
        XCTAssertEqual(route(keyCode: KeyCode.quote, key: "'"), .page(1))
    }

    func testRowKeys() {
        var settings = Self.neutralSettings
        settings.runRowKey = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [])
        settings.copyRowKey = HotkeySpec(keyCode: KeyCode.delete, modifiers: [.command])
        let run = route(
            keyCode: KeyCode.returnKey,
            key: "return",
            settings: settings
        )
        XCTAssertEqual(run, .performRow(.execute))
        let copy = route(
            keyCode: KeyCode.delete,
            key: "x",
            modifiers: [.command],
            settings: settings
        )
        XCTAssertEqual(copy, .performRow(.copy))
    }

    /// A held row key repeats: moving is useful, running the same shortcut ten times is not.
    func testRepeatedRowKeyIsIgnored() {
        var settings = Self.neutralSettings
        settings.runRowKey = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [])
        XCTAssertEqual(
            route(keyCode: KeyCode.returnKey, key: "return", isRepeat: true, settings: settings),
            .none
        )
    }

    /// While the list is narrowed the user holds modifiers, so every event carries them;
    /// they are the filter and must be stripped before the key is identified.
    func testNavigationWhileNarrowing() {
        var panel = PanelState.hidden
        panel.heldModifiers = [.command]
        XCTAssertEqual(
            route(keyCode: KeyCode.down, key: "down", modifiers: [.command], panel: panel),
            .moveSelection(1)
        )
    }

    // MARK: - Backspace

    /// ⌫ undoes a tick before it pops a level: the tick is the newer thing the user did.
    func testBackspaceUndoesLatchedTick() {
        var panel = PanelState.hidden
        panel.latchedModifiers = [.option]
        panel.latchedOrder = [[.option]]
        XCTAssertEqual(
            route(keyCode: KeyCode.delete, key: .backspace, panel: panel),
            .undoLatched
        )
    }

    /// No ticks to undo, but a prefix to climb out of.
    func testBackspaceGoesUpOneLevel() {
        XCTAssertEqual(
            route(keyCode: KeyCode.delete, key: .backspace, prefix: .modifiers([.option])),
            .goUpLevel
        )
    }

    /// At the top level with no ticks, ⌫ is not the panel's: it passes through.
    func testBackspaceAtTopLevelIsIgnored() {
        XCTAssertEqual(route(keyCode: KeyCode.delete, key: .backspace), .none)
    }

    // MARK: - Chord composition

    /// A repeat of a composable key never composes: the stroke was already handled or the
    /// user is holding the key.
    func testRepeatedComposableKeyIsIgnored() {
        let catalog = [item(.combo([.command], c))]
        XCTAssertEqual(
            route(keyCode: 8, key: c, modifiers: [.command], isRepeat: true, items: catalog),
            .none
        )
    }

    /// An ordinary ⌥⌘C is not composed — the event already carries the chord, so the front
    /// app performs it.
    func testPhysicalChordPassesThrough() {
        let catalog = [item(.combo([.option, .command], c))]
        XCTAssertEqual(
            route(keyCode: 8, key: c, modifiers: [.option, .command], items: catalog),
            .passThrough(item: catalog[0], probe: .combo([.option, .command], c))
        )
    }

    /// A ticked ⌥ with a bare C *is* composed: the tap swallowed the key, so KagiPeek owes
    /// the app the assembled chord.
    func testComposedChordReplays() {
        var pending = PendingModifiers()
        pending.latched = [.option]
        let catalog = [item(.combo([.option], c))]
        XCTAssertEqual(
            route(keyCode: 8, key: c, pending: pending, items: catalog),
            .replayComposed(item: catalog[0], probe: .combo([.option], c))
        )
    }

    /// ⌘K of ⌘K ⌘C opens the deeper level.
    func testStrokeDescends() {
        let catalog = [item(KeyChord([.combo([.command], k), .combo([.command], c)]))]
        XCTAssertEqual(
            route(keyCode: 40, key: k, modifiers: [.command], items: catalog),
            .descend(probe: .combo([.command], k))
        )
    }

    /// A bare key with no match keeps the panel open and narrows by the physical set.
    func testNoMatchKeepsHeldModifiers() {
        XCTAssertEqual(route(keyCode: 8, key: c, modifiers: [.option]), .noMatch(heldModifiers: [.option]))
    }
}
