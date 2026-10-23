import Foundation

/// The virtual key codes the app reasons about.
///
/// macOS compares menu shortcuts by virtual key code, so these are the identity of a key;
/// the character it produces depends on the layout and is not a substitute.
enum KeyCode {
    static let tab: UInt16 = 48
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let slash: UInt16 = 44
    static let semicolon: UInt16 = 41
    static let quote: UInt16 = 39

    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126

    /// The arrows, as consumed by the panel and by a list.
    static let arrows: [UInt16] = [left, right, down, up]

    /// Keys that double as Emacs-style navigation with ⌃ held.
    static let ctrlF: UInt16 = 3
    static let ctrlB: UInt16 = 11
    static let ctrlN: UInt16 = 45
    static let ctrlP: UInt16 = 35
}

/// Keys that are the same key to a person but different codes to the system.
enum KeyAliases {
    /// Main Return and the keypad Enter. A binding recorded on either one answers to both,
    /// so a laptop keyboard and a full-size one behave the same.
    static func enterCodes(for keyCode: UInt16) -> [UInt16] {
        if keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter {
            return [KeyCode.returnKey, KeyCode.keypadEnter]
        }
        return [keyCode]
    }
}

/// Decides which action a key press asks for on a surface that carries the row contract.
///
/// The surfaces that carry it used to repeat the same two `if` statements, which meant "run
/// wins over copy" was a property of statement order in three places. It is a rule of the
/// contract, so it lives here once and is tested.
enum RowKeyRouter {
    static func action(
        for keyCode: UInt16,
        modifiers: ModifierSet,
        run: HotkeySpec,
        copy: HotkeySpec
    ) -> RowAction? {
        if run.matches(keyCode: keyCode, modifiers: modifiers) { return .execute }
        if copy.matches(keyCode: keyCode, modifiers: modifiers) { return .copy }
        return nil
    }

    /// The row action for a press that happens while modifiers are held to narrow the list.
    ///
    /// Narrowing is the whole point of the panel, and it means the user is physically holding
    /// ⌘ (or ⌃, or ⌥) — so every key event arrives carrying those modifiers and an exact
    /// match alone would never see the bare run key: ⌘ held + ↩ reads as the *copy* key, and
    /// ⌃ held + ↩ matches nothing at all.
    ///
    /// The order is deliberate and load-bearing:
    ///
    /// 1. `run` against the event minus the held set — while ⌘ is held, ↩ is the run key.
    ///    This comes first because it *is* the reported bug: without it, Return did nothing
    ///    (or copied) exactly while the list was narrowed.
    /// 2. `copy` against the event as it arrived — a copy key whose modifiers are not the
    ///    ones being held still copies (⌥ held + ⌘↩ is copy).
    /// 3. `copy` against the stripped set — ⇧↩ copies while ⌘ is held.
    /// 4. `run` against the event as it arrived — the un-narrowed case, last so that a copy
    ///    key recorded on a held modifier is not silently turned into a run.
    ///
    /// Known trade-off: while ⌘ narrows the list, ⌘↩ *is* ⌘ + ↩ and the two cannot be told
    /// apart, so ⌘↩ answers run. Copying then means releasing ⌘ first, or recording the copy
    /// key on a modifier that is not used for narrowing (⇧↩).
    ///
    /// - Parameter held: only the modifiers physically down. A latched set must never be
    ///   passed: its modifiers are not in the event, so subtracting them would invent
    ///   combinations that were never pressed.
    static func action(
        for keyCode: UInt16,
        modifiers: ModifierSet,
        held: ModifierSet,
        run: HotkeySpec,
        copy: HotkeySpec
    ) -> RowAction? {
        let stripped = modifiers.subtracting(held)
        if run.matches(keyCode: keyCode, modifiers: stripped) { return .execute }
        if copy.matches(keyCode: keyCode, modifiers: modifiers) { return .copy }
        if copy.matches(keyCode: keyCode, modifiers: stripped) { return .copy }
        if run.matches(keyCode: keyCode, modifiers: modifiers) { return .execute }
        return nil
    }

    /// Every (keyCode, modifiers) pair that must be consumed while the row keys are live,
    /// including the Enter alias. Derived from the same specs as `action(for:)` so the
    /// "handled but not swallowed" and "swallowed but not handled" holes cannot open.
    static func capturedIdentifiers(run: HotkeySpec, copy: HotkeySpec) -> [(keyCode: UInt16, modifiers: ModifierSet)] {
        run.capturedIdentifiers + copy.capturedIdentifiers
    }
}
