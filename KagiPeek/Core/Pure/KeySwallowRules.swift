import Foundation

/// A global hotkey the tap must consume instead of forwarding to the front app.
nonisolated struct SwallowRule: Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: ModifierSet
    /// Hyper-key tolerance: accept a superset of the recorded modifiers, so a binding
    /// recorded as ⌃⌥⇧⌘C still fires when the user holds one modifier more.
    var tolerant: Bool
}

/// Everything the tap consults to answer "eat this keystroke, or let it through?".
///
/// Three channels feed one answer, and they are not interchangeable:
///
/// - **`rules`** — the user's global hotkeys. A keystroke they name is KagiPeek's, so the
///   front app must not also see it.
/// - **`capturedIdentifiers`** — key + modifier pairs the panel is using right now (arrows,
///   Return, Escape) while it is pinned. Modifier-sensitive, so ⌥; stays available to the
///   front app while plain `;` belongs to the panel.
/// - **`capturedKeyCodes`** — key codes consumed whatever the modifiers say. Escape only,
///   because there is no spelling of Escape the panel should let past.
/// - **`capturedCharacters`** — the characters of the enabled paging pairs. A CJK layout
///   types `；` for the semicolon key, so the identifier channel (which knows the ANSI code)
///   is not enough to describe what the user meant; the character decides.
///
/// This lived inside `KeyboardMonitor` — a 693-line class holding a thread, a run loop, two
/// timers and four caches — where the one decision every keystroke of every session depends
/// on could not be tested at all. It is a value type: build one, ask it a question.
nonisolated struct KeySwallowRules: Equatable {
    var rules: [SwallowRule] = []
    var capturedIdentifiers: Set<UInt32> = []
    var capturedKeyCodes: Set<UInt16> = []
    var capturedCharacters: Set<Character> = []

    /// True when nothing is captured, which is the answer for almost every keystroke of a
    /// session — the cheap refusal comes first for exactly that reason.
    var isEmpty: Bool {
        rules.isEmpty
            && capturedIdentifiers.isEmpty
            && capturedKeyCodes.isEmpty
            && capturedCharacters.isEmpty
    }

    /// Packs a key and its modifiers into the identifier the panel captures with.
    ///
    /// The low byte is the modifier mask and the key code sits above it, so two events
    /// differing only in modifiers cannot collide.
    static func identifier(keyCode: UInt16, modifiers: ModifierSet) -> UInt32 {
        UInt32(keyCode) << 8 | UInt32(truncatingIfNeeded: modifiers.rawValue & 0xFF)
    }

    func shouldSwallow(keyCode: UInt16, modifiers: ModifierSet, characters: String? = nil) -> Bool {
        // `capturedKeyCodes` is a separate channel (Escape regardless of modifiers); leaving
        // it out of this guard would silently disable Escape whenever the others are empty.
        guard !isEmpty else { return false }

        if capturedKeyCodes.contains(keyCode) { return true }
        if capturedIdentifiers.contains(Self.identifier(keyCode: keyCode, modifiers: modifiers)) {
            return true
        }
        // Paging characters are judged with Shift allowed (a layout may spell one with it).
        // Any other modifier means the key is not the paging key the user pressed — the
        // identifier channel already covers the held-modifier spelling published by the
        // engine.
        if modifiers.subtracting([.shift]).isEmpty,
           let first = characters?.first,
           capturedCharacters.contains(first) {
            return true
        }
        for rule in rules {
            guard rule.keyCode == keyCode else { continue }
            if rule.modifiers == modifiers { return true }
            if rule.tolerant, modifiers.isSuperset(of: rule.modifiers) { return true }
        }
        return false
    }
}
