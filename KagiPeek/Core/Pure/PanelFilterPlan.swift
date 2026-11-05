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
        // Letters only belong to the filter once it has something in it. An empty filter
        // makes `filter.modifiers` an empty superset, so without this guard every bare
        // letter would be appended — stealing ⌘C / ⌥C chord strokes and the latched
        // modifiers' "tick ⌥ then press C" path, and clearing the prefix on top.
        guard !filter.isEmpty else { return .none }
        guard !event.isRepeat, let letter = letter(for: event, filter: filter) else { return .none }
        return .append(letter)
    }

    /// The lowercase a–z this event would append, or nil when it belongs to something else.
    ///
    /// Only modifiers the filter already holds are allowed through: ⌘F and ⌥F remain the
    /// front app's (or a hotkey's) chord, while a lone F after ⌃ was pressed filters. Shift
    /// is stripped because it is the hint layer, never a filter dimension.
    static func letter(for event: KeyEvent, filter: PanelFilter) -> Character? {
        guard let key = event.key,
              key.raw.count == 1,
              let character = key.raw.first,
              character >= "a", character <= "z"
        else { return nil }
        let pressed = event.modifiers.subtracting(.shift)
        guard filter.modifiers.isSuperset(of: pressed) else { return nil }
        return character
    }
}
