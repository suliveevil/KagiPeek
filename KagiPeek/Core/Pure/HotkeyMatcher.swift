import Foundation

/// Matches a recorded global hotkey against a live key event.
///
/// Hyper-key tools (Karabiner, BetterTouchTool, …) can deliver an extra modifier that the
/// recorder never saw, so a hotkey with three or more modifiers also matches when the event
/// carries a superset of them.
enum HotkeyMatcher {
    static func matches(
        keyCode: UInt16,
        modifiers: ModifierSet,
        key: KeyToken?,
        spec: HotkeySpec
    ) -> Bool {
        guard keyCode == spec.keyCode else { return false }
        if let key, key != spec.chord.steps.first?.key {
            return false
        }
        if modifiers == spec.modifiers { return true }
        if spec.modifiers.count >= 3, modifiers.isSuperset(of: spec.modifiers) {
            return true
        }
        return false
    }

    /// Called on the event-tap thread: keep it allocation-light.
    static func shouldSwallow(keyCode: UInt16, modifiers: ModifierSet, spec: HotkeySpec) -> Bool {
        guard keyCode == spec.keyCode else { return false }
        if modifiers == spec.modifiers { return true }
        return spec.modifiers.count >= 3 && modifiers.isSuperset(of: spec.modifiers)
    }
}
