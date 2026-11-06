import Foundation

/// Everything the composed-stroke swallow decision reads, as one immutable value.
///
/// The decision used to live in `ShortcutEngine.shouldSwallowComposed`, on the main actor.
/// That put the main thread inside the input path: the tap could not answer "swallow or
/// pass?" without waiting for it, and a wedged main thread meant a frozen keyboard. The
/// decision now runs where the event arrives — the tap's own thread — against a snapshot
/// the engine publishes after every state change. A stale snapshot costs one wrong
/// decision about one keystroke; a synchronous main-thread call costs the whole session's
/// input. The trade is not close.
nonisolated struct ComposedSwallowState {
    var isTestingShortcut = false
    /// `panel.isVisible && phase == .active`
    var panelIsActive = false
    /// `!panel.latchedModifiers.isEmpty`
    var hasLatchedModifiers = false
    /// What the user has composed so far.
    var prefix: KeyChord = .empty
    /// What the panel is contributing (held physical, latched sticky).
    var pending: PendingModifiers = PendingModifiers()
    /// Only the modifiers physically down — `PanelKeyIntake` subtracts these.
    var heldModifiers: ModifierSet = []
    /// The panel's ordered filter tokens. Non-empty means letters and ⌫ belong to it.
    var filter = PanelFilter()
    var runRowKey: HotkeySpec?
    var copyRowKey: HotkeySpec?
    /// The punctuation pairs the settings currently enable, for `PanelKeyIntake`.
    var pagingPairs: Set<PagingPair> = [.semicolonQuote]
    /// The bindings a chord can resolve against: the front app's menu items *and* the
    /// system hotkeys, the same set the panel draws its rows from. A visible row that the
    /// tap cannot match would be swallowed for no reason.
    var catalogItems: [BindingItem] = []
    /// `panel.shiftHintActive`: a tap of Shift has labelled the first 36 rows with 0–9 /
    /// a–z. The labels stay up after Shift is released, and a bare glyph press belongs to
    /// the panel rather than reaching the front app as text.
    var shiftHintsActive = false
    /// Rows on the current page. The key handler only runs a glyph that names a row on
    /// screen, so the swallow decision shares that boundary: swallowing a glyph that
    /// addresses nothing is a keypress that vanishes without a trace.
    var hintRowCount = 0
}

/// Whether a key event has to be consumed because the panel is composing a stroke.
///
/// Verbatim from `ShortcutEngine.shouldSwallowComposed`, which this replaces:
///
/// - **⌫ while composing.** It undoes a tick, so the panel owns it. Letting it reach the
///   front app as well would delete a character the user never aimed at.
/// - **navigation, paging, the row keys, `/` and Escape.** With a ticked modifier these
///   arrive carrying nothing, so `⌥;` is a real binding and the composition below would
///   swallow the `;` as its first stroke — while the engine pages the list. The tap reads
///   `PanelKeyIntake`, the same list the handler walks, so the two cannot diverge.
nonisolated enum ComposedSwallow {
    static func decide(_ state: ComposedSwallowState, event: KeyEvent) -> Bool {
        guard !state.isTestingShortcut else { return false }
        guard state.panelIsActive else { return false }
        // While the hint layer is up a bare glyph is a row address, not text. It reaches
        // here before the composition rules because the address must not be offered to
        // chord composition either. The same resolver the key handler uses answers this,
        // so a press is swallowed exactly when a row will run for it — no swallowed key
        // that vanishes, and no row key that also types into the front app.
        if state.shiftHintsActive,
           event.modifiers.isEmpty,
           ShiftHintLayer.index(for: event, pageRowCount: state.hintRowCount) != nil { return true }
        guard let key = event.key else { return false }
        // A non-empty token queue owns its own input: bare letters the filter accepts and
        // ⌫ would otherwise reach the front app as text or a deletion. A letter still
        // carrying physical modifiers belongs to a chord, so `letter(for:)` refuses it and
        // this press passes through — that is how ⌥⌘M reaches the system while ⌥⌘ narrows
        // the list. The Shift hint layer keeps priority, and a search palette never reaches
        // here (`panelIsActive`).
        if !state.filter.isEmpty, !state.shiftHintsActive {
            if event.keyCode == KeyCode.delete { return true }
            if PanelFilterPlan.letter(for: event) != nil { return true }
        }
        guard state.hasLatchedModifiers else { return false }
        if event.modifiers.isEmpty, key == .backspace { return true }
        if PanelKeyIntake.isConsumedBeforeComposition(
            keyCode: event.keyCode,
            modifiers: event.modifiers,
            held: state.heldModifiers,
            run: state.runRowKey,
            copy: state.copyRowKey,
            pagingPairs: state.pagingPairs,
            characters: event.characters
        ) { return false }
        let resolution = ChordComposition.resolve(
            prefix: state.prefix,
            physical: event.modifiers,
            pending: state.pending,
            key: key,
            in: state.catalogItems
        )
        return resolution.shouldSwallow
    }
}
