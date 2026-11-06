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
    /// The visible frame of the screen the panel will land on. A closure rather than
    /// `NSScreen.main`: the controller picks the screen by anchor window, then pointer, then
    /// main screen, and counting rows against a different screen is how a page overflowed.
    private let availableVisibleFrame: () -> CGRect?
    private let frontmostName: () -> String
    private let dismissPanel: () -> Void
    private let dismissEverything: () -> Void
    private let onCapturedKeysChanged: () -> Void
    private let onInputStateChanged: () -> Void
    /// Same disabled row, same explanation: at most once per `DisabledNoticeGate.interval`.
    private var disabledNoticeGate = DisabledNoticeGate()
    /// The reachability answer is expensive (one pure route per shortcut), and a panel
    /// rebuild happens on every arrow key. Keyed by everything the answer reads, so a
    /// catalog rescan, a filter change or a settings change recomputes and nothing else does.
    private var triggerAuditCache: (key: String, result: PanelTriggerAudit.Result)?

    init(
        state: EngineState,
        usageStore: UsageStore,
        localization: Localization,
        presenters: EnginePresenters,
        rowRunner: RowRunner,
        isPreviewing: @escaping () -> Bool,
        availableVisibleFrame: @escaping () -> CGRect?,
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
        self.availableVisibleFrame = availableVisibleFrame
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
        // The screen the controller will place the panel on, not `NSScreen.main`. On a
        // secondary display that is shorter or narrower, counting against the main screen
        // produced a page that did not fit: the last rows went under the footer or past the
        // edge, and `panelFrame` could only clamp the window, not the list inside it.
        guard let visible = availableVisibleFrame()?.size ?? NSScreen.main?.visibleFrame.size else {
            return configured
        }
        let columns: Int
        let panelHeight: CGFloat
        switch settings.panelPlacement {
        case .fillScreen:
            columns = max(1, min(4, Int((visible.width - OverlayMetrics.padding * 2) / OverlayMetrics.denseColumnStride)))
            panelHeight = visible.height
        case .fixedSize:
            columns = max(1, min(settings.columnCount, OverlayMetrics.columns(forWidth: CGFloat(settings.fixedPanelWidth))))
            panelHeight = min(CGFloat(settings.fixedPanelHeight), visible.height)
        case .coverWindow, .besideWindow:
            columns = max(1, settings.columnCount)
            panelHeight = min(OverlayMetrics.maxPanelHeight, visible.height)
        }
        // One card per source, not three: the app's, the system hotkeys', and one per config
        // tool that has rows (each tool is its own card, up to six). Reserving three cards
        // undercounted the chrome by up to five cards' insets and gaps, so the page was
        // taller than the window it was drawn in.
        let ledger = PanelSections.cardAndHeadingBudget(
            systemCount: state.systemBindings.count,
            toolCounts: configToolRowCounts,
            appHeading: settings.panelOrder == .byMenuGroup
        )
        return OverlayMetrics.fittedPageSize(
            maxItemsPerPage: configured,
            columns: columns,
            panelHeight: panelHeight,
            cardCount: ledger.cards,
            headingCount: ledger.headings
        )
    }

    /// How many rows each config tool has, folded or not.
    ///
    /// A folded tool still draws its card, so it still costs its frame. Small next to the
    /// catalog, and only read while a page is being rebuilt. Empty when the panel-level
    /// switch hides the tool section: no card, no heading, no page budget.
    private var configToolRowCounts: [Int] {
        guard state.settings.showConfigToolsInPanel else { return [] }
        let counts = toolRowCounts(in: state.configBindings)
        return ConfigTool.allCases.map { counts[$0] ?? 0 }
    }

    private func toolRowCounts(in bindings: [BindingItem]) -> [ConfigTool: Int] {
        var counts: [ConfigTool: Int] = [:]
        for binding in bindings {
            if let tool = binding.configTool {
                counts[tool, default: 0] += 1
            }
        }
        return counts
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
            includeDisabled: state.settings.showDisabledItems,
            ignoredSignature: ignoredSignature,
            systemCount: state.systemBindings.count,
            // The distribution, not just the total: a config rewrite that keeps the count
            // but moves rows between tools changes the card count and the page capacity.
            configCounts: configToolRowCounts,
            expandedTools: state.panel.expandedTools,
            narrowing: state.panel.isNarrowing,
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
        // The tool rows are part of the widest list whenever the section is open; folded,
        // they cost their cards' headings only.
        let toolBindings = state.favoritesPolicy.favoritesOnly(
            PanelSections.configToolRows(
                state.configBindings,
                showing: state.settings.showConfigToolsInPanel
            ),
            isFavorite: { usageStore.isFavorite($0.usageKey) }
        )
        let toolCounts = toolRowCounts(in: toolBindings)
        // The widest list this state can draw: while a filter stands, every tool card is open,
        // so the rows behind all of them have to fit inside the frame.
        let toolRows = ToolSectionFold.visibleRowCount(
            toolCounts: toolCounts,
            expanded: state.panel.expandedTools,
            narrowing: state.panel.isNarrowing
        )
        let total = hits.count + toolRows
        let pageSize = key.pageSize
        // Every section flows through the same pages. A short list reserves only its own
        // rows; the other sections' cards still get their frame and heading. One card per
        // non-empty tool, not one card for the whole tool block.
        let headings = PanelSections.cardAndHeadingBudget(
            systemCount: state.systemBindings.count,
            toolCounts: Array(toolCounts.values),
            appHeading: state.settings.panelOrder == .byMenuGroup
        ).headings
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
    /// The app's card is the one the title bar names, so the same name heads it — with the
    /// count the title bar has no room for. Empty until a scan names the front app.
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
        // `allEntries` is the filtered list of all three sources; `sequence` is what the
        // panel walks, with each folded tool card's rows removed (a filter in force opens
        // every card, for the duration only). Counts come from the former, so a folded card
        // still says how many rows it holds.
        let allEntries = filteredEntries(allPanelEntries())
        let sequence = visibleEntries(allEntries)
        let page = panelPage(of: sequence, pageSize: panelPageSize)
        let systemTitle = localization.text(.groupSystemHotkeys)
        let sectionTitle = panelSectionTitle
        let audit = triggerAudit()
        let specs = rowSpecs(
            for: page.entries,
            highlighted: highlightedIDs(for: page.entries.map(\.hit)),
            systemTitle: systemTitle,
            appTitle: sectionTitle,
            hintLabels: hintLabels(for: page.entries),
            unreachable: audit
        )
        if isPreviewing() {
            let counts = PanelSections.counts(in: allEntries)
            let toolRows = ConfigTool.allCases.reduce(0) { $0 + (counts[.tool($1)] ?? 0) }
            Diag.info(.ui, "panel sequence: app=\(counts[.app] ?? 0) system=\(counts[.system] ?? 0) tool=\(toolRows) page=\(page.index + 1)/\(page.count) rows=\(specs.count)")
        }
        applyPanelUpdate(
            allEntries: allEntries,
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

    /// Row id → Shift-hint glyph for the rows on the current page.
    ///
    /// Numbering is per page, not over the whole sequence: page 2 restarts at `0`, and the
    /// key handler refuses a glyph whose number has no row on this page. A table anchored to
    /// the whole sequence would draw one glyph per visible row while letting a glyph from
    /// another page run a row that was not even on screen.
    private func hintLabels(for page: [PanelEntry]) -> [String: String] {
        guard state.panel.shiftHintActive, state.prefix.isEmpty else { return [:] }
        return ShiftHintLayer.labels(for: page.map(\.hit.id))
    }

    /// Which shortcuts the panel lists cannot actually be triggered with the keys as they
    /// are routed right now. Off when the setting is off; cached for every other rebuild.
    ///
    /// The audit reads `state.chordItems` — the very list the key router consults — rather
    /// than assembling its own catalog. If those two ever drift apart again, the audit
    /// reports the rows the router cannot reach instead of quietly agreeing with a list the
    /// engine does not use.
    private func triggerAudit() -> PanelTriggerAudit.Result {
        guard state.settings.autoAuditUnreachableShortcuts else { return PanelTriggerAudit.Result() }
        let items = state.chordItems
        let hotkeys = [
            state.settings.panelHotkey, state.settings.searchHotkey, state.settings.switchHotkey,
            state.settings.runRowKey, state.settings.copyRowKey
        ].map { String(describing: $0) }.joined(separator: ",")
        let key = [
            String(items.count),
            String(state.catalog.scannedAt.timeIntervalSince1970),
            String(state.systemBindings.count),
            state.panel.filter.query,
            String(describing: state.phase),
            String(state.panel.shiftHintActive),
            String(state.panel.triggerNarrowPending),
            String(state.panel.latchedModifiers.rawValue),
            state.prefix.cacheKey,
            hotkeys
        ].joined(separator: "|")
        if let cached = triggerAuditCache, cached.key == key { return cached.result }

        let result = PanelTriggerAudit.audit(
            items: items,
            context: PanelTriggerAudit.Context(
                phase: state.phase,
                settings: state.settings,
                panel: state.panel,
                prefix: state.prefix,
                pending: state.pending,
                triggerPending: state.panel.triggerNarrowPending,
                routingItems: state.chordItems
            )
        )
        triggerAuditCache = (key, result)
        return result
    }

    /// One row per entry, described for the builder.
    private func rowSpecs(
        for entries: [PanelEntry],
        highlighted: Set<String>,
        systemTitle: String,
        appTitle: String,
        hintLabels: [String: String],
        unreachable: PanelTriggerAudit.Result
    ) -> [PanelRowBuilder.Spec] {
        entries.map { entry in
            let hit = entry.hit
            // A system hotkey macOS refuses to name used to arrive as a row whose command
            // column was an em dash, and the same dash also said "no keyboard shortcut" a few
            // rows down. The only true thing about that row is its chord, so the chord becomes
            // the name and the key column stays empty.
            let unnamedSystemHotkey = entry.section == .system && hit.item.title == DescriptionCleaner.placeholder
            let renderedChord = KeyFormatter.render(hit.item.chord, style: state.settings.keyStyle)
            return PanelRowBuilder.Spec(
                id: hit.id,
                keySegments: unnamedSystemHotkey ? [] : keySegments(for: hit),
                title: unnamedSystemHotkey
                    ? renderedChord
                    : DescriptionCleaner.truncate(hit.item.title, maxLength: state.settings.maxDescriptionLength),
                note: rowNote(for: entry),
                groupTitle: rowGroupTitle(for: entry, systemTitle: systemTitle, appTitle: appTitle),
                // The chevron and the click share one answer: a row without a chevron is a
                // shortcut the user can run (`KeyChord.isFinalStroke`).
                isGroup: !hit.item.chord.isFinalStroke(after: state.prefix),
                isEnabled: hit.item.isEnabled,
                hasConflict: state.conflictIDs.contains(hit.item.id),
                isHighlighted: highlighted.contains(hit.item.id),
                isCompleted: state.panel.completedRowID == hit.item.id,
                isFavorite: usageStore.isFavorite(hit.item.usageKey),
                hintLabel: hintLabels[hit.id],
                source: hit.item.source,
                // Both the system section and the Apple-menu section carry the same chord
                // for Sleep/Restart/…; the policy is evaluated on every row so both are red.
                restriction: RestrictedActionPolicy.restriction(for: hit.item).action,
                hasChord: !hit.item.chord.isEmpty,
                unreachableReason: unreachable.reason(forRowID: hit.id)
            )
        }
    }

    /// The row's annotation column, by source.
    ///
    /// The system card's header already names the section, so repeating it in every row's
    /// note column would be the same word 79 times. A tool row says which tool owns it —
    /// that is the answer "why does ⌘K open Alfred and not the app".
    private func rowNote(for entry: PanelEntry) -> String {
        switch entry.section {
        case .app:
            return menuPath(of: entry.hit.item)
        case .system:
            return ""
        case let .tool(tool):
            return tool.displayName
        }
    }

    /// Which card a row belongs to, by source.
    ///
    /// The app's heading exists for the menu-bar order, where a card title tells the user
    /// which menu a block came from. Chord order is one flat list, so it draws no heading;
    /// the system's hotkeys keep theirs either way, and each tool always names itself.
    private func rowGroupTitle(for entry: PanelEntry, systemTitle: String, appTitle: String) -> String {
        switch entry.section {
        case .app:
            return state.settings.panelOrder == .byMenuGroup ? appTitle : ""
        case .system:
            return systemTitle
        case let .tool(tool):
            return tool.displayName
        }
    }

    /// Builds the rows and writes the whole panel state back in one pass.
    private func applyPanelUpdate(
        allEntries: [PanelEntry],
        specs: [PanelRowBuilder.Spec],
        page: PanelPage,
        systemTitle: String,
        sectionTitle: String
    ) {
        let built = PanelRowBuilder.build(specs)
        let budget = unnarrowedBudget()
        // Every section spans pages, so its heading prints the section's size rather than the
        // slice on screen — "15" was the count of the page, not of the section. The counts
        // come from `allEntries`, so a folded tool card still knows how many rows it holds.
        let counts = PanelSections.counts(in: allEntries)
        let appTotal = counts[.app] ?? 0
        let systemTotal = counts[.system] ?? 0
        var toolTotals: [(tool: ConfigTool, count: Int)] = []
        for tool in ConfigTool.allCases {
            toolTotals.append((tool, counts[.tool(tool)] ?? 0))
        }
        // Group titles identify sections: the app's card is headed by the app's name (or by
        // nothing in chord order), the system's by its localisation, a tool's by its own name.
        var totals: [String: Int] = [:]
        // Assigned one by one, not as a literal: the app's title is empty until a scan names
        // the front app, so "" and `sectionTitle` are often the same key.
        totals[""] = appTotal
        totals[sectionTitle] = appTotal
        totals[systemTitle] = systemTotal
        for pair in toolTotals {
            totals[pair.tool.displayName] = pair.count
        }
        var groups = built.groups.map { group -> PanelGroup in
            let tool = ConfigTool.allCases.first { $0.displayName == group.title }
            return PanelGroup(
                id: group.id,
                title: group.title,
                rows: group.rows,
                // A title that is in neither map is one of the app's menu-group headings
                // (by-menu order), and those print the app's total, as they always have.
                totalCount: totals[group.title] ?? appTotal,
                isCollapsible: tool != nil,
                isExpanded: tool.map {
                    ToolSectionFold.isExpanded(
                        tool: $0,
                        expanded: state.panel.expandedTools,
                        narrowing: state.panel.isNarrowing
                    )
                } ?? true,
                tool: tool
            )
        }
        // A folded tool still draws its card: a title, its count, and no rows. The builder
        // only makes groups out of rows, so the empty ones are added here, after the sequence,
        // in the same fixed order the rows would have had (App → system → each tool). An open
        // tool adds nothing: its card is made by its rows, on whichever page they sit.
        let presentTitles = Set(groups.map(\.title))
        for pair in toolTotals where pair.count > 0 && !presentTitles.contains(pair.tool.displayName) {
            guard !ToolSectionFold.isExpanded(
                tool: pair.tool,
                expanded: state.panel.expandedTools,
                narrowing: state.panel.isNarrowing
            ) else { continue }
            groups.append(
                PanelGroup(
                    id: pair.tool.displayName,
                    title: pair.tool.displayName,
                    rows: [],
                    totalCount: pair.count,
                    isCollapsible: true,
                    isExpanded: false,
                    tool: pair.tool
                )
            )
        }
        state.panel.groups = groups
        state.panel.flatRowIDs = built.flatRowIDs
        state.panel.rowBudget = budget.rows
        state.panel.headingBudget = budget.headings
        state.panelSelectionIndex = PanelSelection.resolved(
            previous: state.panelSelectionIndex,
            rowCount: built.flatRowIDs.count
        )
        state.panel.prefixLabels = KeyFormatter.breadcrumb(for: state.prefix, style: state.settings.keyStyle)
        state.panel.pageIndex = page.index
        state.panel.pageCount = page.count
        // Three sources, one total: a folded tool block still counts its rows here, because
        // the number in the title bar answers "how much is in this panel", not "how much is
        // on this page".
        state.panel.totalCount = allEntries.count
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

    /// The panel's rows as one sequence: the app's section, the system's, then each tool's.
    ///
    /// `orderedHits()` stays app-only — it is what the prefix, the held modifiers and the
    /// order cache reason about. The other two sources are appended here, once, so pagination
    /// and "jump to the page of this row" walk exactly the sequence the panel draws.
    /// Internal for `PreviewScenarios`, which needs the page a heading lands on.
    func panelSequence() -> [PanelEntry] {
        visibleEntries(filteredEntries(allPanelEntries()))
    }

    /// Every row the session owns, in the panel's fixed source order.
    ///
    /// The tool blocks are ordered by `ConfigTool.allCases`, not by the order the scan
    /// happened to return: the cards then stay in the same place across rescans, which also
    /// makes the order assertable in a test.
    private func allPanelEntries() -> [PanelEntry] {
        let appHits = orderedHits()
        let systemHits: [PrefixHit]
        if state.prefix == .empty, !state.systemBindings.isEmpty {
            systemHits = ranked(state.systemBindings)
        } else {
            systemHits = []
        }
        // Tool rows are single chords like the system's, so they follow the same rule: they
        // appear only on an empty prefix, ranked the same way, one block per tool.
        var toolBlocks: [(ConfigTool, [PrefixHit])] = []
        if state.prefix == .empty,
           state.settings.showConfigToolsInPanel,
           !state.configBindings.isEmpty {
            for tool in ConfigTool.allCases {
                let items = state.configBindings.filter { $0.configTool == tool }
                if !items.isEmpty {
                    toolBlocks.append((tool, ranked(items)))
                }
            }
        }
        return PanelSections.combine(app: appHits, system: systemHits, tool: toolBlocks)
    }

    /// Rows ranked by the same rules the app's list uses: favorites policy, then the chord
    /// order, with favorites pinned when the setting asks for it.
    ///
    /// The system and tool sources used to spell this out separately; one helper keeps all
    /// three sources from drifting into three slightly different orders.
    private func ranked(_ items: [BindingItem]) -> [PrefixHit] {
        let favorite = state.favoritesPolicy.favoritesOnly(items) { usageStore.isFavorite($0.usageKey) }
        var sorted = PanelOrdering.sorted(favorite, emphasizing: state.pending.effective)
        sorted = state.favoritesPolicy.pinningFavoritesFirst(sorted) { usageStore.isFavorite($0.usageKey) }
        return PanelSections.hits(for: sorted)
    }

    /// The rows the panel walks: every source, with a folded tool card's rows left out.
    ///
    /// Folded, the tools still draw a card (title and count, no rows), so they stay in the
    /// counts but not in the pages. A filter in force opens every card for as long as it
    /// stands — a match behind a closed card would be listed in its count and unreachable —
    /// and the user's own fold choices are left untouched underneath.
    private func visibleEntries(_ entries: [PanelEntry]) -> [PanelEntry] {
        let narrowing = !state.panel.filter.isEmpty
        state.panel.isNarrowing = narrowing
        return PanelSections.visible(
            entries,
            expandedTools: state.panel.expandedTools,
            narrowing: narrowing
        )
    }

    /// The filter is a query over the combined sequence, after the source split and after
    /// every other rule: it only decides which rows survive, never their order.
    private func filteredEntries(_ entries: [PanelEntry]) -> [PanelEntry] {
        // Build the corpus only when there is a query: an empty filter matches everything,
        // and typing is the only thing that needs the index.
        guard !state.panel.filter.isEmpty else { return entries }
        guard let ids = PanelFilterPlan.matchingIDs(filter: state.panel.filter, corpus: filterCorpus()) else {
            return entries
        }
        return entries.filter { ids.contains($0.id) }
    }

    /// The corpus the filter query runs against: all of the panel's sources, with the tool
    /// rows only when the panel-level switch shows them.
    ///
    /// The palette's cached corpus is deliberately not reused: it is built from the palette's
    /// scope (one app, plus the system hotkeys) and never contains tool rows, so filtering
    /// through it would silently hide the whole config-tool section.
    ///
    /// Built once per catalog, not once per keystroke. The key covers every input the corpus
    /// is made of: a scan (the menu trees), a config read (the tool rows), the system rows,
    /// the key style that renders the chords, the language the titles are in, and whether the
    /// tool rows are shown at all. `configScan` is in the key because a rewrite that keeps
    /// the row count still changes the documents.
    private func filterCorpus() -> SearchCorpus {
        let showingTools = state.settings.showConfigToolsInPanel
        let key = [
            String(state.catalog.scannedAt.timeIntervalSince1970),
            String(state.configScanGeneration),
            String(state.configScan.scannedAt.timeIntervalSince1970),
            String(state.systemBindings.count),
            String(showingTools),
            state.settings.keyStyle.rawValue,
            localization.language.rawValue
        ].joined(separator: "|")
        if let cached = state.panelFilterCorpus, state.panelFilterCorpusKey == key {
            return cached
        }
        let corpus = SearchCorpus(
            items: state.catalog.items + state.systemBindings
                + PanelSections.configToolRows(state.configBindings, showing: showingTools),
            style: state.settings.keyStyle
        )
        state.panelFilterCorpus = corpus
        state.panelFilterCorpusKey = key
        return corpus
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

    /// Opens or folds one tool's card.
    ///
    /// Per tool, not per section: each card is its own choice, and the state stores the set
    /// of open tools. The rows leave the sequence and come back, so both caches are dropped:
    /// the budget was sized for the previous fold, and the order cache must not outlive the
    /// session's rule change. The page is clamped by the next rebuild.
    func toggleToolSection(_ tool: ConfigTool) {
        if state.panel.expandedTools.contains(tool) {
            state.panel.expandedTools.remove(tool)
        } else {
            state.panel.expandedTools.insert(tool)
        }
        state.orderedHitsCache = nil
        state.rowBudgetCache = nil
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
        guard let item = item(forRowID: rowID) else { return }
        usageStore.toggleFavorite(item.usageKey)
        // A pin changes the order but not the press counter, so the cache has to be dropped.
        state.orderedHitsCache = nil
        rebuildPanel()
    }

    /// Rows can come from the frontmost app's catalog, the system hotkey list, or a config
    /// tool's file. One resolver keeps clicks and keys honest.
    private func item(forRowID rowID: String) -> BindingItem? {
        state.catalog.items.first(where: { $0.id == rowID })
            ?? state.systemBindings.first(where: { $0.id == rowID })
            ?? state.configBindings.first(where: { $0.id == rowID })
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

    /// Copies the menu path only.
    ///
    /// A restricted row's context menu and a chord-less row use this: the shortcut is the
    /// thing that cannot be offered, but the place the command lives still can.
    func copyMenuPath(rowID: String) {
        guard let item = item(forRowID: rowID) else {
            Diag.error(.run, "row \(rowID) is in no panel source")
            return
        }
        let path = menuPath(of: item)
        guard !path.isEmpty else {
            presenters.notices.show(
                chord: "!",
                title: localization.text(.panelNothingToCopy),
                kind: .failure
            )
            return
        }
        guard copyToPasteboard(path) else {
            presenters.notices.show(
                chord: "!",
                title: localization.text(.panelCopyFailed),
                kind: .failure
            )
            return
        }
        presenters.notices.show(chord: path, title: localization.text(.panelCopied))
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
        state.panelSelectionIndex = -1
        rebuildPanel()
    }

    func previousPage() {
        let target = PaginationPlan.previousPage(from: state.panel.pageIndex, pageCount: state.panel.pageCount)
        guard PaginationPlan.moved(from: state.panel.pageIndex, to: target, pageCount: state.panel.pageCount) else {
            return
        }
        state.panel.pageIndex = target
        state.panelSelectionIndex = -1
        rebuildPanel()
    }

    // MARK: - Panel execution

    func moveSelection(_ delta: Int) {
        guard state.panel.isVisible, !state.panel.flatRowIDs.isEmpty else { return }
        let last = state.panel.flatRowIDs.count - 1
        state.panelSelectionIndex = min(max(-1, state.panelSelectionIndex + delta), last)
    }

    /// The run key / copy key pressed on the selected panel row.
    func performSelectedPanelRow(action: RowAction) {
        guard state.panelSelectionIndex >= 0, state.panel.flatRowIDs.indices.contains(state.panelSelectionIndex) else {
            // The run key on a panel with nothing selected used to be indistinguishable from
            // a broken key: no execution, no copy, no log. Say why.
            let index = state.panelSelectionIndex
            let rows = state.panel.flatRowIDs.count
            let name = action.rawValue
            Diag.info(.run, "\(name) key ignored: no row selected (index=\(index), rows=\(rows))")
            return
        }
        performPanelRow(rowID: state.panel.flatRowIDs[state.panelSelectionIndex], action: action)
    }

    /// A click and the run key share one contract, but they ask different questions:
    ///
    /// - the run key asks to execute;
    /// - a click on a restricted or config row copies instead of running (see
    ///   `PanelRowActionPlan`), which is why it gets its own entry point.
    func performPanelRow(rowID: String, action: RowAction) {
        switch action {
        case .execute: performPanelRow(rowID: rowID, request: .execute)
        case .copy: performPanelRow(rowID: rowID, request: .copyShortcut)
        }
    }

    /// Cursor click in the panel. Restricted and config-tool rows answer by copying their
    /// shortcut (or their menu path when there is no chord) rather than doing nothing.
    func clickPanelRow(rowID: String) {
        performPanelRow(rowID: rowID, request: .click)
    }

    /// The one place panel activation turns into an outcome. The configuration row never
    /// reaches `RowRunner`, and a restricted action never reaches it either.
    private func performPanelRow(rowID: String, request: PanelRowRequest) {
        guard let item = item(forRowID: rowID) else {
            // No namespace knows this id. Reachable only if a row and the catalog disagree,
            // which used to present itself as "clicking does nothing".
            Diag.error(.run, "row \(rowID) is in no panel source")
            return
        }
        let outcome = PanelRowActionPlan.outcome(
            request: request,
            restriction: RestrictedActionPolicy.restriction(for: item),
            source: item.source,
            hasChord: !item.chord.isEmpty
        )
        switch outcome {
        case .run:
            run(item: item, rowID: rowID)
        case .copyShortcut:
            copyShortcut(rowID: rowID)
        case .copyMenuItem:
            copyMenuPath(rowID: rowID)
        case .noticeUnsupportedSource:
            showNotice(.panelUnsupportedSource)
        case .noticeRestricted:
            // The click, the run key and the palette's Return are one path now: copy what
            // the row has and say why it did not run. Nothing closes, because nothing ran.
            rowRunner.refuseRestricted(item)
        case .noticeNothingToCopy:
            showNotice(.panelNothingToCopy)
        }
    }

    private func showNotice(_ key: L10nKey) {
        presenters.notices.show(
            chord: "!",
            title: localization.text(key),
            kind: .info
        )
    }

    /// Cursor moved over a row: make it the selected row so Return acts on it.
    func select(rowID: String) {
        guard state.panel.isVisible, let index = state.panel.flatRowIDs.firstIndex(of: rowID) else { return }
        guard state.panelSelectionIndex != index else { return }
        state.panelSelectionIndex = index
    }

    /// Runs the row the user picked, in whichever namespace owns it.
    ///
    /// A row belongs to exactly one namespace, so this is a router into the effects below
    /// rather than a function that does the work. Catalog row, system hotkey, unknown id.
    ///
    /// The guard is the same table the click and copy paths use: a config row says "shown
    /// only", a restricted action says "not available to run". Neither reaches `RowRunner`.
    func activate(rowID: String) {
        performPanelRow(rowID: rowID, request: .execute)
    }

    private func run(item: BindingItem, rowID: String) {
        switch item.source {
        case .system:
            rowRunner.runSystemHotkey(item)
        case .configFile:
            // Unreachable through the plan; the double guard inside `RowRunner` covers any
            // future caller that finds this row another way.
            showNotice(.panelUnsupportedSource)
        default:
            activateCatalogItem(item, rowID: rowID)
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
            Diag.info(.run, "ignoring disabled row=\(rowID) titleLen=\(item.title.count)")
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
        Diag.debug(.run, "descending one level depth=\(item.group.count) titleLen=\(item.title.count)")
        state.prefix = PrefixResolver.probe(after: state.prefix, modifiers: step.modifiers, key: key)
        state.panelSelectionIndex = -1
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
