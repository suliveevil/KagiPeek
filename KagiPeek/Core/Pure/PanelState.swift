import Foundation

struct PanelRow: Identifiable {
    let id: String
    /// The chord as this row shows it, already split into glyphs so the view can emphasise
    /// the modifier the user is holding without re-parsing formatted text. With an empty
    /// prefix this is the whole shortcut; one level down it is the stroke still missing.
    let keySegments: [KeyFormatter.Segment]
    let title: String
    /// Where the command lives in the menu bar ("File", "Format › Text"). Rows are ordered
    /// by their shortcut, so the menu level is an annotation next to the title rather than
    /// a section heading that would break the order.
    let note: String
    let isGroup: Bool
    let isEnabled: Bool
    let hasConflict: Bool
    /// Position among the rows on the current page, used for keyboard selection. `-1` means
    /// "not addressable", which is also `PanelState.selectionIndex == -1` ("nothing
    /// selected") — the two are only compared for rows whose `index >= 0`.
    let index: Int
    /// Part of the shortcut currently being pressed.
    let isHighlighted: Bool
    /// The full shortcut has just been pressed; its description is emphasised.
    let isCompleted: Bool
    /// Pinned by the user.
    let isFavorite: Bool

    /// The chord as plain text — the segmented form joined back together, so the two can
    /// never drift.
    var keyLabel: String { keySegments.map(\.text).joined() }
}

struct PanelGroup: Identifiable {
    let id: String
    let title: String
    let rows: [PanelRow]
    /// How many rows the whole section has, when the page only carries a slice of it.
    ///
    /// The heading used to print `rows.count`, which for a section that spans pages is the
    /// count on *this* page — "System hotkeys 15" while 79 exist. Nil means "the count is the
    /// rows here", which is true for every single-page group.
    var totalCount: Int?
}

/// Immutable snapshot the overlay renders. SwiftUI observes the engine, so every field here
/// is replaced wholesale — no partial state to get out of sync.
struct PanelState {
    var isVisible = false
    var isScanning = false
    var isPinned = false
    var prefixLabels: [String] = []
    var groups: [PanelGroup] = []
    var pageIndex = 0
    var pageCount = 1
    var totalCount = 0
    var appName = ""
    var hasConflicts = false
    var usedBuiltInCatalog = false
    var showsFavoritesOnly = false

    /// Page-ordered row ids, so ↑/↓ and the run key can address a row without flattening in
    /// the view.
    var flatRowIDs: [String] = []
    var selectionIndex = -1
    /// The modifier set currently down. While the prefix is still modifier-only it also is
    /// what narrows the list (`PrefixResolver`), and it is what `PanelHighlighter` lights up
    /// in the surviving rows' chords.
    var heldModifiers: ModifierSet = []
    /// Modifiers ticked in the title bar while the panel is open. They are sticky — unlike
    /// `heldModifiers`, which follows the physical keys — and are folded into the next
    /// stroke, so ⌥⌘C can be typed as "click ⌥, click ⌘, press C". A tick narrows the list
    /// while it stands, the same way holding the key does.
    var latchedModifiers: ModifierSet = []
    /// The ticks in the order they were made. `latchedModifiers` is a set and loses that,
    /// but ⌫ has to undo the *last tick*, not the one that happens to come last in
    /// ⌃⌥⇧⌘ order — ticking ⌘ and then ⌥ and pressing ⌫ must drop the ⌥.
    var latchedOrder: [ModifierSet] = []
    var completedRowID: String?

    /// Rows the window is sized for: how many rows the widest list of this panel session
    /// shows — the same filters, with nothing composed.
    ///
    /// Sizing from the page on screen instead made the window change height on every
    /// modifier press, because narrowing removes rows by definition; releasing the modifier
    /// then put them back. On screen that read as the panel jumping. The frame is now set
    /// from this budget once and holds while the list moves inside it. `0` means "not
    /// computed yet" and falls back to the rows on screen.
    var rowBudget = 0
    /// Titled group headings the window reserves for, for the same reason: a heading that
    /// disappears while narrowing must not shrink the frame either.
    var headingBudget = 0

    var isEmpty: Bool { groups.isEmpty }

    /// True when the panel is showing exactly one selectable row.
    ///
    /// Derived, never stored: a second copy of "how many rows there are" is another thing to
    /// keep in sync, and this class of bug is what drift looks like. It also deliberately
    /// reads `flatRowIDs` and not `totalCount` — `totalCount` counts every row of both
    /// sections, while the page in front of the user holds only some of them.
    ///
    /// For display only (a footer hint, emphasising the one remaining row). Which row is
    /// *selected* is `PanelSelection.resolved`'s job: a boolean cannot say "the first one".
    var hasSingleMatch: Bool { flatRowIDs.count == 1 }

    static let hidden = PanelState()
}

/// Small "executed" toast shown after a shortcut completes.
struct HUDState {
    var chord: String
    var title: String
}
