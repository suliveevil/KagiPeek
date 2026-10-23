import Foundation

/// The modifiers ticked in the title bar, kept as a set *and* in the order they were ticked.
///
/// A set is what the panel needs to draw and to compose with (`contains`, `union`), but a set
/// cannot answer "which one was last?" — and ⌫ has to undo the last tick, not the one that
/// happens to come last in ⌃⌥⇧⌘ order. Ticking ⌘ and then ⌥ and pressing ⌫ must drop the ⌥.
///
/// Both halves live here so the two places that change them cannot disagree.
enum LatchedTicks {
    /// Ticks or unticks every modifier in `modifiers`, appending newly ticked ones to the end.
    static func toggling(
        _ modifiers: [ModifierSet],
        latched: ModifierSet,
        order: [ModifierSet]
    ) -> (latched: ModifierSet, order: [ModifierSet]) {
        var latched = latched
        var order = order
        for modifier in modifiers {
            if let index = order.firstIndex(of: modifier) {
                order.remove(at: index)
                latched.remove(modifier)
            } else {
                order.append(modifier)
                latched.insert(modifier)
            }
        }
        return (latched, order)
    }

    /// Undoes the most recent tick.
    /// - Returns: nil when there is nothing to undo, so ⌫ can fall through to its other
    ///   meaning (up one level of a chord) only when no tick was consumed.
    static func popping(
        latched: ModifierSet,
        order: [ModifierSet]
    ) -> (latched: ModifierSet, order: [ModifierSet])? {
        guard let last = order.last else { return nil }
        var latched = latched
        var order = order
        order.removeLast()
        latched.remove(last)
        return (latched, order)
    }
}
