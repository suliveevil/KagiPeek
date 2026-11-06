import Foundation

/// The panel filter's two decisions, as values: which rows survive, and what a key-down
/// does to the token queue.
///
/// Both are pure so the engine only executes them. The row side deliberately goes through
/// `SearchCorpus` rather than a second string matcher: the palette and the panel must
/// answer the same query the same way.
nonisolated enum PanelFilterPlan {
    enum Decision: Equatable, Sendable {
        case append(Character)
        case popToken
        case none
    }

    /// - Returns: the ids the query matches, or nil when the filter is empty ("no filter").
    ///
    /// The panel only needs the surviving set: it orders those rows by its own sequence
    /// afterwards, so scoring and sorting every hit would be wasted work.
    /// `SearchCorpus.matchingItems` answers with a match-only predicate in corpus order,
    /// for one term and for many alike. A panel filter is usually multi-term from the
    /// first letter on — `PanelFilter.query` joins its queue with spaces, and a letter
    /// only enters a non-empty queue, so the queue starts with a modifier token — which
    /// is exactly why a single-term shortcut was not enough.
    static func matchingIDs(filter: PanelFilter, corpus: SearchCorpus) -> Set<String>? {
        guard !filter.isEmpty else { return nil }
        return Set(corpus.matchingItems(for: filter.query).map(\.id))
    }

    static func decision(
        for event: KeyEvent,
        filter: PanelFilter,
        phase: EnginePhase,
        shiftHintActive: Bool,
        triggerPending: Bool,
        triggerKey: TriggerKey
    ) -> Decision {
        // The search palette has its own text field, the Shift hint layer owns 0–9 / a–z,
        // and the press that summoned the panel is a trigger rather than a filter.
        guard phase == .active, !shiftHintActive, !triggerPending else { return .none }
        // A key-down on a trigger modifier's physical key is never a filter token.
        guard !triggerKey.keyCodes.contains(event.keyCode) else { return .none }

        if event.keyCode == KeyCode.delete, !filter.isEmpty {
            return .popToken
        }
        // Letters only belong to the filter once it has something in it, and only when they
        // arrive bare. An empty filter would otherwise steal ⌘C / ⌥C chord strokes and the
        // latched modifiers' "tick ⌥ then press C" path, and clear the prefix on top; a
        // letter still carrying modifiers is a chord, not a query (see `letter(for:)`).
        guard !filter.isEmpty else { return .none }
        guard !event.isRepeat, let letter = letter(for: event) else { return .none }
        return .append(letter)
    }

    /// The lowercase a–z this event would append, or nil when it belongs to something else.
    ///
    /// Only a *bare* letter is filter input. A letter carrying physical modifiers is a chord
    /// stroke, even when those modifiers are the very ones narrowing the list: ⌥⌘M is
    /// "Minimize All", not the filter query "⌥ ⌘ m". Letting the queue claim it swallowed
    /// the keystroke — the front app never saw ⌥⌘M, and a system hotkey has no menu row for
    /// the panel to complete — so neither the shortcut nor the dismissal happened.
    ///
    /// Shift is the hint layer, not a filter dimension, and a capital letter is still a
    /// letter; it is the one modifier a filter token may carry.
    static func letter(for event: KeyEvent) -> Character? {
        guard let key = event.key,
              key.raw.count == 1,
              let character = key.raw.first,
              character >= "a", character <= "z"
        else { return nil }
        guard event.modifiers.subtracting(.shift).isEmpty else { return nil }
        return character
    }
}
