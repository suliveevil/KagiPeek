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
    var catalogItems: [BindingItem] = []
    /// `panel.shiftHintActive`: the first 36 rows are addressed by 0–9 / a–z, so a
    /// Shift + glyph press belongs to the panel and must not reach the front app as text.
    var shiftHintsActive = false
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
        guard let key = event.key else { return false }
        // The Shift-hint layer owns a Shift + glyph press. It reaches here before the
        // composition rules because nothing is latched while hints are up: the panel is
        // open, Shift is down, and the glyph is a row address — if it were let through the
        // app would get a stray capital letter.
        if state.shiftHintsActive,
           event.modifiers == [.shift],
           ShiftHintLayer.index(forCharacter: key.raw) != nil { return true }
        // A non-empty token queue owns its own input: letters the filter accepts and ⌫
        // would otherwise reach the front app as text or a deletion. The Shift hint layer
        // keeps priority, and a search palette never reaches here (`panelIsActive`).
        if !state.filter.isEmpty, !state.shiftHintsActive {
            if event.keyCode == KeyCode.delete { return true }
            if PanelFilterPlan.letter(for: event, filter: state.filter) != nil { return true }
        }
        guard state.hasLatchedModifiers else { return false }
        if event.modifiers.isEmpty, key == .backspace { return true }
        if PanelKeyIntake.isConsumedBeforeComposition(
            keyCode: event.keyCode,
            modifiers: event.modifiers,
            held: state.heldModifiers,
            run: state.runRowKey,
            copy: state.copyRowKey,
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
