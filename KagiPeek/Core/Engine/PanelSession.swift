import AppKit

/// The panel's session state and rendering: what rows exist, how they are ordered and
/// paginated, which one is selected, and what a click or key does to it.
///
/// Opening and dismissing the panel stay in the engine: those manipulate the input phase,
/// the tap's captured keys and the pointer, which is the input router's job. This class
/// starts from "the panel is visible" and never changes that by itself.
@MainActor
final class PanelSession {
    private let state: EngineState
    private let usageStore: UsageStore
    private let localization: Localization
    private let presenters: EnginePresenters
    private let rowRunner: RowRunner
    private let isPreviewing: () -> Bool
    private let frontmostName: () -> String
    private let dismissPanel: () -> Void
    private let dismissEverything: () -> Void
    private let onCapturedKeysChanged: () -> Void
    private let onInputStateChanged: () -> Void
    /// Same disabled row, same explanation: at most once per `DisabledNoticeGate.interval`.
    private var disabledNoticeGate = DisabledNoticeGate()

    init(
        state: EngineState,
        usageStore: UsageStore,
        localization: Localization,
        presenters: EnginePresenters,
        rowRunner: RowRunner,
        isPreviewing: @escaping () -> Bool,
        frontmostName: @escaping () -> String,
        dismissPanel: @escaping () -> Void,
        dismissEverything: @escaping () -> Void,
        onCapturedKeysChanged: @escaping () -> Void,
        onInputStateChanged: @escaping () -> Void
    ) {
        self.state = state
        self.usageStore = usageStore
        self.localization = localization
        self.presenters = presenters
        self.rowRunner = rowRunner
        self.isPreviewing = isPreviewing
        self.frontmostName = frontmostName
        self.dismissPanel = dismissPanel
        self.dismissEverything = dismissEverything
        self.onCapturedKeysChanged = onCapturedKeysChanged
        self.onInputStateChanged = onInputStateChanged
    }

    /// Rows per page: `maxItemsPerPage` is an upper bound, not a target. A 60-row page in a
    /// 720 pt window put its last rows under the footer (or past the screen edge), so the
    /// geometry gets the final say. The arithmetic is pure (`OverlayMetrics`) and holds no
    /// `Theme` values: how rows are counted must not move when a corner radius does.
    /// Internal for `PreviewScenarios`, which computes the boundary page from it.
    var panelPageSize: Int {
        let settings = state.settings
        let configured = max(1, settings.maxItemsPerPage)
        guard let screen = NSScreen.main else { return configured }
        let visible = screen.visibleFrame.size
        let columns: Int
        let panelHeight: CGFloat
        switch settings.panelPlacement {
        case .fillScreen:
            columns = max(1, min(4, Int((visible.width - OverlayMetrics.padding * 2) / OverlayMetrics.denseColumnStride)))
            panelHeight = visible.height
        case .fixedSize:
            columns = max(1, min(settings.columnCount, OverlayMetrics.columns(forWidth: CGFloat(settings.fixedPanelWidth)))
            panelHeight = min(CGFloat(settings.fixedPanelHeight), visible.height)
        case .coverWindow, .besideWindow:
            columns = max(1, settings.columnCount)
            panelHeight = min(OverlayMetrics.maxPanelHeight, visible.height)
        }
        return OverlayMetrics.fittedPageSize(
            maxItemsPerPage: configured,
            columns: columns,
            panelHeight: panelHeight,
            // Two cards at most: the app's section and the system hotkeys. Reserved on
            // every page so the page count cannot wobble when one of them is empty.
            cardCount: 2,
            headingCount: 2
        )
    }

    /// How many rows and headings the panel window must be sized for: the widest list this
    /// session can show, which is the same list with nothing composed.
    ///
    /// Modifiers only ever remove rows, so sizing the window from the page on screen made
    /// it shrink on every press and grow again on release — the panel visibly jumping. The
    /// frame is now computed from this budget and holds while the list moves inside it.
    /// The favorites rules that feed ranking, row budgeting and search, as one value — see
    /// `FavoritesPolicy`. The cache keys hold it whole, so a rule change cannot leave a
    /// stale order or budget behind.
    private func unnarrowedBudget() -> (rows: Int, headings: Int) {
        let key = RowBudgetKey(
            scannedAt: state.catalog.scannedAt,
            showsFavoritesOnly: state.favoritesPolicy.showsFavoritesOnly,
            filter: state.panel.filter,
            includeDisabled: state.settings.showDisabledItems,
            ignoredSignature: ignoredSignature,
            systemCount: state.systemBindings.count,
            pageSize: panelPageSize
        )
        if let cached = state.rowBudgetCache, cached.key == key {
            return (cached.rows, cached.headings)
        }
        var hits = PrefixResolver.hits(
            for: .empty,
            in: state.catalog.items,
            includeDisabled: state.settings.showDisabledItems
        ).filter { !state.isIgnored($0.item) }
        hits = state.favoritesPolicy.favoritesOnly(hits) { usageStore.isFavorite($0.item.usageKey) }
        let total = hits.count
        let pageSize = key.pageSize
        // Both sections flow through the same pages. A short list reserves only its own
        // rows; the system section's heading still gets its one strip.
        let headings = state.systemBindings.isEmpty ? 1 : 2
        let allocation = PanelBudget.budget(totalRows: total, pageSize: pageSize, headings: headings)
        state.rowBudgetCache = (key, allocation.rows, allocation.headings)
        return (allocation.rows, allocation.headings)
    }

    /// One page of the ranked sequence, plus where it sits in the whole.
    ///
    /// A shape rather than a tuple so the three numbers travel together: `pageIndex` alone is
    /// meaningless without the `pageCount` it was clamped against.
    private struct PanelPage {
        let index: Int
        let count: Int
        let entries: [PanelEntry]
    }

    /// The name the app's own section is headed with.
    ///
    /// Both sections get a card, and a card needs a name: the app's own section is the one the
    /// title bar names, so the same name heads it — with the count the title bar has no room
    /// for. Empty until a scan names the front app.
    private var panelSectionTitle: String {
        state.appName.isEmpty ? frontmostName() : state.appName
    }

    /// Internal for `PreviewScenarios`, which jumps between pages. Every other caller is in
    /// this file — the panel is rebuilt after a state change, never on demand from outside.
    ///
    /// Five phases, each with one job: slice the page, describe its rows, build them, and
    /// write the result back. Split at the seams the blank lines were already drawing.
    func rebuildPanel() {
        guard state.panel.isVisible else { return }
        let sequence = panelSequence()
        let page = panelPage(of: sequence, pageSize: panelPageSize)
        let systemTitle = localization.text(.groupSystemHotkeys)
        let sectionTitle = panelSectionTitle
        let specs = rowSpecs(
            for: page.entries,
            highlighted: highlightedIDs(for: page.entries.map(\.hit)),
            systemTitle: systemTitle,
            sectionTitle: sectionTitle,
            hintLabels: hintLabels(for: sequence)
        )
        if isPreviewing() {
            let systemRows = sequence.filter(\.isSystem).count
            Diag.info(.ui, "panel sequence: app=\(sequence.count - systemRows) system=\(systemRows) page=\(page.index + 1)/\(page.count) rows=\(specs.count)")
        }
        applyPanelUpdate(
            sequence: sequence,
            specs: specs,
            page: page,
            systemTitle: systemTitle,
            sectionTitle: sectionTitle
        )
    }

    /// Clamps the requested page into the sequence. A narrowing prefix can delete the page the
    /// user was on, and a stale index would otherwise render an empty panel.
    private func panelPage(of sequence: [PanelEntry], pageSize: Int) -> PanelPage {
        let pageCount = max(1, Int(ceil(Double(sequence.count) / Double(pageSize))))
        let pageIndex = min(max(0, state.panel.pageIndex), pageCount - 1)
        let entries = Array(sequence.dropFirst(pageIndex * pageSize).prefix(pageSize))
        return PanelPage(index: pageIndex, count: pageCount, entries: entries)
    }

    /// Row id → Shift-hint glyph for the first 36 entries of the sequence.
    ///
    /// The table is anchored to the whole sequence, not the page, so pressing Shift on page 2
    /// addresses the same rows as on page 1 — the hint answers "which row", not "which
    /// visible row". Rows that are not on this page simply do not render their label.
    private func hintLabels(for sequence: [PanelEntry]) -> [String: String] {
        guard state.panel.shiftHintActive, state.prefix.isEmpty else { return [:] }
        return ShiftHintLayer.labels(for: sequence.map(\.hit.id))
    }

    /// One row per entry, described for the builder.
    private func rowSpecs(
        for entries: [PanelEntry],
        highlighted: Set<String>,
        systemTitle: String,
        sectionTitle: String,
        hintLabels: [String: String]
    ) -> [PanelRowBuilder.Spec] {
        entries.map { entry in
            let hit = entry.hit
            // A system hotkey macOS refuses to name used to arrive as a row whose command
            // column was an em dash, and the same dash also said "no keyboard shortcut" a few
            // rows down. The only true thing about that row is its chord, so the chord becomes
            // the name and the key column stays empty.
            let unnamedSystemHotkey = entry.isSystem && hit.item.title == DescriptionCleaner.placeholder
            let renderedChord = KeyFormatter.render(hit.item.chord, style: state.settings.keyStyle)
            return PanelRowBuilder.Spec(
                id: hit.id,
                keySegments: unnamedSystemHotkey ? [] : keySegments(for: hit),
                title: unnamedSystemHotkey
                    ? renderedChord
                    : DescriptionCleaner.truncate(hit.item.title, maxLength: state.settings.maxDescriptionLength),
                // The system card's header already names the section, so repeating it in
                // every row's note column would be the same word 79 times.
                note: entry.isSystem ? "" : menuPath(of: hit.item),
                // The app's heading exists for the menu-bar order, where a card title tells
                // the user which menu a block came from. Chord order is one flat list, so it
                // draws no heading; the system's hotkeys keep theirs either way.
                groupTitle: entry.isSystem
                    ? systemTitle
                    : (state.settings.panelOrder == .byMenuGroup ? sectionTitle : ""),
                // The chevron and the click share one answer: a row without a chevron is a
                // shortcut the user can run (`KeyChord.isFinalStroke`).
                isGroup: !hit.item.chord.isFinalStroke(after: state.prefix),
                isEnabled: hit.item.isEnabled,
                hasConflict: state.conflictIDs.contains(hit.item.id),
                isHighlighted: highlighted.contains(hit.item.id),
                isCompleted: state.panel.completedRowID == hit.item.id,
                isFavorite: usageStore.isFavorite(hit.item.usageKey),
                hintLabel: hintLabels[hit.id]
            )
        }
    }

    /// Builds the rows and writes the whole panel state back in one pass.
    private func applyPanelUpdate(
        sequence: [PanelEntry],
        specs: [PanelRowBuilder.Spec],
        page: PanelPage,
        systemTitle: String,
        sectionTitle: String
    ) {
        let built = PanelRowBuilder.build(specs)
        let budget = unnarrowedBudget()
        // Both sections span pages, so their headings print the section's size rather than the
        // slice on screen — "15" was the count of the page, not of the section.
        let systemTotal = sequence.reduce(0) { $0 + ($1.isSystem ? 1 : 0) }
        let appTotal = sequence.count - systemTotal
        state.panel.groups = built.groups.map { group in
            PanelGroup(
                id: group.id,
                title: group.title,
                rows: group.rows,
                totalCount: group.title == systemTitle ? systemTotal : appTotal
            )
        }
        state.panel.flatRowIDs = built.flatRowIDs
        state.panel.rowBudget = budget.rows
        state.panel.headingBudget = budget.headings
        state.panel.selectionIndex = PanelSelection.resolved(
            previous: state.panel.selectionIndex,
            rowCount: built.flatRowIDs.count
        )
        state.panel.prefixLabels = KeyFormatter.breadcrumb(for: state.prefix, style: state.settings.keyStyle)
        state.panel.pageIndex = page.index
        state.panel.pageCount = page.count
        state.panel.totalCount = sequence.count
        state.panel.appName = sectionTitle
        state.panel.hasConflicts = !state.conflicts.isEmpty
        state.panel.showsFavoritesOnly = state.showsFavoritesOnly
        state.panel.usedBuiltInCatalog = state.usedBuiltInCatalog
        state.panel.isPinned = state.phase == .active
        presenters.panel.presentPanel(state: state.panel, settings: state.settings)
    }

    /// Hits in ranked order; shared by rendering and by "jump to the page of this row".
    /// Changes whenever the rules change in any way, including an edit that keeps the count.
    private var ignoredSignature: String {
        state.settings.ignoredCommands.map(\.id).joined(separator: ",")
    }

    private func orderedHits() -> [PrefixHit] {
        let cacheKey = OrderedHitsKey(
            prefix: state.prefix,
            heldModifiers: state.panel.heldModifiers,
            filter: state.panel.filter,
            latchedModifiers: state.panel.latchedModifiers,
            scannedAt: state.catalog.scannedAt,
            favorites: state.favoritesPolicy,
            includeDisabled: state.settings.showDisabledItems,
            panelOrder: state.settings.panelOrder,
            ignoredSignature: ignoredSignature
        )
        if let cached = state.orderedHitsCache, cached.key == cacheKey {
            return cached.hits
        }
        let hits = PrefixResolver.hits(
            for: state.prefix,
            in: state.catalog.items,
            includeDisabled: state.settings.showDisabledItems
        ).filter { !state.isIgnored($0.item) }
        // The default order is the shortcut itself, not a score and not the menu it came
        // from: ⌘C, ⌘V and ⌘X belong together. The modifiers being composed decide which
        // block comes first, so pressing ⌘ — or ticking it — answers the question without
        // hiding the answer for every other modifier. "By menu group" keeps each top-level
        // menu contiguous instead; both orders are pure and return the same items.
        let emphasized = state.pending.effective
        var sorted = state.settings.panelOrder.sorted(
            hits,
            by: \.item,
            emphasizing: emphasized
        )
        sorted = state.favoritesPolicy.favoritesOnly(sorted) { usageStore.isFavorite($0.item.usageKey) }
        sorted = state.favoritesPolicy.pinningFavoritesFirst(sorted) { usageStore.isFavorite($0.item.usageKey) }
        state.orderedHitsCache = (cacheKey, sorted)
        return sorted
    }

    /// The panel's rows as one sequence: the app's section, then the system's.
    ///
    /// `orderedHits()` stays app-only — it is what the prefix, the held modifiers and the
    /// order cache reason about. The system section is appended here, once, so pagination and
    /// "jump to the page of this row" walk exactly the sequence the panel draws.
    /// Internal for `PreviewScenarios`, which needs the page a heading lands on.
    func panelSequence() -> [PanelEntry] {
        let appHits = orderedHits()
        let combined: [PanelEntry]
        if state.prefix == .empty, !state.systemBindings.isEmpty {
            let items = state.favoritesPolicy.favoritesOnly(state.systemBindings) { usageStore.isFavorite($0.usageKey) }
            var sorted = PanelOrdering.sorted(items, emphasizing: state.pending.effective)
            sorted = state.favoritesPolicy.pinningFavoritesFirst(sorted) { usageStore.isFavorite($0.usageKey) }
            combined = PanelSections.combine(app: appHits, system: PanelSections.hits(for: sorted))
        } else {
            combined = PanelSections.combine(app: appHits, system: [])
        }
        // The filter is a query over the combined sequence, after the app/system split and
        // after every other rule: it only decides which rows survive, never their order.
        guard let ids = PanelFilterPlan.matchingIDs(filter: state.panel.filter, corpus: filterCorpus()) else {
            return combined
        }
        return combined.filter { ids.contains($0.id) }
    }

    /// The corpus the filter query runs against: the palette's if it is already built,
    /// otherwise one over the panel's own rows. System hotkeys are part of the panel, so
    /// they are part of the fallback corpus too.
    private func filterCorpus() -> SearchCorpus {
        if let corpus = state.searchCorpus { return corpus }
        return SearchCorpus(
            items: state.catalog.items + state.systemBindings,
            style: state.settings.keyStyle
        )
    }

    /// Rows that are part of the shortcut currently being pressed.
    ///
    /// Only the visible page can glow, so the highlighter is handed the page's items instead
    /// of the whole catalog. (The previous version dropped `pageHits` and then recomputed the
    /// same prefix over every item.)
    private func highlightedIDs(for pageHits: [PrefixHit]) -> Set<String> {
        PanelHighlighter.highlightedIDs(
            items: pageHits.map(\.item),
            prefix: state.prefix,
            heldModifiers: state.pending.effective
        )
    }

    /// What the row's shortcut column shows.
    ///
    /// While the list is narrowed by held modifiers — and with an empty prefix — the row
    /// shows its whole chord. Holding ⌘ used to strip the ⌘ and print just `C`; the glyph now
    /// stays and is lit instead (see `PanelOrdering`), so a narrowed row still reads `⌘C`.
    /// Only after the user has actually typed a key does the row drop back to the which-key
    /// view and print the stroke still missing, because the breadcrumb already names what
    /// was typed.
    private func keySegments(for hit: PrefixHit) -> [KeyFormatter.Segment] {
        // A menu item with no keyboard shortcut still gets a row; its shortcut column stays
        // blank rather than saying "no shortcut".
        if hit.item.chord.isEmpty {
            return []
        }
        let shown: KeyChord
        if state.prefix.isEmpty || state.prefix.isModifierOnly {
            shown = hit.item.chord
        } else if let step = hit.item.chord.step(after: state.prefix) {
            shown = KeyChord([step])
        } else {
            shown = .empty
        }
        return KeyFormatter.segments(for: shown, style: state.settings.keyStyle)
    }

    /// Menu-bar path ("File", "Format › Text") used as the row's annotation.
    private func menuPath(of item: BindingItem) -> String {
        item.group.joined(separator: " › ")
    }

    private func ensurePage(containing itemID: String) {
        let sequence = panelSequence()
        guard let index = sequence.firstIndex(where: { $0.id == itemID }) else { return }
        state.panel.pageIndex = index / panelPageSize
    }

    // MARK: - Favourites and panel actions

    func toggleFavoritesFilter() {
        state.showsFavoritesOnly.toggle()
        state.panel.pageIndex = 0
        // No `selectionIndex = -1`: narrowing to one row has to leave that row selected, and
        // a selection that is still visible has to survive. `PanelSelection.resolved` decides.
        rebuildPanel()
    }

    /// Ticks or unticks one of the title bar's modifier chips.
    ///
    /// A tick composes a stroke — a ticked ⌥ plus a pressed C is ⌥⌘C — and keeps narrowing
    /// the list while it stands.
    func toggleModifier(_ modifier: ModifierSet) {
        toggleLatched(modifier)
    }

    /// Ticks or unticks a whole set — one tap can carry ⌥ and ⌘ together.
    private func toggleLatched(_ modifiers: ModifierSet) {
        let next = LatchedTicks.toggling(
            modifiers.ordered,
            latched: state.panel.latchedModifiers,
            order: state.panel.latchedOrder
        )
        state.panel.latchedModifiers = next.latched
        state.panel.latchedOrder = next.order
        refreshAfterLatchedChange()
        onInputStateChanged()
    }

    /// Undoes one tick, the most recent one first.
    @discardableResult
    func popLatched() -> Bool {
        guard let next = LatchedTicks.popping(
            latched: state.panel.latchedModifiers,
            order: state.panel.latchedOrder
        ) else { return false }
        state.panel.latchedModifiers = next.latched
        state.panel.latchedOrder = next.order
        onInputStateChanged()
        return true
    }

    /// Re-seeds the prefix and redraws after the ticked set changed.
    func refreshAfterLatchedChange() {
        if state.panel.filter.isEmpty {
            if state.prefix.isEmpty || state.prefix.isModifierOnly {
                let effective = state.pending.effective
                state.prefix = effective.isEmpty ? .empty : .modifiers(effective)
            }
        } else {
            // The filter already does the narrowing; a prefix on top would narrow twice.
            state.prefix = .empty
        }
        state.orderedHitsCache = nil
        state.panel.pageIndex = 0
        rebuildPanel()
        onCapturedKeysChanged()
    }

    /// Undoes the most recent tick, if there is one. The input path uses this before
    /// treating Backspace as "go up a level".
    func undoLastTick() -> Bool {
        guard popLatched() else { return false }
        refreshAfterLatchedChange()
        return true
    }

    func toggleFavorite(rowID: String) {
        let item = state.catalog.items.first(where: { $0.id == rowID })
            ?? state.systemBindings.first(where: { $0.id == rowID })
        guard let item else { return }
        usageStore.toggleFavorite(item.usageKey)
        // A pin changes the order but not the press counter, so the cache has to be dropped.
        state.orderedHitsCache = nil
        rebuildPanel()
    }

    /// Rows can come from the frontmost app's catalog, the app the browser window is
    /// showing, or the system hotkey list. One resolver keeps clicks and keys honest.
    private func item(forRowID rowID: String) -> BindingItem? {
        state.catalog.items.first(where: { $0.id == rowID })
            ?? state.systemBindings.first(where: { $0.id == rowID })
    }

    /// What a copy puts on the pasteboard: the shortcut when there is one, the menu path
    /// when there is not.
    ///
    /// The draft asks for exactly that. A command with no shortcut still has a path, and
    /// "nothing to copy" was the one answer a user could not act on.
    private func copyPayload(forRowID rowID: String) -> String? {
        guard let item = item(forRowID: rowID) else { return nil }
        let chord = KeyFormatter.render(item.chord, style: state.settings.keyStyle)
        if !chord.isEmpty { return chord }
        let path = menuPath(of: item)
        return path.isEmpty ? nil : path
    }

    func copyShortcut(rowID: String) {
        // Copying an empty string would wipe the pasteboard and report success.
        guard let text = copyPayload(forRowID: rowID) else {
            presenters.notices.show(
                chord: "!",
                title: localization.text(.panelNothingToCopy),
                kind: .failure
            )
            return
        }
        copyToPasteboard(text)
    }

    /// Copy with the toast both surfaces share, so a copy that changes nothing on screen
    /// still answers the click.
    func copyRow(rowID: String) {
        // Saying "copied" after clearing the pasteboard would be a lie the user only
        // notices later.
        guard let text = copyPayload(forRowID: rowID) else {
            presenters.notices.show(
                chord: "!",
                title: localization.text(.panelNothingToCopy),
                kind: .failure
            )
            return
        }
        guard copyToPasteboard(text) else {
            presenters.notices.show(
                chord: "!",
                title: localization.text(.panelCopyFailed),
                kind: .failure
            )
            return
        }
        presenters.notices.show(chord: text, title: localization.text(.panelCopied))
    }

    func showSettings() {
        dismissEverything()
        presenters.settings.showSettings()
    }

    /// The panel's conflict badge is a shortcut into the Conflicts page, not just a warning.
    func showConflicts() {
        dismissEverything()
        presenters.settings.showConflicts()
    }

    /// Page keys loop: next on the last page returns to the first, previous on the first
    /// page jumps to the last. A one-page list is left untouched — no rebuild, no flash.
    func nextPage() {
        let target = PaginationPlan.nextPage(from: state.panel.pageIndex, pageCount: state.panel.pageCount)
        guard PaginationPlan.moved(from: state.panel.pageIndex, to: target, pageCount: state.panel.pageCount) else {
            return
        }
        state.panel.pageIndex = target
        state.panel.selectionIndex = -1
        rebuildPanel()
    }

    func previousPage() {
        let target = PaginationPlan.previousPage(from: state.panel.pageIndex, pageCount: state.panel.pageCount)
        guard PaginationPlan.moved(from: state.panel.pageIndex, to: target, pageCount: state.panel.pageCount) else {
            return
        }
        state.panel.pageIndex = target
        state.panel.selectionIndex = -1
        rebuildPanel()
    }

    // MARK: - Panel execution

    func moveSelection(_ delta: Int) {
        guard state.panel.isVisible, !state.panel.flatRowIDs.isEmpty else { return }
        let last = state.panel.flatRowIDs.count - 1
        state.panel.selectionIndex = min(max(-1, state.panel.selectionIndex + delta), last)
    }

    /// The run key / copy key pressed on the selected panel row.
    func performSelectedPanelRow(action: RowAction) {
        guard state.panel.selectionIndex >= 0, state.panel.flatRowIDs.indices.contains(state.panel.selectionIndex) else {
            // The run key on a panel with nothing selected used to be indistinguishable from
            // a broken key: no execution, no copy, no log. Say why.
            let index = state.panel.selectionIndex
            let rows = state.panel.flatRowIDs.count
            let name = action.rawValue
            Diag.info(.run, "\(name) key ignored: no row selected (index=\(index), rows=\(rows))")
            return
        }
        performPanelRow(rowID: state.panel.flatRowIDs[state.panel.selectionIndex], action: action)
    }

    /// A click and the run key share one contract: run or copy, as asked for.
    func performPanelRow(rowID: String, action: RowAction) {
        switch action {
        case .execute: activate(rowID: rowID)
        case .copy: copyRow(rowID: rowID)
        }
    }

    /// Cursor moved over a row: make it the selected row so Return acts on it.
    func select(rowID: String) {
        guard state.panel.isVisible, let index = state.panel.flatRowIDs.firstIndex(of: rowID) else { return }
        guard state.panel.selectionIndex != index else { return }
        state.panel.selectionIndex = index
    }

    /// Click in the panel: close it and trigger the command in the front app — by pressing
    /// the menu item when there is one, by replaying the chord otherwise — the same
    /// contract as clicking a search result.
    /// Runs the row the user picked, in whichever namespace owns it.
    ///
    /// A row belongs to exactly one namespace, so this is a router into the three effects
    /// below rather than a function that does the work. Split at the same seams the
    /// `if`-chain already had: catalog row, system hotkey, unknown id.
    func activate(rowID: String) {
        if let item = state.catalog.items.first(where: { $0.id == rowID }) {
            activateCatalogItem(item, rowID: rowID)
        } else if let system = state.systemBindings.first(where: { $0.id == rowID }) {
            rowRunner.runSystemHotkey(system)
        } else {
            // Neither namespace knows this id. Reachable only if a row and the catalog
            // disagree, which used to present itself as "clicking does nothing".
            Diag.error(.run, "row \(rowID) is in neither the catalog nor the system hotkeys")
        }
    }

    /// A catalog row either opens the level below it or runs the command.
    ///
    /// A restored row has to re-walk its menu path before it can be pressed, so a run is
    /// two-phase: claim the row on the main actor (the panel draws it as running and a
    /// second click is refused), resolve the element on the catalog's element queue, then
    /// come back here to press. If the panel closed while the walk was in flight the claim
    /// disappears with `dismissPanel` and the completion is dropped.
    private func activateCatalogItem(_ item: BindingItem, rowID: String) {
        if let step = nextLevelStep(for: item) {
            enterNextLevel(of: item, step: step)
            return
        }
        guard item.isEnabled else {
            Diag.info(.run, "ignoring disabled row \(item.title)")
            // A row that does nothing when clicked reads as a broken panel. The reason is
            // spoken once per row per three seconds, not on every click.
            if disabledNoticeGate.shouldShow(rowID: rowID, at: Date()) {
                presenters.notices.show(
                    chord: "",
                    title: localization.text(.panelDisabledReason),
                    kind: .info
                )
            }
            return
        }
        guard state.panel.beginRunning(rowID: rowID) else {
            Diag.debug(.run, "ignoring repeated activation of \(rowID): a run is in flight")
            return
        }
        rebuildPanel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let element = await self.rowRunner.resolveElement(forRowID: rowID)
            guard self.state.panel.runningRowID == rowID else { return }
            self.state.panel.endRunning(rowID: rowID)
            self.usageStore.record(usageKey: item.usageKey)
            self.dismissPanel()
            await self.rowRunner.run(item, rowID: rowID, element: element, origin: .panel)
        }
    }

    /// - Returns: the step to open, or nil when this row is a command to run.
    ///
    /// Only a row with a level below it opens. A row showing the last stroke is a complete
    /// shortcut as far as the user is concerned — it is drawn without a chevron — so running
    /// it replays the whole chord.
    ///
    /// Descending a final stroke used to push the prefix onto the complete chord; `hits` then
    /// dropped that row, because `nextKey(after:)` is nil once the prefix is the whole chord.
    /// The panel emptied itself instead of running.
    private func nextLevelStep(for item: BindingItem) -> KeyStep? {
        guard !item.chord.isFinalStroke(after: state.prefix),
              let step = item.chord.step(after: state.prefix),
              step.key != nil
        else { return nil }
        return step
    }

    /// The click-side counterpart of `descend(_:)`.
    ///
    /// Deliberately not shared with it, because the two differ: the keyboard path clears
    /// `latchedModifiers` (the ticks have been folded into the stroke it just built), while
    /// this one leaves them alone. That asymmetry is inherited from before this split and is
    /// preserved here rather than "fixed" — changing it is a behaviour change, not a refactor.
    private func enterNextLevel(of item: BindingItem, step: KeyStep) {
        guard let key = step.key else { return }
        Diag.debug(.run, "descending one level for \(item.title)")
        state.prefix = PrefixResolver.probe(after: state.prefix, modifiers: step.modifiers, key: key)
        state.panel.selectionIndex = -1
        state.panel.pageIndex = 0
        rebuildPanel()
        onCapturedKeysChanged()
    }

    /// The keyboard path's "Backspace" after the ticked modifiers are accounted for.
    func goUpOneLevel() {
        // A tick is undone before a level is popped: the tick is what the user did most
        // recently, and ⌫ on an empty prefix would otherwise close the panel outright.
        if undoLastTick() { return }
        guard !state.prefix.isEmpty else {
            dismissPanel()
            return
        }
        let next = state.prefix.droppingLastStep()
        if next.isEmpty {
            dismissPanel()
            return
        }
        state.prefix = next
        rebuildPanel()
    }

    func complete(_ item: BindingItem, probe: KeyChord) {
        usageStore.record(usageKey: item.usageKey)
        ensurePage(containing: item.id)
        state.panel.completedRowID = item.id
        rebuildPanel()

        state.completionTask?.cancel()
        state.completionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled, let self else { return }
            self.state.panel.completedRowID = nil
            self.dismissPanel()
        }
    }

    /// - Returns: whether the pasteboard actually accepted the text.
    @discardableResult
    private func copyToPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        if !ok {
            // The pasteboard can refuse (another process holding it, a locked clipboard
            // manager). Log the length and nothing else: clipboard content is the user's.
            Diag.warning(.run, "pasteboard refused \(text.count) characters")
        }
        return ok
    }
}
