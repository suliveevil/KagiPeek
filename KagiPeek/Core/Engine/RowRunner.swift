import AppKit

/// Runs one row: resolve its Accessibility element, press the menu item, replay the chord
/// when the press is refused, and report what happened.
///
/// Execution differs between the two surfaces by design, not by accident: the panel records
/// usage *before* pressing and dismisses itself first, while the palette records usage *after*
/// a successful press, keeps no HUD, and brings the searched app forward. `Origin` keeps those
/// differences visible in one place instead of duplicating the four failure branches.
@MainActor
final class RowRunner {
    enum Origin {
        case panel
        case search
    }

    private let state: EngineState
    private let catalogLoader: CatalogLoader
    private let usageStore: UsageStore
    private let localization: Localization
    private let presenters: EnginePresenters
    private let frontmostBundleID: () -> String?
    private let injectionTargetForFrontmost: () -> InjectionTarget?
    private let dismissPanel: () -> Void

    init(
        state: EngineState,
        catalogLoader: CatalogLoader,
        usageStore: UsageStore,
        localization: Localization,
        presenters: EnginePresenters,
        frontmostBundleID: @escaping () -> String?,
        injectionTargetForFrontmost: @escaping () -> InjectionTarget?,
        dismissPanel: @escaping () -> Void
    ) {
        self.state = state
        self.catalogLoader = catalogLoader
        self.usageStore = usageStore
        self.localization = localization
        self.presenters = presenters
        self.frontmostBundleID = frontmostBundleID
        self.injectionTargetForFrontmost = injectionTargetForFrontmost
        self.dismissPanel = dismissPanel
    }

    /// What a restored row needs to find its live element: the app it belongs to, the menu
    /// path and the title to verify. It is captured before leaving the main actor.
    private struct CachedRowRequest {
        let identity: String
        let pid: pid_t
        let axPath: String
        let title: String
        let isScoped: Bool
    }

    /// The Accessibility element behind a row, taken from the snapshot that owns the row.
    ///
    /// Ids carry the app's bundle id, so a row can only ever be found in one of the two
    /// scanned snapshots — the front app's — and looking in it is the honest way to say
    /// "whichever app this row belongs to". A snapshot restored from the disk cache carries
    /// no elements, so its rows are resolved on demand by re-walking the menu path. That walk
    /// happens on the catalog loader's element queue: a hung app must not freeze the panel
    /// while the row says it is running.
    func resolveElement(forRowID rowID: String) async -> AXUIElement? {
        if state.search.scopeAppID != nil, let element = state.searchScopeCatalog.elements[rowID] {
            return element
        }
        if let element = state.catalog.elements[rowID] { return element }
        guard let request = cachedRowRequest(forRowID: rowID),
              let resolved = await catalogLoader.resolveElement(
                  atAxPath: request.axPath,
                  pid: request.pid,
                  expectingTitle: request.title
              )
        else { return nil }
        // Memoise only on the snapshot the request came from: the panel may have switched
        // apps while the walk was in flight, and a stale element must not be filed under
        // the new snapshot's ids.
        if request.isScoped,
           state.search.scopeAppID != nil,
           state.searchScopeCatalog.appIdentity == request.identity,
           state.searchScopeCatalog.appPID == request.pid,
           state.searchScopeCatalog.elements.isEmpty {
            state.searchScopeCatalog.elements[rowID] = resolved.element
        } else if state.catalog.appIdentity == request.identity,
                  state.catalog.appPID == request.pid,
                  state.catalog.elements.isEmpty {
            state.catalog.elements[rowID] = resolved.element
        }
        return resolved.element
    }

    private func cachedRowRequest(forRowID rowID: String) -> CachedRowRequest? {
        if state.search.scopeAppID != nil,
           let request = cachedRowRequest(forRowID: rowID, in: state.searchScopeCatalog, isScoped: true) {
            return request
        }
        return cachedRowRequest(forRowID: rowID, in: state.catalog, isScoped: false)
    }

    private func cachedRowRequest(
        forRowID rowID: String,
        in snapshot: CatalogSnapshot,
        isScoped: Bool
    ) -> CachedRowRequest? {
        // A real scan already carries its elements; only a restored snapshot needs this.
        // Built-in fallback rows have no menu path either, and keep replaying their chord.
        guard snapshot.elements.isEmpty,
              let pid = snapshot.appPID,
              let item = snapshot.items.first(where: { $0.id == rowID }),
              let axPath = item.axPath
        else { return nil }
        return CachedRowRequest(
            identity: snapshot.appIdentity,
            pid: pid,
            axPath: axPath,
            title: item.title,
            isScoped: isScoped
        )
    }

    /// Triggering the command is the point, so the menu item itself is pressed first: it
    /// works for commands that have no shortcut at all, and for the ones that do it is
    /// exactly what clicking the menu would do. Replaying the chord is the fallback — for a
    /// stale element, or an app that refuses the press.
    ///
    /// `element` is the result of the asynchronous walk (nil when the row has no menu path
    /// or the menu changed under the cache). It never comes from the main thread, so this
    /// function only does the press and the fallback.
    func run(
        _ item: BindingItem,
        rowID: String,
        element: AXUIElement?,
        origin: Origin,
        searchTarget: NSRunningApplication? = nil
    ) async {
        let rendered = KeyFormatter.render(item.chord, style: state.settings.keyStyle)
        if let element, await MenuTrigger.press(ResolvedAXElement(element: element)) {
            switch origin {
            case .panel:
                Diag.action("panel.run", target: item.appBundleID ?? frontmostBundleID())
                Diag.debug(.run, "pressed menu item \(Sanitizer.clamp(item.title))")
                showExecutedNotice(
                    chord: item.chord.isEmpty ? KeyFormatter.noShortcutPlaceholder : rendered,
                    title: item.title
                )
            case .search:
                Diag.info(.run, "pressed menu item \(item.title) from search")
                Diag.action("search.run", target: item.appBundleID ?? frontmostBundleID())
                DispatchQueue.main.async { searchTarget?.activate() }
                usageStore.record(usageKey: item.usageKey)
            }
            return
        }
        guard !item.chord.isEmpty else {
            // No shortcut to replay either: the row is unreachable until the next scan.
            // Say so instead of closing the surface on a click that did nothing.
            Diag.error(.run, """
                menu press failed and \(Sanitizer.clamp(item.title)) has no shortcut \
                to replay
                """)
            switch origin {
            case .panel:
                Diag.error(.inject, """
                    ax-press failed and no chord to replay row=\(rowID) \
                    title=\(Sanitizer.clamp(item.title)) target=\(item.appBundleID ?? "?")
                    """)
            case .search:
                Diag.error(.inject, """
                    ax-press failed and no chord to replay (from search) \
                    title=\(Sanitizer.clamp(item.title)) target=\(item.appBundleID ?? "?")
                    """)
            }
            presenters.notices.showNotice(
                text: localization.text(.panelRunFailed),
                kind: .failure
            )
            return
        }
        switch origin {
        case .panel:
            Diag.debug(.run, """
                ax-press refused, replaying \(KeyFormatter.render(item.chord, style: .symbols)) \
                row=\(rowID) title=\(Sanitizer.clamp(item.title))
                """)
            Diag.action("panel.run.replay", target: item.appBundleID ?? frontmostBundleID())
            // The toast is the confirmation of a run, so it waits for the replay to actually
            // post: a chord withheld because the app never came back is a failure, not a run.
            let target = injectionTargetForFrontmost()
            let outcome = await ShortcutInjector.post(item.chord, to: target, delay: 0.12)
            if outcome == .sent {
                showExecutedNotice(chord: rendered, title: item.title)
            } else {
                reportInjectionFailure(outcome)
            }
        case .search:
            Diag.debug(.run, "search replay \(KeyFormatter.render(item.chord, style: .symbols)) title=\(Sanitizer.clamp(item.title))")
            Diag.action("search.run.replay", target: item.appBundleID ?? frontmostBundleID())
            // The injector brings the previous app back and verifies it, instead of typing
            // into whatever holds the keyboard once the palette closes.
            let injectionTarget = searchTarget.map { injectionTarget(for: $0) }
            let outcome = await ShortcutInjector.post(item.chord, to: injectionTarget, delay: 0.18)
            if outcome != .sent {
                reportInjectionFailure(outcome)
            }
            usageStore.record(usageKey: item.usageKey)
        }
    }

    /// A system hotkey has no element to press: replay the chord into the front app.
    func runSystemHotkey(_ system: BindingItem) {
        usageStore.record(usageKey: system.usageKey)
        dismissPanel()
        Diag.info(.inject, "replaying system hotkey into the front app")
        showExecutedNotice(
            chord: KeyFormatter.render(system.chord, style: state.settings.keyStyle),
            title: system.title
        )
        Task { @MainActor in
            await ShortcutInjector.post(system.chord, delay: 0.12)
        }
    }

    /// The panel has to show the toast too: the setting promises a confirmation and a run
    /// that vanishes without one reads as a failure.
    private func showExecutedNotice(chord: String, title: String) {
        guard state.settings.showExecutedHUD else { return }
        presenters.notices.show(chord: chord, title: title)
    }

    private func injectionTarget(for app: NSRunningApplication) -> InjectionTarget {
        InjectionTarget(processID: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    /// A replay that never posted a key has to say so: the success toast is the opposite
    /// outcome, and closing quietly is what made "nothing happened" unreadable.
    private func reportInjectionFailure(_ outcome: InjectionOutcome) {
        Diag.error(.inject, "replay ended without a key event: \(outcome)")
        switch outcome {
        case .sent:
            break
        case .targetMissing, .targetNotFrontmost:
            presenters.notices.showNotice(
                text: localization.text(.injectTargetUnavailable),
                kind: .failure
            )
        case .emptyChord, .eventCreationFailed:
            presenters.notices.showNotice(
                text: localization.text(.panelRunFailed),
                kind: .failure
            )
        }
    }
}
