import Foundation

/// The keys the panel consumes for *itself*, before any stroke is composed.
///
/// The event tap has to decide whether to swallow a key before the engine ever sees it, and
/// `handleKeyDown` spends its first few branches on keys that are panel navigation rather
/// than a chord: `/` opens the search palette, Escape closes the panel, the arrows and `;`/`'`
/// move through the list, and the run/copy keys act on the selected row.
///
/// That list has to be readable from the tap as well, and the reason is the ticked modifier.
/// A ticked ⌥ is not in the key event — it lives in the panel — so `;` arrives carrying
/// nothing, and `⌥;` is a perfectly good binding that `ChordComposition` would happily
/// complete. Left unchecked the tap swallows the `;` as the first stroke of `⌥;` while the
/// engine pages the list: the key is eaten and nothing the user asked for happens. Both
/// sides therefore read this one list instead of each keeping its own copy.
///
/// Backspace is deliberately absent. It belongs to the panel only while a sequence is being
/// composed, where it undoes a tick — see `ShortcutEngine.shouldSwallowComposed`, which owns
/// that decision because it is the one place that knows a tick exists.
enum PanelKeyIntake {
    /// - Parameter held: only the modifiers physically down. A latched set must never be
    ///   passed here: its modifiers are not in the event, so subtracting them would invent
    ///   combinations the user never pressed.
    static func isConsumedBeforeComposition(
        keyCode: UInt16,
        modifiers: ModifierSet,
        held: ModifierSet,
        run: HotkeySpec,
        copy: HotkeySpec
    ) -> Bool {
        if keyCode == KeyCode.slash, modifiers.isEmpty { return true }
        // By key code, not by token: the tap claims Esc whether or not it decoded a
        // character for it, and a virtual keyboard (Caps Lock remapped to Esc) can send
        // the key with no character attached.
        if keyCode == KeyCode.escape { return true }
        let pressed = modifiers.subtracting(held)
        if NavigationKey.direction(keyCode: keyCode, modifiers: pressed) != nil { return true }
        if NavigationKey.pageStep(keyCode: keyCode, modifiers: pressed) != nil { return true }
        if RowKeyRouter.action(
            for: keyCode,
            modifiers: modifiers,
            held: held,
            run: run,
            copy: copy
        ) != nil { return true }
        return false
    }
}
