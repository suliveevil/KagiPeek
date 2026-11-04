import Foundation

/// Everything the search palette shows or reasons about, as one value.
///
/// The engine used to publish the query, the results, the selection, the visibility, the
/// direct combo answer and the scope as independent `@Published` fields; a view that wanted
/// "one search" had to keep six bindings in step, and a scope change updated four of them.
/// One snapshot means every change replaces the whole value and the palette reads a single
/// source of truth.
///
/// What deliberately stays engine-side: the scope's *icon* (`NSImage` is AppKit) and the
/// scoped app's live catalog / process (AX handles and a click target do not belong in pure
/// state).
nonisolated struct SearchSnapshot {
    var query = ""
    var results: [BindingItem] = []
    var selection = 0
    /// Bumped when the palette should bring the selection into view. Hovering a row also
    /// moves the selection (Return has to act on the row under the pointer), but it must not
    /// move the list — scrolling on every hover is what made the palette's scrollbar chase
    /// the cursor.
    var scrollRequest = 0
    var isVisible = false
    /// The direct answer to a query that spells out a combo, or nil for a plain text search.
    var comboAnswer: ComboLookup.Answer? = nil
    /// The app the palette looks at, or nil for the frontmost one.
    var scopeAppID: String? = nil
    var scopeName = ""
    var scopeItems: [BindingItem] = []
    /// Loading and provenance are separate from "results are empty": a slow scoped scan
    /// and a genuinely empty list must not look the same.
    var loadState: SearchLoadState = .idle
    var usedBuiltInCatalog = false

    /// Starts a fresh palette session: every opening begins with an empty field, the first
    /// row selected and the list at the top.
    ///
    /// Nothing carries over from the previous opening — not the query, the results, the
    /// selection, the scroll request, the combo answer, the scope, or the loading state.
    /// A query left behind is the one thing the user cannot see until they start typing:
    /// the palette would look like a full list while showing matches for text they no
    /// longer remember typing. The engine clears its scope-side caches separately; this
    /// value only owns what the view reads.
    mutating func beginNewSession() {
        query = ""
        results = []
        selection = 0
        scrollRequest &+= 1
        comboAnswer = nil
        loadState = .idle
        usedBuiltInCatalog = false
        scopeAppID = nil
        scopeName = ""
        scopeItems = []
    }

    var isEmpty: Bool { results.isEmpty }
}
