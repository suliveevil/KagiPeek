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

    /// The last gate before any key is posted.
    ///
    /// `PanelSession` and `SearchSession` already consult `PanelRowActionPlan`, but execution
    /// is the dangerous half and must not depend on a caller remembering to ask: a config
    /// row and a restricted system action are refused here even if a future surface forgets.
    private func refusesExecution(_ item: BindingItem) -> Bool {
        if item.source == .configFile {
            presenters.notices.showNotice(
                text: localization.text(.panelUnsupportedSource),
                kind: .info
            )
            return true
        }
        if RestrictedActionPolicy.restriction(for: item).isRestricted {
            presenters.notices.showNotice(
                text: localization.text(.panelRestrictedNotice),
                kind: .info
            )
            return true
        }
        return false
    }

    /// A restricted row, refused on every surface the same way.
    ///
    /// Clicking it used to copy silently while Return said why, and the palette said why
    /// without copying. Now all three copy what the row has and say both things in one
    /// notice, and none of them closes the surface: nothing ran, so there is nothing to
    /// dismiss. A row with no chord falls back to its menu path, and the notice says which
    /// of the two was copied instead of claiming a shortcut that does not exist.
    func refuseRestricted(_ item: BindingItem) {
        let chord = KeyFormatter.render(item.chord, style: state.settings.keyStyle)
        if !chord.isEmpty, copyToPasteboard(chord) {
            presenters.notices.show(
                chord: chord,
                title: localization.text(.panelRestrictedCopiedShortcut),
                kind: .info
            )
            return
        }
        let path = item.group.joined(separator: " › ")
        if chord.isEmpty, !path.isEmpty, copyToPasteboard(path) {
            presenters.notices.show(
                chord: path,
                title: localization.text(.panelRestrictedCopiedPath),
                kind: .info
            )
            return
        }
        // Nothing to copy, or the pasteboard refused: still say why, never stay silent.
        presenters.notices.showNotice(
            text: localization.text(.panelRestrictedNotice),
            kind: .info
        )
    }

    private func copyToPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            Diag.error(.run, "pasteboard refused \(text.count) characters")
            return false
        }
        return true
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
        guard !refusesExecution(item) else { return }
        let rendered = KeyFormatter.render(item.chord, style: state.settings.keyStyle)
        if let element, await MenuTrigger.press(ResolvedAXElement(element: element)) {
            switch origin {
            case .panel:
                Diag.action("panel.run", target: item.appBundleID ?? frontmostBundleID())
                Diag.debug(.run, "pressed menu item row=\(rowID) titleLen=\(item.title.count)")
                showExecutedNotice(
                    chord: item.chord.isEmpty ? KeyFormatter.noShortcutPlaceholder : rendered,
                    title: item.title
                )
            case .search:
                Diag.info(.run, "pressed menu item from search row=\(rowID) titleLen=\(item.title.count)")
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
                menu press failed and row=\(rowID) (titleLen=\(item.title.count)) has no \
                shortcut to replay
                """)
            switch origin {
            case .panel:
                Diag.error(.inject, """
                    ax-press failed and no chord to replay row=\(rowID) \
                    titleLen=\(item.title.count) target=\(item.appBundleID ?? "?")
                    """)
            case .search:
                Diag.error(.inject, """
                    ax-press failed and no chord to replay (from search) \
                    titleLen=\(item.title.count) target=\(item.appBundleID ?? "?")
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
                row=\(rowID) titleLen=\(item.title.count)
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
            Diag.debug(.run, "search replay \(KeyFormatter.render(item.chord, style: .symbols)) row=\(rowID) titleLen=\(item.title.count)")
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
        guard !refusesExecution(system) else { return }
        usageStore.record(usageKey: system.usageKey)
        dismissPanel()
        Diag.info(.inject, "replaying system hotkey into the front app")
        showExecutedNotice(
            chord: KeyFormatter.render(system.chord, style: state.settings.keyStyle),
            title: system.title
        )
        // One pending replay at a time: a second hotkey pressed before the first one has
        // posted would otherwise leave two chords racing into the same app.
        let chord = system.chord
        state.injectionTask?.cancel()
        state.injectionTask = Task { @MainActor in
            await ShortcutInjector.post(chord, delay: 0.12)
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
        switch outcome {
        case .sent:
            return
        case .cancelled:
            // Neither success nor failure: the engine stopped the hand-off. A "run failed"
            // notice here would blame the target app for the engine's own decision, and a
            // success toast would claim a chord that was never posted.
            Diag.info(.inject, "replay cancelled, no failure reported")
            return
        case .targetMissing, .targetNotFrontmost:
            Diag.error(.inject, "replay ended without a key event: \(outcome)")
            presenters.notices.showNotice(
                text: localization.text(.injectTargetUnavailable),
                kind: .failure
            )
        case .emptyChord, .eventCreationFailed:
            Diag.error(.inject, "replay ended without a key event: \(outcome)")
            presenters.notices.showNotice(
                text: localization.text(.panelRunFailed),
                kind: .failure
            )
        }
    }
}
