import Foundation

/// Decides whether the filter's token queue has just spelled a whole shortcut *and* the
/// narrowed panel has converged on a single row.
///
/// The queue is a search box *and* a way of typing a chord one key at a time. Holding ⌥⌘
/// and pressing H is a physical chord: the router sees ⌥⌘H and the front app performs it.
/// But ⌥⌘ added as filter chips leaves the same tokens behind with no keys held down, so the
/// following bare `h` belongs to the queue — `ComposedSwallow` swallows it, the front app
/// never sees ⌥⌘H, and the panel merely narrows to (and selects) the "Hide Others" row. The
/// user then has to press Space, click, or use the context menu to actually run it.
///
/// When the queue now spells a complete one-stroke chord — every modifier token plus exactly
/// one letter — that last key press *was* the shortcut. This pure decision finds the row to
/// run so the engine can take the same execution path as a click, without inventing a second
/// set of rules about what may run.
///
/// **Only one surviving row may be run.** Typing ⌥ ⌘ `c` must stay a way to narrow a long
/// list even when ⌥⌘C is one of the rows it narrows to; auto-running it there would take the
/// choice away from the user. The gate is the panel's own post-rebuild snapshot: the total
/// surviving row count must be exactly one, and the single row the panel actually drew must
/// be the very row whose chord the queue spelled. A count of one that is hidden inside a
/// folded card is not a row the user pointed at, so it does not run either.
///
/// It deliberately does not fire for:
/// - a filter that leaves more than one row (a query, not an unambiguous address);
/// - a single row that is not the exact chord match;
/// - a queue with no modifiers (a bare letter is a query, never a chord);
/// - a queue with more than one letter (`⌥ ⌘ h h` is a search, not a chord);
/// - a chord that is only a prefix of a longer one (`relation` answers `.descend`);
/// - a disabled, restricted or config-tool row (the panel refuses to run those anyway);
/// - a chord nobody owns.
nonisolated enum FilterChordCompletion {
    /// - Parameters:
    ///   - items: the chords the panel can list — the same `state.chordItems` the key router
    ///     and the reachability audit read, so a visible row cannot be missed here.
    ///   - remainingRowIDs: the row ids the narrowed panel drew, in display order. With
    ///     exactly one surviving row this is that one row, and no separate selection lookup
    ///     is needed.
    ///   - remainingRowCount: the panel's total surviving rows across all sources and pages,
    ///     including rows behind a folded card. Counted on the page alone would misread the
    ///     last page of a long result list as "only one row".
    /// - Returns: the id of the row to execute, or nil when the queue is still a query.
    static func rowID(
        filter: PanelFilter,
        items: [BindingItem],
        remainingRowIDs: [String],
        remainingRowCount: Int
    ) -> String? {
        // The gate comes first: no chord matching is worth doing while the user is still
        // looking at a list of candidates, and a mismatch between the count and the drawn
        // rows means the snapshot is not an unambiguous address.
        guard remainingRowCount == 1,
              remainingRowIDs.count == 1
        else { return nil }
        let onlyRowID = remainingRowIDs[0]

        guard !filter.isEmpty else { return nil }
        let letters = filter.letters
        guard letters.count == 1, let character = letters.first else { return nil }
        let modifiers = filter.modifiers
        guard !modifiers.isEmpty else { return nil }

        let probe = KeyChord.combo(modifiers, KeyToken(String(character)))
        // Look only for the row the panel is showing. Reusing the panel's own gate keeps a
        // row it would refuse to run from firing merely because its chord was spelled here.
        guard let match = items.first(where: { item in
            guard item.id == onlyRowID,
                  !item.chord.isEmpty,
                  item.chord.relation(to: probe) == .exact,
                  item.isEnabled
            else { return false }
            return PanelRowActionPlan.outcome(
                request: .execute,
                restriction: RestrictedActionPolicy.restriction(for: item),
                source: item.source,
                hasChord: true
            ) == .run
        }) else { return nil }
        return match.id
    }
}
