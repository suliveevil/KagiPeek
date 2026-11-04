import AppKit

/// Decides *what* to scan, *for whom*, and *when*: the frontmost app's menu catalog, the
/// system hotkey table, and the third-party config files.
///
/// Scanning itself stays in `CatalogLoader` / `SystemHotkeyReader` / `ConfigFileScanner`; this
/// class owns the generation counters and stale-result guards, because those are the rules
/// that make a slow scan harmless.
@MainActor
final class CatalogCoordinator {
    private let state: EngineState
    private let catalogLoader: CatalogLoader
    private let appDirectory: AppDirectory
    private let localization: Localization
    private let presenters: EnginePresenters
    private let isPreviewing: () -> Bool
    private let frontmost: () -> FrontmostApp?
    private let dismissPanel: () -> Void
    private let recomputeConflicts: ([BindingItem]) -> Void
    private let resetConflictOwnerFilter: () -> Void
    private let publishInputState: () -> Void
    private let rebuildPanel: () -> Void
    private let refreshSearch: () -> Void

    init(
        state: EngineState,
        catalogLoader: CatalogLoader,
        appDirectory: AppDirectory,
        localization: Localization,
        presenters: EnginePresenters,
        isPreviewing: @escaping () -> Bool,
        frontmost: @escaping () -> FrontmostApp?,
        dismissPanel: @escaping () -> Void,
        recomputeConflicts: @escaping ([BindingItem]) -> Void,
        resetConflictOwnerFilter: @escaping () -> Void,
        publishInputState: @escaping () -> Void,
        rebuildPanel: @escaping () -> Void,
        refreshSearch: @escaping () -> Void
    ) {
        self.state = state
        self.catalogLoader = catalogLoader
        self.appDirectory = appDirectory
        self.localization = localization
        self.presenters = presenters
        self.isPreviewing = isPreviewing
        self.frontmost = frontmost
        self.dismissPanel = dismissPanel
        self.recomputeConflicts = recomputeConflicts
        self.resetConflictOwnerFilter = resetConflictOwnerFilter
        self.publishInputState = publishInputState
        self.rebuildPanel = rebuildPanel
        self.refreshSearch = refreshSearch
    }

    // MARK: - The frontmost app's catalog

    func reload(force: Bool, preserveOnEmpty: Bool = false) {
        guard !isPreviewing() else { return }
        guard let app = frontmost() else {
            state.isCatalogLoading = false
            return
        }
        // KagiPeek is an accessory app that activates itself for the search palette, the
        // settings window. Scanning its own menu bar would replace the real
        // app's shortcuts with the built-in fallback, so it is never a catalog source.
        guard !app.isSelf else {
            Diag.debug(.scan, "skipping own process as a catalog source")
            return
        }
        state.isCatalogLoading = true
        if state.panel.isVisible {
            state.panel.isScanning = true
            presenters.panel.presentPanel(state: state.panel, settings: state.settings)
        }
        // Scans run on a background queue with a concurrency of two, so a slow scan for the
        // previous app can finish after a fast one for the current app. Only the newest
        // request is allowed to publish.
        state.catalogGeneration &+= 1
        let generation = state.catalogGeneration
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.catalogLoader.load(
                app: app,
                language: self.state.settings.language,
                includeBuiltIn: self.state.settings.includeBuiltInCatalog,
                showAppleMenu: self.state.settings.showAppleMenu,
                force: force
            )
            guard !self.isPreviewing() else { return }
            guard generation == self.state.catalogGeneration else {
                Diag.debug(.scan, "dropping stale scan for \(snapshot.appIdentity)")
                return
            }
            // 一次强制重扫可能撞上菜单栏还没挂回来：它给的是空列表，而用户上一次的列表
            // 仍然有效。保留旧目录，但把「正在扫描」复位，别让面板一直转圈。
            if preserveOnEmpty,
               CatalogPublishPolicy.keepsPrevious(
                   previousCount: self.state.catalog.items.count,
                   newCount: snapshot.items.count,
                   hasMenuBar: snapshot.hasMenuBar
               ) {
                Diag.warning(.scan, "keeping the previous catalog after an empty forced rescan")
                self.state.isCatalogLoading = false
                self.state.panel.isScanning = false
                return
            }
            self.state.isCatalogLoading = false
            self.state.catalog = snapshot
            self.state.catalogSize = snapshot.items.count
            self.state.usedBuiltInCatalog = snapshot.usedBuiltInCatalog
            self.state.scanDuration = snapshot.readDuration
            self.state.scanState = snapshot.state
            self.recomputeConflicts(snapshot.items)
            self.state.panel.isScanning = false
            self.state.searchCorpus = nil
            self.state.orderedHitsCache = nil
            self.publishInputState()
            self.evaluateExclusion()
            if self.state.panel.isVisible {
                self.rebuildPanel()
            }
            self.refreshSearch()
            // One line, both sinks: the count, whether there was a menu bar at all, and — the
            // part a "my shortcuts are missing" report needs — why the scan produced what it
            // did. This used to be two near-identical lines, one per sink.
            Diag.info(.scan, """
                scanned \(snapshot.appIdentity): \(snapshot.items.count) items, \
                menus=\(snapshot.hasMenuBar), built-in=\(snapshot.usedBuiltInCatalog), \
                state=\(snapshot.state.diagnosticCode), \(Int(snapshot.readDuration * 1000))ms
                """)
            if !snapshot.hasMenuBar, !snapshot.usedBuiltInCatalog {
                Diag.warning(.scan, "no menu bar exposed and built-in catalog is off: the panel will be empty (bundle=\(snapshot.appIdentity))")
            }
        }
    }

    /// Loads one app's catalog for the palette's scope, without forcing or adding the built-in
    /// list: a scope is about that app's own commands, and a cached answer is what makes
    /// switching scope feel like flipping a page.
    func loadScopedCatalog(for app: FrontmostApp) async -> CatalogSnapshot {
        await catalogLoader.load(
            app: app,
            language: state.settings.language,
            includeBuiltIn: false,
            showAppleMenu: state.settings.showAppleMenu,
            force: false
        )
    }

    /// Old rows belong to the old process. Keeping them behind a new app name made a
    /// half-finished scan look like app B's complete catalog.
    func clearForIdentityChange() {
        state.catalog = .empty
        state.catalogSize = 0
        state.usedBuiltInCatalog = false
        state.scanState = .ok
        state.orderedHitsCache = nil
        publishInputState()
        state.rowBudgetCache = nil
        state.searchCorpus = nil
        state.conflicts = []
        state.conflictIDs = []
    }

    func evaluateExclusion() {
        guard let bundleID = frontmost()?.bundleID else {
            state.isFrontAppExcluded = false
            return
        }
        state.isFrontAppExcluded = state.settings.excludedBundleIDs.contains(bundleID)
        if state.isFrontAppExcluded {
            // "Shortcuts do nothing in this app" has exactly one cause in the settings, and
            // it used to be invisible.
            Diag.info(.scan, "front app is on the exclusion list (bundle=\(bundleID)): panel suppressed")
            dismissPanel()
        }
    }

    /// Wipes every cached scan, memory and disk. Called after a settings reset, where the
    /// fingerprints alone cannot be trusted to catch everything that changed.
    func invalidateAll() {
        catalogLoader.invalidateAll()
    }

    // MARK: - Running apps

    /// Re-reads the list of running apps. Used by the search scope menu and the conflict scan;
    /// nothing here is "browsing" any more.
    func refreshRunningApps() {
        appDirectory.refresh()
        state.runningApps = appDirectory.apps
    }

    /// Command titles of a running app, for the ignored-command picker.
    ///
    /// Reads whatever is already cached — the frontmost catalog, or the disk cache behind
    /// `CatalogLoader` — instead of forcing a scan: the picker is a convenience, and making it
    /// pay for a full AX walk of a big app would be felt as a hang in Settings.
    func commandTitles(for app: AppEntry, completion: @escaping ([String]) -> Void) {
        if app.pid == frontmost()?.pid, !state.catalog.items.isEmpty {
            completion(state.catalog.items.map(\.title))
            return
        }
        let target = FrontmostApp(
            pid: app.pid,
            bundleID: app.bundleID,
            name: app.name,
            icon: app.icon
        )
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.catalogLoader.load(
                app: target,
                language: self.state.settings.language,
                includeBuiltIn: false,
                showAppleMenu: self.state.settings.showAppleMenu,
                force: false
            )
            completion(snapshot.items.map(\.title))
        }
    }

    // MARK: - System hotkeys and config files

    func reloadSystemHotkeys() {
        state.systemBindings = SystemHotkeyReader.read(language: localization.language)
        if isPreviewing() {
            // "Named" means the name table knew the chord; the rest render as an em dash, so
            // counting non-empty titles would report 79 of 79 named and tell us nothing.
            let named = state.systemBindings.filter { $0.title != DescriptionCleaner.placeholder }.count
            Diag.info(.ui, "system hotkeys: \(state.systemBindings.count) read, \(named) named, first: \(state.systemBindings.prefix(6).map { "\(KeyFormatter.render($0.chord, style: .symbols))=\($0.title)" }.joined(separator: " | "))")
        }
        state.searchCorpus = nil
        recomputeConflicts(state.catalog.items)
        resetConflictOwnerFilter()
    }

    /// Reads the third-party config tools, off the main actor.
    ///
    /// Deliberately not tied to the app switch: these files change when the user edits them,
    /// not when they change apps, so a scan runs at launch and when it is asked for. Reading
    /// six files on every activation would be work whose result cannot have changed.
    func scanConfigFiles() {
        state.configScanTask?.cancel()
        state.configScanGeneration &+= 1
        let generation = state.configScanGeneration
        let enabled = state.settings.scanConfigFiles
        // The scan itself is the only part that leaves the main actor, and it takes nothing
        // but a Bool across: keeping `self` out of the detached closure is what lets the
        // result come back on the main actor without a data race to reason about.
        state.configScanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                enabled ? ConfigFileScanner.scan() : ConfigScanResult()
            }.value
            guard let self,
                  !Task.isCancelled,
                  generation == self.state.configScanGeneration,
                  self.state.settings.scanConfigFiles == enabled else { return }
            self.applyConfigScan(result)
        }
    }

    private func applyConfigScan(_ result: ConfigScanResult) {
        guard !isPreviewing() else { return }
        state.configScan = result
        state.configBindings = result.items
        state.searchCorpus = nil
        recomputeConflicts(state.catalog.items)
        resetConflictOwnerFilter()
        Diag.info(.scan, "config scan: \(result.totalCount) shortcuts")
    }
}
