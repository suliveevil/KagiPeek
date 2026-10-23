import Foundation

/// One row of the panel: "press this key next to get that".
struct PrefixHit: Identifiable, Equatable, Sendable {
    let item: BindingItem
    /// The key to press next, or nil for a command that has no keyboard shortcut at all:
    /// the row is real and clickable — pressing the menu item performs it — there is just
    /// nothing to type.
    let nextKey: KeyToken?
    let remainingSteps: Int
    let relation: PrefixRelation

    /// The binding's own id, never a composite of it.
    ///
    /// This used to append the next key ("…|c"). That id leaked into `PanelRow.id`, so
    /// every lookup that expected a binding id — run, copy, pin, the completion flash —
    /// compared two different namespaces and quietly did nothing. One row per binding per
    /// level means the binding id is already unique here.
    var id: String { item.id }
}

/// Turns "what the user has typed so far" into panel rows and execution decisions.
enum PrefixResolver {
    /// All bindings reachable from `prefix`, one row per binding.
    static func hits(
        for prefix: KeyChord,
        in items: [BindingItem],
        includeDisabled: Bool = true
    ) -> [PrefixHit] {
        var result: [PrefixHit] = []
        result.reserveCapacity(min(items.count, 64))
        for item in items {
            if !includeDisabled && !item.isEnabled { continue }
            let relation = item.chord.relation(to: prefix)
            guard relation != .unrelated else { continue }
            result.append(
                PrefixHit(
                    item: item,
                    nextKey: item.chord.nextKey(after: prefix),
                    remainingSteps: item.chord.remainingSteps(after: prefix),
                    relation: relation
                )
            )
        }
        return result
    }

    /// The binding the user just completed, if any.
    static func exactMatch(in items: [BindingItem], for probe: KeyChord) -> BindingItem? {
        var fallback: BindingItem?
        for item in items where item.chord.relation(to: probe) == .exact {
            if item.isEnabled { return item }
            if fallback == nil { fallback = item }
        }
        return fallback
    }

    /// How many bindings continue past `probe` (used to decide whether to drill down).
    static func descendantCount(in items: [BindingItem], for probe: KeyChord) -> Int {
        items.reduce(into: 0) { count, item in
            if item.chord.relation(to: probe) == .descend { count += 1 }
        }
    }

    /// Builds the probe prefix for a key press.
    ///
    /// While the user is only holding modifiers the prefix is a single modifier step; the
    /// key press *replaces* that step instead of appending a second one.
    static func probe(
        after prefix: KeyChord,
        modifiers: ModifierSet,
        key: KeyToken,
        alternates: [KeyToken] = []
    ) -> KeyChord {
        if prefix.isEmpty || prefix.isModifierOnly {
            return KeyChord.combo(modifiers, key, alternates: alternates)
        }
        return prefix.appending(modifiers: modifiers, key: key, alternates: alternates)
    }
}
