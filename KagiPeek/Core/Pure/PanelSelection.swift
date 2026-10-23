import Foundation

/// The panel's keyboard selection after the rows have been rebuilt.
///
/// The panel used to clamp a previous index into the new row count and nothing else. That
/// is a no-op for the one value the panel actually starts with: `-1` ("nothing selected"),
/// which is also what a modifier press writes before rebuilding. So a panel narrowed to a
/// single row kept "nothing selected", and the run key — whose first act is
/// `guard selectionIndex >= 0` — quietly did nothing. That is the whole which-key promise
/// broken: hold ⌘, one row left, press Return, nothing happens.
///
/// The rule therefore has to answer "what is selected now", not "is the old index still
/// in range":
///
/// - no rows → nothing selected;
/// - **exactly one row → that row.** Narrowing is a decision the user just made; making
///   them press ↓ first would make Return dead exactly when it is most useful.
/// - otherwise the previous row, when it is still there. Selection is deliberately *not*
///   invented for a long list: with forty rows on screen, auto-selecting the first one
///   would let a stray Return run a shortcut the user never looked at.
enum PanelSelection {
    /// - Parameters:
    ///   - previous: the selection before the rebuild. `-1` means "nothing selected".
    ///   - rowCount: how many selectable rows the rebuilt page has.
    /// - Returns: the index to select, or `-1` for "nothing selected".
    static func resolved(previous: Int, rowCount: Int) -> Int {
        guard rowCount > 0 else { return -1 }
        if rowCount == 1 { return 0 }
        guard previous >= 0, previous < rowCount else { return -1 }
        return previous
    }
}
