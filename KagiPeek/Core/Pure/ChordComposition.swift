import Foundation

/// Turns "the key the user just pressed" plus "what the panel is contributing" into one
/// stroke, and decides what that stroke means.
///
/// A stroke can be assembled: the modifier may come from a title-bar tick rather than from
/// the physical key event (⌥⌘C typed as "click ⌥, click ⌘, press C"). That changes what has
/// to happen to the event itself — see `shouldSwallow` — so the decision is made here, in
/// pure code, where a wrong answer cannot silently double-execute.
enum ChordComposition {
    enum Outcome: Equatable {
        /// The pressed stroke finishes a shortcut.
        case complete(BindingItem)
        /// The stroke opens a deeper level (⌘K of ⌘K ⌘C).
        case descend
        /// Nothing starts with this stroke.
        case noMatch
    }

    struct Resolution: Equatable {
        /// The chord built from the prefix, the latched modifiers and the pressed key.
        var probe: KeyChord
        var outcome: Outcome
        /// True when part of `probe` came from the panel rather than from the event.
        var composed: Bool

        /// What to show the user: the assembled stroke, never the bare key.
        ///
        /// Showing "C" when the user ticked ⌥ and ⌘ would give them no way to check whether
        /// the tick took effect, which is the whole point of the interaction.
        var displayChord: KeyChord { probe }
    }

    /// - Parameters:
    ///   - physical: the modifiers the key event actually carried.
    ///   - pending: what the panel is contributing; only `latched` is folded into the stroke.
    static func resolve(
        prefix: KeyChord,
        physical: ModifierSet,
        pending: PendingModifiers,
        key: KeyToken,
        in items: [BindingItem]
    ) -> Resolution {
        let stroke = physical.union(pending.latched)
        let probe = PrefixResolver.probe(after: prefix, modifiers: stroke, key: key)
        // A latched modifier that is *not* physically down is the part the panel supplied.
        // If every latched modifier happens to be held as well, the key press is an ordinary
        // one and must pass through untouched.
        let composed = !pending.latched.subtracting(physical).isEmpty
        let outcome: Outcome
        if let item = PrefixResolver.exactMatch(in: items, for: probe) {
            outcome = .complete(item)
        } else if PrefixResolver.descendantCount(in: items, for: probe) > 0 {
            outcome = .descend
        } else {
            outcome = .noMatch
        }
        return Resolution(probe: probe, outcome: outcome, composed: composed)
    }
}

extension ChordComposition.Resolution {
    /// Whether the event has to be consumed by the tap.
    ///
    /// Only a composed stroke: an ordinary ⌥⌘C is let through so the front app performs it
    /// itself, exactly as before. A composed one has to be swallowed, because the physical
    /// event carries only "C" — letting it through as well would run the shortcut once for
    /// the panel and once for the app.
    var shouldSwallow: Bool {
        composed && outcome != .noMatch
    }
}
