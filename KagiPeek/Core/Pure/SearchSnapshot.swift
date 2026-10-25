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
struct SearchSnapshot {
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

    var isEmpty: Bool { results.isEmpty }
}
