import Foundation

nonisolated struct PanelRow: Identifiable {
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
    /// "not addressable", which is also the panel cursor's sentinel (`-1`, nothing
    /// selected) — the two are only compared for rows whose `index >= 0`.
    let index: Int
    /// Part of the shortcut currently being pressed.
    let isHighlighted: Bool
    /// The full shortcut has just been pressed; its description is emphasised.
    let isCompleted: Bool
    /// Pinned by the user.
    let isFavorite: Bool
    /// The Shift-hint glyph (0–9, a–z) standing in for the chord while the hint layer is
    /// up. Nil means the chord column shows the shortcut as usual.
    let hintLabel: String?
    /// Which source owns this row. The view uses it to decide whether a right-click may
    /// offer Run at all (config rows never run).
    var source: BindingSource = .menu
    /// Set for a restricted system action the panel shows but never runs. The view paints
    /// the title red and drops Run from the context menu.
    var restriction: RestrictedAction? = nil
    /// Whether the item has a chord at all. A row without one cannot copy a shortcut and
    /// falls back to its menu path.
    var hasChord: Bool = true
    /// Why the reachability audit decided this row cannot be triggered right now, or nil
    /// when its last key does reach the front app. A visible row that silently does nothing
    /// is worse than no row, so the view warns in the gutter.
    var unreachableReason: PanelTriggerAudit.Reason? = nil

    /// The chord as plain text — the segmented form joined back together, so the two can
    /// never drift.
    var keyLabel: String { keySegments.map(\.text).joined() }

    var isRestricted: Bool { restriction != nil }
}

nonisolated struct PanelGroup: Identifiable {
    let id: String
    let title: String
    let rows: [PanelRow]
    /// How many rows the whole section has, when the page only carries a slice of it.
    ///
    /// The heading used to print `rows.count`, which for a section that spans pages is the
    /// count on *this* page — "System hotkeys 15" while 79 exist. Nil means "the count is the
    /// rows here", which is true for every single-page group.
    var totalCount: Int?
    /// A card whose rows can be hidden by clicking its title — the tool sections.
    var isCollapsible = false
    /// Whether a collapsible card currently shows its rows. Fixed for every other card.
    var isExpanded = true
    /// The config tool this card belongs to, when it is one. The identity travels with the
    /// card so a click toggles the tool the user pointed at, not a shared section flag.
    var tool: ConfigTool? = nil
}

/// Immutable snapshot the overlay renders. SwiftUI observes the engine, so every field here
/// is replaced wholesale — no partial state to get out of sync.
nonisolated struct PanelState {
    var isVisible = false
    var isScanning = false
    var isPinned = false
    var prefixLabels: [String] = []
    var groups: [PanelGroup] = []
    var pageIndex = 0
    var pageCount = 1
    var totalCount = 0
    /// Every row of all three sources, including the tool rows while that section is folded.
    var appName = ""
    var hasConflicts = false
    var usedBuiltInCatalog = false
    var showsFavoritesOnly = false

    /// Page-ordered row ids, so ↑/↓ and the run key can address a row without flattening in
    /// the view.
    var flatRowIDs: [String] = []
    /// The panel's ordered filter tokens: modifiers and letters in the order they were
    /// added. Empty means "the whole list"; non-empty replaces the old prefix narrowing.
    var filter = PanelFilter()
    /// The modifier set currently down. It is kept in step with `filter.modifiers`, and it
    /// is what `PanelHighlighter` lights up in the surviving rows' chords.
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
    /// A tap of Shift toggled the hint layer: the first 36 rows show their 0–9 / a–z labels
    /// and a bare glyph press runs the matching row. Sticky — it survives the Shift release,
    /// so the addressing key carries no modifier — and cleared when the row runs, Shift is
    /// tapped again, or Esc leaves the layer without closing the panel. Kept in the snapshot
    /// because the tap's swallow decision reads it, and because the rows have to be rebuilt
    /// when it flips.
    var shiftHintActive = false
    /// The config-tool cards the user opened. Empty on every new panel session: the tool
    /// shortcuts are the third source and should not push the app's own list off the first
    /// page before the user asks for them.
    var expandedTools: Set<ConfigTool> = []
    /// The panel is narrowing (a filter token stands). Tool cards are opened by the filter
    /// while it stands, without touching `expandedTools`, so closing the filter brings the
    /// user's own fold choices back unchanged.
    var isNarrowing = false
    /// The panel was opened by the modifier gesture and the trigger key is still down.
    /// Until that key is released, a `flagsChanged` must not narrow the list: the press
    /// that summoned the panel is a trigger, not a filter. Cleared by the release edge.
    var triggerNarrowPending = false
    /// The row whose menu element is being resolved off the main thread. Non-nil means a run
    /// is already in flight, and further activations are refused until it finishes or the
    /// panel closes.
    var runningRowID: String?

    /// Rows the window is sized for: how many rows the widest list of this panel session
    /// shows — the same filters, with nothing composed.
    ///
    /// Sizing from the page on screen instead made the window change height on every
    /// modifier press, because narrowing removes rows by definition; releasing the modifier
    /// then put them back. On screen that read as the panel jumping. The frame is now set
    /// from this budget once and holds while the list moves inside it. `0` means "not
    /// computed yet" and falls back to the rows on screen.
    ///
    /// A fold is structural, not a list moving, so it does resize: opening a tool card adds
    /// its rows to the budget. A filter that opens every card for its duration is sized for
    /// the same reason — the frame is allocated once for the widest list that filter can
    /// draw, and holds while its tokens change.
    var rowBudget = 0
    /// Titled group headings the window reserves for, for the same reason: a heading that
    /// disappears while narrowing must not shrink the frame either.
    var headingBudget = 0

    var isEmpty: Bool { groups.isEmpty }

    /// True when the panel is showing exactly one selectable row.
    ///
    /// Derived, never stored: a second copy of "how many rows there are" is another thing to
    /// keep in sync, and this class of bug is what drift looks like. It also deliberately
    /// reads `flatRowIDs` and not `totalCount` — `totalCount` counts every row of all three
    /// sources, while the page in front of the user holds only some of them.
    ///
    /// For display only (a footer hint, emphasising the one remaining row). Which row is
    /// *selected* is `PanelSelection.resolved`'s job: a boolean cannot say "the first one".
    var hasSingleMatch: Bool { flatRowIDs.count == 1 }

    /// Claims the run slot for `rowID`. Returns false when another run is already in flight,
    /// so a double click cannot queue two activations of the same row.
    mutating func beginRunning(rowID: String) -> Bool {
        guard runningRowID == nil else { return false }
        runningRowID = rowID
        return true
    }

    /// Releases the slot only when it still belongs to this row: a stale completion after
    /// the panel moved to another app must not clear the new row's state.
    mutating func endRunning(rowID: String) {
        if runningRowID == rowID { runningRowID = nil }
    }

    /// Resets the transient state one panel session owns, before the first rebuild.
    ///
    /// `shiftHintActive` matters here: the Shift hint layer belongs to the session that
    /// raised it, so a panel opened again must not start with 0–9 / a–z standing in for the
    /// chords. The other fields are the page position and transient filter the rebuild
    /// replaces; the keyboard cursor lives on `EngineState` and is reset with the session.
    mutating func beginNewSession() {
        pageIndex = 0
        completedRowID = nil
        prefixLabels = []
        filter.clear()
        heldModifiers = []
        shiftHintActive = false
        expandedTools = []
        isNarrowing = false
        triggerNarrowPending = false
    }

    static let hidden = PanelState()
}
