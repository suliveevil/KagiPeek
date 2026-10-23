import Foundation

/// Decides which rows glow while the user is pressing a shortcut.
///
/// The trigger modifiers are *not* a prefix: the panel keeps every shortcut on screen and
/// only highlights the rows whose chord starts with the modifiers currently held. Once the
/// user descends into a chord, every row on that level is part of the shortcut in progress.
enum PanelHighlighter {
    static func highlightedIDs(
        items: [BindingItem],
        prefix: KeyChord,
        heldModifiers: ModifierSet
    ) -> Set<String> {
        if !prefix.isEmpty, !prefix.isModifierOnly {
            let hits = PrefixResolver.hits(for: prefix, in: items)
            return Set(hits.map(\.item.id))
        }
        guard !heldModifiers.isEmpty else { return [] }
        return Set(items.compactMap { item in
            guard let first = item.chord.steps.first,
                  first.modifiers.isSuperset(of: heldModifiers) else { return nil }
            return item.id
        })
    }
}
