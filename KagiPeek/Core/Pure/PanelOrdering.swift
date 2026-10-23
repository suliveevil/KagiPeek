import Foundation

/// How the panel orders its rows, and which rows a modifier filter keeps.
///
/// The panel is a reference card, not a mirror of the menu bar. Rows are ordered by the
/// shortcut itself — fewer strokes first, then the modifier set by significance (⌘, ⌥, ⌃, ⇧),
/// then the key, where a function key sorts as the word it is named after (`f`, `f1`, `f2`,
/// … `g`). So ⌘C, ⌘V and ⌘X sit together whichever menu they came from, ⌥⌘C stays next to
/// ⌘C, and every ⌘ shortcut is reachable before anything else. The menu path travels with
/// the row as a note instead of a heading, which is also why a heading can no longer reorder
/// the list.
///
/// Two panel-only decisions live here because the view has no business making them:
///
/// - **Hold to emphasise and re-order.** While modifiers are down the list narrows to the
///   shortcuts that can be reached from them (`PrefixResolver`, the which-key core) and the
///   rows that use them lead the order, so pressing another modifier re-answers "which
///   shortcuts start with these" instead of leaving the list where it was.
/// - **Filter.** `uses(_:allOf:)` answers "does this chord carry all of these modifiers",
///   which is the title bar's rule for its ⌃ ⌥ ⇧ ⌘ chips — a second, sticky way to narrow.
enum PanelOrdering {
    /// Lexicographic over the strokes, in the order they are drawn. Two chords that print
    /// the same way are ordered by their remaining strokes, then by nothing (the caller
    /// breaks the tie).
    ///
    /// A command with no keyboard shortcut is not part of the chord order and sorts after
    /// every chord: the panel is still a shortcut reference card first, and the
    /// shortcut-less rows — clickable, but not typeable — belong at the end of it.
    static func compare(_ lhs: KeyChord, _ rhs: KeyChord) -> Bool {
        if lhs.isEmpty || rhs.isEmpty {
            // Both empty: equal here, the caller's tie-break decides.
            if lhs.isEmpty, rhs.isEmpty { return false }
            return rhs.isEmpty
        }
        let shared = min(lhs.steps.count, rhs.steps.count)
        for index in 0..<shared {
            let left = lhs.steps[index]
            let right = rhs.steps[index]
            if left.modifiers != right.modifiers {
                return compareModifiers(left.modifiers, right.modifiers)
            }
            switch (left.key, right.key) {
            case let (left?, right?):
                if left != right { return left < right }
            case (nil, .some):
                // A modifier-only stroke prints first: "⌘" before "⌘C".
                return true
            default:
                break
            }
        }
        return lhs.steps.count < rhs.steps.count
    }

    /// Orders modifier sets by significance: ⌘, then ⌥, then ⌃, then ⇧.
    ///
    /// The first modifier that differs decides, and a set that runs out first comes first,
    /// so every chord that uses ⌘ comes first — ordered by whatever else it carries — then
    /// the ones that do not: `⌘X`, `⌥⌘X`, `⌃⌘X`, `⇧⌘X`, `⌥X`, `⌃⌥X`, `⇧⌥X`, `⌃X`, `⇧⌃X`,
    /// `⇧X`. ⌘ leads because it is the modifier people actually press; the canonical print
    /// order (⌃⌥⇧⌘) is how a chord is drawn, not how it should be found.
    ///
    /// Counting modifiers first — the rule two revisions back — put *every* two-modifier
    /// shortcut after *every* one-modifier shortcut, which is not an order anyone reads:
    /// `⌃⌥C` ended up a screen away from `⌃C` while `⌘C` sat above both.
    private static func compareModifiers(_ lhs: ModifierSet, _ rhs: ModifierSet) -> Bool {
        let left = orderedBySignificance(lhs)
        let right = orderedBySignificance(rhs)
        for (index, modifier) in left.enumerated() {
            // The right set ran out: it is a prefix, so it sorts first.
            guard index < right.count else { return false }
            if modifier != right[index] {
                return rank(modifier) < rank(right[index])
            }
        }
        return left.count < right.count
    }

    /// ⌘, ⌥, ⌃, ⇧ — by how much the modifier narrows a chord, not by how it is printed.
    private static let significance: [ModifierSet] = [.command, .option, .control, .shift]

    private static func orderedBySignificance(_ modifiers: ModifierSet) -> [ModifierSet] {
        significance.filter { modifiers.contains($0) }
    }

    private static func rank(_ modifier: ModifierSet) -> Int {
        significance.firstIndex(of: modifier) ?? Int.max
    }

    /// True when one stroke of `chord` carries every modifier in `modifiers`.
    ///
    /// A chord is matched as a whole rather than by its first stroke so that ⌘K ⌘C counts
    /// as a ⌘ shortcut, which is how a user reads it.
    static func uses(_ chord: KeyChord, allOf modifiers: ModifierSet) -> Bool {
        guard !modifiers.isEmpty else { return true }
        return chord.steps.contains { $0.modifiers.isSuperset(of: modifiers) }
    }

    /// Panel order. Rows that use `modifiers` (the set being held) come first, so pressing
    /// ⌘ answers "which shortcuts want ⌘" before anything else without hiding the rest.
    static func areInIncreasingOrder(
        _ lhs: BindingItem,
        _ rhs: BindingItem,
        emphasizing modifiers: ModifierSet = []
    ) -> Bool {
        if !modifiers.isEmpty {
            let left = uses(lhs.chord, allOf: modifiers)
            let right = uses(rhs.chord, allOf: modifiers)
            if left != right { return left }
        }
        if compare(lhs.chord, rhs.chord) { return true }
        if compare(rhs.chord, lhs.chord) { return false }
        if lhs.title != rhs.title {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        // Two bindings may share a title and a chord (the same command in two menus);
        // the id keeps the order total, which `sorted(by:)` requires.
        return lhs.id < rhs.id
    }

    static func sorted(_ items: [BindingItem], emphasizing modifiers: ModifierSet = []) -> [BindingItem] {
        items.sorted { areInIncreasingOrder($0, $1, emphasizing: modifiers) }
    }
}
