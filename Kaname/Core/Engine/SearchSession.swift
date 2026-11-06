import AppKit

/// The search palette: its own session state, its own scope, its own ranking.
///
/// The palette and the panel share the panel window, but they are separate sessions. This
/// class owns the palette's half — opening and closing, scope selection, selection movement,
/// and the ranking corpus. Everything it needs from the rest of the engine arrives as a
/// closure or through the modules it holds.
@MainActor
final class SearchSession {
    private let state: EngineState
    private let usageStore: UsageStore
    private let localization: Localization
    private let rowRunner: RowRunner
    private let catalogCoordinator: CatalogCoordinator
    private let presenters: EnginePresenters
    private let isStarted: () -> Bool
    private let isPreviewing: () -> Bool
    private let dismissPanel: () -> Void
    private let activatePanel: () -> Void
    private let externalBindings: () -> [BindingItem]

    init(
        state: EngineState,
        usageStore: UsageStore,
        localization: Localization,
        rowRunner: RowRunner,
        catalogCoordinator: CatalogCoordinator,
        presenters: EnginePresenters,
        isStarted: @escaping () -> Bool,
        isPreviewing: @escaping () -> Bool,
        dismissPanel: @escaping () -> Void,
        activatePanel: @escaping () -> Void,
        externalBindings: @escaping () -> [BindingItem]
    ) {
        self.state = state
        self.usageStore = usageStore
        self.localization = localization
        self.rowRunner = rowRunner
        self.catalogCoordinator = catalogCoordinator
        self.presenters = presenters
        self.isStarted = isStarted
        self.isPreviewing = isPreviewing
        self.dismissPanel = dismissPanel
        self.activatePanel = activatePanel
        self.externalBindings = externalBindings
    }

    func showSearch() {
        openSearch()
    }

    /// `/` in the panel: opens the palette as a fresh search.
    ///
    /// The panel and the palette are two views of one window, and `/` is the door between
    /// them. What it is not is a resume: each opening starts from an empty field, the first
    /// row and the top of the list, so a query typed ten minutes ago cannot masquerade as
    /// part of today's search. The same reset covers the scope and the Shift hint layer.
    func showSearchFromPanel() {
        guard state.panel.isVisible, !state.search.isVisible else { return }
        openSearch()
    }

    /// `/` in the palette while its field is not focused: back to the panel.
    ///
    /// The field keeps focus in practice, and while it has it `/` is just a character — a
    /// search field that refuses to accept a slash is a worse bug than a missing shortcut.
    /// This is the other half of the toggle, for when focus is elsewhere in the window.
    func returnToPanelFromSearch() {
        guard state.search.isVisible else { return }
        Diag.info(.ui, "search: `/` returns to the shortcut panel")
        state.search.isVisible = false
        presenters.panel.closeSearch()
        activatePanel()
    }

    private func openSearch() {
        dismissPanel()
        // Reset the scope while the engine still knows which one it was: the snapshot waits
        // for the engine to clear its cached catalog, icon and process first.
        selectSearchScope(nil)
        state.search.beginNewSession()
        state.searchFocusToken += 1
        refreshSearch()
        state.search.isVisible = true
        presenters.panel.presentSearch()
    }

    func hideSearch() {
        state.search.isVisible = false
        presenters.panel.closeSearch()
    }

    func toggleSearch() {
        if state.search.isVisible {
            hideSearch()
        } else {
            showSearch()
        }
    }

    /// - Parameter scrollIntoView: false for the pointer. Hovering moves the selection so
    ///   Return acts on the row under the cursor, but the list must stay where it is: a
    ///   scroll per hover event made the scrollbar move with the mouse.
    func selectSearchResult(_ index: Int, scrollIntoView: Bool = true) {
        guard state.search.results.indices.contains(index) else { return }
        state.search.selection = index
        if scrollIntoView { state.search.scrollRequest &+= 1 }
    }

    func moveSearchSelection(_ delta: Int) {
        guard !state.search.results.isEmpty else { return }
        let next = state.search.selection + delta
        state.search.selection = min(max(0, next), state.search.results.count - 1)
        state.search.scrollRequest &+= 1
    }

    /// Click in the search palette: close it, return to the previous app and replay the
    /// shortcut there.
    func activateSearchResult(_ index: Int) {
        guard state.search.results.indices.contains(index) else { return }
        let item = state.search.results[index]
        guard RowEligibility.canActivate(isEnabled: item.isEnabled) else { return }
        guard canRunFromSearch(item) else { return }
        // With a scope, the app to run in is the one being searched — it is usually *not* in
        // front, because the palette took the keyboard from whatever was.
        let scoped = state.searchScopeProcessID.flatMap { NSRunningApplication(processIdentifier: $0) }
        let target = scoped ?? presenters.panel.searchTargetApplication ?? NSWorkspace.shared.frontmostApplication
        hideSearch()
        if let scoped, !scoped.isActive {
            // Bring it forward first, then trigger: a menu press into a background app and a
            // chord replayed to the wrong window are both ways to do nothing visible.
            scoped.activate()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self?.triggerSearchItem(item, target: scoped)
            }
            return
        }
        Task { @MainActor [weak self] in
            await self?.triggerSearchItem(item, target: target)
        }
    }

    /// The trigger itself, split out so the scoped path can activate first and still share it.
    private func triggerSearchItem(_ item: BindingItem, target: NSRunningApplication?) async {
        guard RowEligibility.canActivate(isEnabled: item.isEnabled) else { return }
        guard canRunFromSearch(item) else { return }
        // Pressing the menu item is the primary trigger; `RowRunner` keeps the search path's
        // differences (no HUD, record after success) inside the same implementation.
        let element = await rowRunner.resolveElement(forRowID: item.id)
        await rowRunner.run(
            item,
            rowID: item.id,
            element: element,
            origin: .search,
            searchTarget: target
        )
    }

    /// The palette has no copy action, so a refused row is told why and the palette stays
    /// open: closing it would look like the shortcut ran.
    private func canRunFromSearch(_ item: BindingItem) -> Bool {
        let outcome = PanelRowActionPlan.outcome(
            request: .execute,
            restriction: RestrictedActionPolicy.restriction(for: item),
            source: item.source,
            hasChord: !item.chord.isEmpty
        )
        switch outcome {
        case .run:
            return true
        case .noticeRestricted:
            // Same notice and same copy as the panel's click and run key; the palette stays
            // open because closing it would look like the shortcut ran.
            rowRunner.refuseRestricted(item)
            return false
        case .noticeUnsupportedSource:
            presenters.notices.showNotice(
                text: localization.text(.panelUnsupportedSource),
                kind: .info
            )
            return false
        case .copyShortcut, .copyMenuItem, .noticeNothingToCopy:
            // `.execute` never yields these; keeping the switch exhaustive documents that.
            return false
        }
    }

    /// Return in the search palette behaves exactly like a click: close it, return to
    /// the front app and replay the shortcut there.
    func confirmSearchSelection() {
        guard state.search.results.indices.contains(state.search.selection) else { return }
        activateSearchResult(state.search.selection)
    }

    /// Rows the palette searches: the scoped app's commands, or the frontmost app's plus the
    /// system's own hotkeys and the config-tool rows.
    ///
    /// Config rows have no bundle id, so they belong to the unscoped ("all") view only; the
    /// app-scoped corpus stays that app's menus. They follow the panel-level display switch:
    /// with the tool section hidden, the palette must not answer with rows the panel refuses
    /// to draw.
    private var searchItems: [BindingItem] {
        state.search.scopeAppID == nil
            ? state.catalog.items + state.systemBindings
                + PanelSections.configToolRows(
                    state.configBindings,
                    showing: state.settings.showConfigToolsInPanel
                )
            : state.search.scopeItems
    }

    /// Points the palette at another app, or back at the frontmost one with nil.
    func selectSearchScope(_ appID: String?) {
        guard appID != state.search.scopeAppID else { return }
        let app = appID.flatMap { id in state.runningApps.first(where: { $0.id == id }) }
        state.search = SearchScopePlan.switched(
            state.search,
            appID: appID,
            name: app?.name ?? "",
            isRunning: app != nil
        )
        state.searchScopeIcon = nil
        state.searchScopeProcessID = nil
        state.searchScopeCatalog = .empty
        state.searchCorpus = nil
        guard let appID, let app else {
            refreshSearch()
            return
        }
        state.searchScopeIcon = app.icon
        state.searchScopeProcessID = app.pid
        refreshSearch()
        // Cache first: switching scope should feel like flipping a page, not like a scan.
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.catalogCoordinator.loadScopedCatalog(
                for: FrontmostApp(pid: app.pid, bundleID: app.bundleID, name: app.name, icon: app.icon)
            )
            guard self.state.search.scopeAppID == appID else { return }
            self.state.search.scopeItems = snapshot.items
            self.state.searchScopeCatalog = snapshot
            self.state.searchCorpus = nil
            self.state.search.loadState = SearchScopePlan.loadState(for: snapshot.state)
            self.state.search.usedBuiltInCatalog = snapshot.usedBuiltInCatalog
            self.refreshSearch()
        }
    }

    /// Markdown for what the palette is showing: the matches when there is a query, the
    /// scope's whole list when there is not.
    func makeSearchMarkdown() -> String {
        let title = state.search.scopeName.isEmpty ? state.appName : state.search.scopeName
        let items = state.search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? searchItems
            : state.search.results
        return MarkdownExporter.render(
            appName: title,
            items: items,
            style: state.settings.keyStyle,
            language: localization.language
        )
    }

    /// Internal for `PreviewScenarios`, which drives the palette without a text field.
    func refreshSearch() {
        guard isStarted() else { return }
        // `searchItems` concatenates up to two sources. Reading it once per refresh means the
        // corpus key, the corpus and the combo answer all describe the same list, and a
        // keystroke no longer rebuilds that list four times.
        let items = searchItems
        // The corpus is built from the *scoped* items, not from the frontmost catalog: the
        // palette existed to search one app, and a corpus built from somebody else's menus
        // answers every keystroke with the wrong app's list. The key makes the scope part of
        // the cache identity, so a scope switch (or its catalog arriving a moment later)
        // cannot be answered from the previous app's documents.
        let corpusKey = [
            state.search.scopeAppID ?? "-",
            String(state.catalog.scannedAt.timeIntervalSince1970),
            String(state.searchScopeCatalog.scannedAt.timeIntervalSince1970),
            String(items.count),
            // Counts alone miss a rescan that rewrites the same number of rows. The scan
            // timestamp changes with every config read, so a same-count edit cannot be
            // answered from the previous corpus.
            String(state.configBindings.count),
            String(state.configScan.scannedAt.timeIntervalSince1970),
            String(state.settings.showConfigToolsInPanel),
            state.settings.keyStyle.rawValue,
            localization.language.rawValue
        ].joined(separator: "|")
        if state.searchCorpus == nil || state.searchCorpusKey != corpusKey {
            state.searchCorpus = SearchCorpus(items: items, style: state.settings.keyStyle)
            state.searchCorpusKey = corpusKey
        }
        // A query that spells out a combo gets a direct answer about who owns it, even when
        // the answer is "one thing, so no conflict" — which is exactly the case the conflict
        // list stays silent about.
        // The unscoped list already contains the system rows and — when the display switch
        // shows them — the tool rows; appending the external sources again would name one
        // owner twice. A scoped list is that app's menus only, so there the external sources
        // are still what completes the answer. When the switch hides the tool rows, they are
        // put back here on purpose: the answer is "who else owns this chord", and hiding a
        // card does not make a conflicting tool stop owning it.
        let hiddenToolRows = state.search.scopeAppID == nil
            ? PanelSections.configToolRows(
                state.configBindings,
                showing: !state.settings.showConfigToolsInPanel
            )
            : externalBindings()
        let comboItems = items + hiddenToolRows
        state.search.comboAnswer = ComboLookup.answer(forQuery: state.search.query, in: comboItems)
        // An empty field means "show this app's list", not "show the first 60 of it".
        let isEmptyQuery = state.search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let includeDisabled = state.settings.showDisabledItems
        var results = (state.searchCorpus?.search(state.search.query, limit: isEmptyQuery ? 400 : 60) ?? [])
            .filter {
                !state.isIgnored($0)
                    && (includeDisabled || RowEligibility.canActivate(isEnabled: $0.isEnabled))
            }
        if !state.favoritesPolicy.canBeFiltered, !isEmptyQuery {
            let existing = Set(results.map(\.id))
            let favorites = items.filter {
                usageStore.isFavorite($0.usageKey)
                    && !state.isIgnored($0)
                    && (includeDisabled || RowEligibility.canActivate(isEnabled: $0.isEnabled))
                    && !existing.contains($0.id)
            }
            results.append(contentsOf: favorites)
        }
        results = state.favoritesPolicy.pinningFavoritesFirst(results) { usageStore.isFavorite($0.usageKey) }
        state.search.results = results
        if state.search.scopeAppID == nil {
            if state.isCatalogLoading {
                state.search.loadState = .loading
            } else if state.scanState == .permissionDenied {
                state.search.loadState = .permissionDenied
            } else {
                state.search.loadState = .ready
            }
        }
        state.search.usedBuiltInCatalog = state.search.scopeAppID == nil
            ? state.usedBuiltInCatalog
            : state.searchScopeCatalog.usedBuiltInCatalog
        // The first match is always selected.
        state.search.selection = 0
        state.search.scrollRequest &+= 1
        if isPreviewing() {
            // A screenshot cannot show which app's list it is showing; this line can.
            Diag.info(.ui, """
                search: scope=\(state.search.scopeAppID ?? "frontmost") items=\(items.count) \
                results=\(results.count) first=\(Sanitizer.clamp(results.first?.title ?? "-"))
                """)
        }
    }
}
