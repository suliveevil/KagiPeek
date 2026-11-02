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
struct ComposedSwallowState {
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
    var runRowKey: HotkeySpec = HotkeySpec(keyCode: 0, modifiers: [])
    var copyRowKey: HotkeySpec = HotkeySpec(keyCode: 0, modifiers: [])
    var catalogItems: [BindingItem] = []
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
enum ComposedSwallow {
    static func decide(_ state: ComposedSwallowState, event: KeyEvent) -> Bool {
        guard !state.isTestingShortcut else { return false }
        guard state.hasLatchedModifiers else { return false }
        guard state.panelIsActive else { return false }
        guard let key = event.key else { return false }
        if event.modifiers.isEmpty, key == .backspace { return true }
        if PanelKeyIntake.isConsumedBeforeComposition(
            keyCode: event.keyCode,
            modifiers: event.modifiers,
            held: state.heldModifiers,
            run: state.runRowKey,
            copy: state.copyRowKey
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
