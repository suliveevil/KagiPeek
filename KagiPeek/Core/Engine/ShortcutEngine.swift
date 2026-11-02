import AppKit
import Combine
import CoreGraphics
import Foundation
import os

/// What the active shortcut should do when it fires. Shared by the engine (which executes
/// the side effect) and `EngineState` (which remembers the recording target).
enum HotkeyTarget: Hashable {
    case panel
    case search
    case switcher
    case runRow
    case copyRow
}

/// Orchestrates input, catalog, ranking and presentation.
///
/// Deliberately thin: pure decisions live in `PrefixResolver` / `Ranker`, AX access in
/// `MenuScanner`, persistence in the stores and drawing in SwiftUI.
@MainActor
final class ShortcutEngine: ObservableObject {
    /// Called once by the screenshot fixture (`PreviewScenarios.swift`), which cannot write
    /// `isPreviewing` from another file.
    func beginPreview() { isPreviewing = true }

    /// The panel session phase, defined in pure code so `KeyEventRouter` can read it
    /// without importing the engine.
    typealias Phase = EnginePhase
    /// Given the engine, return the windows it drives. The App layer writes this closure, so
    /// the controllers can keep taking `engine: self` without Core importing them.
    typealias PresenterFactory = @MainActor (ShortcutEngine) -> EnginePresenters

    // MARK: - State

    /// Everything the engine knows — the published state the UI binds, the session state,
    /// the caches, the gesture machines and the in-flight tasks. The engine coordinates;
    /// this is the data (see `EngineState` for the split).
    let state = EngineState()

    // MARK: - Collaborators

    let settingsStore: SettingsStore
    let usageStore: UsageStore
    let localization = Localization()
    let permissions = AppPermissions(previewDenied: ProcessInfo.processInfo.environment["KAGIPEEK_PREVIEW"] == "permissions")

    private let monitor = KeyboardMonitor()
    private let appContext = AppContextService()
    private let catalogLoader = CatalogLoader()
    private let appDirectory = AppDirectory()
    let updateChecker = UpdateChecker()
    /// The windows the engine drives, built on first use by the factory the App layer supplied.
    ///
    /// Lazy, and built through `makePresenters`, for one reason: the controllers take the
    /// engine in their own initialisers. A factory closure that receives `self` is the way to
    /// break that cycle without Core naming any of them — see `Core/Ports`.
    private lazy var presenters: EnginePresenters = makePresenters(self)
    private let makePresenters: PresenterFactory
    /// The cross-app conflict scan. Lazy for the same reason the presenters are: it needs a
    /// way to name apps, which is a method on this class.
    private(set) lazy var conflicts = ConflictCenter(
        state: state,
        catalogLoader: catalogLoader,
        ownerName: { [weak self] bundleID in self?.ownerName(forBundleID: bundleID) }
    )
    private lazy var shortcutTester = ShortcutTester(
        appToRestore: { [weak self] in self?.lastExternalFrontmost },
        // No `assumeIsolated`: `onListeningChanged` is a plain (non-`Sendable`) closure owned
        // by the `@MainActor` `ShortcutTester`, so under main-actor default isolation both the
        // literal here and its two call sites are statically main-actor — the compiler is the
        // guarantee, not a runtime assertion.
        onListeningChanged: { [weak self] listening in
            self?.state.isTestingShortcut = listening
            self?.publishInputState()
        }
    )

    /// Where the pointer was when the panel opened.
    ///
    /// Running a command from the panel means clicking a row, and dismissing it by clicking
    /// away means clicking somewhere else — either way the pointer ends up wherever the
    /// panel sent it, and the app the user was working in has lost their place. The panel
    /// puts it back when it closes.
    private var cursorReturnPoint: CGPoint?
    /// How short a press has to be to count as a tap rather than a hold. Long enough that
    /// "hold ⌘ and glance" is never mistaken for "tick ⌘", short enough that a deliberate
    /// tap always lands inside it.
    private static let modifierTapWindow: TimeInterval = 0.35
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    /// A tap that tore itself down is rebuilt later, not immediately: rebuilding it into the
    /// same stall would repeat the whole episode within a second.
    private var monitorRetry: DispatchWorkItem?
    /// How many times in a row the tap was torn down for unresponsiveness. The first gets an
    /// automatic retry; a second inside the same unhealthy stretch stops the automation.
    private var unresponsiveTeardowns = 0
    /// Clears the count once the tap has been serving for a while, so a healthy session is
    /// not judged by an old episode.
    private var monitorHealthResetTask: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false
    /// True while the screenshot fixture is driving the app. Read by the paths that must go
    /// quiet during a capture (scanning, executing, following the frontmost app).
    private(set) var isPreviewing = false
    /// The fixture's own settings window: an `NSWindow` with `isReleasedWhenClosed = false`
    /// has to be retained by someone, and the fixture lives in another file.
    var previewWindow: NSWindow?
    /// The most recent app that was not KagiPeek, handed focus back to during a live test.
    private var lastExternalFrontmost: NSRunningApplication?

    var frontmostProcessIdentifier: pid_t { appContext.frontmost?.pid ?? 0 }

    // MARK: - Lifecycle

    init(
        settingsStore: SettingsStore,
        usageStore: UsageStore,
        presenters makePresenters: @escaping PresenterFactory
    ) {
        self.settingsStore = settingsStore
        self.usageStore = usageStore
        self.makePresenters = makePresenters
        state.settings = settingsStore.settings
        localization.update(preference: settingsStore.settings.language)
        state.defaultTitle = localization.text(.appName)
        // Plain non-`Sendable` closure properties of `@MainActor` types (`EngineState`,
        // `AppPermissions`): main-actor isolation is inferred at both the assignment and the
        // call, so no assertion is needed.
        state.searchChangeHandler = { [weak self] _ in
            self?.refreshSearch()
        }

        permissions.onChange = { [weak self] in
            self?.permissionStateChanged()
        }

        settingsStore.$settings
            .dropFirst()
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.apply(settings: value) }
            }
            .store(in: &cancellables)
    }

    /// `isolated deinit` (SE-0371): the engine is `@MainActor` and these two observer
    /// tokens are non-`Sendable`. Teardown belongs on the actor that registered them;
    /// inheriting its isolation is the type-checked way to say so.
    isolated deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Seed the published permission state from the synchronous check AppPermission's
        // initialiser already ran. Without this, the first refreshPermissions() below would
        // read as a permission flip (false → true) and force a scan — on every cold start,
        // which is exactly the moment the caches exist for.
        state.hasAccessibility = permissions.accessibility.isGranted
        state.hasInputMonitoring = permissions.inputMonitoring.isGranted

        appContext.onFrontmostChange = { [weak self] app in
            self?.frontmostChanged(app)
        }
        // A click the tap swallowed closes the panel: it was aimed at the panel's own
        // dismissal, and the app behind it must not see it.
        monitor.onOutsideMousePress = { [weak self] in
            // Same hop as `onEvent`/`onTeardown` below: the handler is a `@Sendable`
            // closure, so its body is nonisolated even though `KeyboardMonitor` always
            // delivers it on the main queue. The assertion names that guarantee.
            MainActor.assumeIsolated { self?.dismissPanel() }
        }
        appContext.onAppsChanged = { [weak self] in
            // An app launching or quitting says nothing about another app's menus, and the
            // disk cache is keyed per app with its own freshness rules — so only the
            // in-memory snapshots go. Wiping the disk here would throw away good entries
            // every time something in the background starts up.
            self?.catalogLoader.invalidateMemory()
        }
        appContext.start()

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissEverything()
            }
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }

        // One poller covers both directions: a grant landing mid-flow, and a revocation,
        // which is the change with no reliable report of its own — and the one that used to
        // freeze the machine, because the tap outlived its permission. It re-arms itself at
        // 2s while something is missing and 5s once everything is granted.
        permissions.startPolling()
        permissions.startObservingSystemChanges()
        // Every path that opens a Settings pane — the grant buttons, the standalone
        // "Open Settings" buttons — funnels through the same hook, so the drag guide
        // anchors to the Settings window no matter which surface started the request.
        // The permission is captured weakly: the hook lives on the permission itself.
        for permission in permissions.all {
            permission.onSettingsPaneOpened = { [weak self, weak permission] in
                guard let self, let permission else { return }
                presenters.guide.presentPermissionGuide(permission, localization: localization)
            }
        }
        refreshPermissions()
        applyHotkeySwallowing()
        appDirectory.start()
        refreshRunningApps()
        reloadSystemHotkeys()
        // The stored cross-app scan, not a new one: one small file instead of fifteen menu
        // walks. A scan happens when the Conflicts page has nothing to show, or on request.
        conflicts.loadCached()
        scanConfigFiles()
        startLiveTestCountdown()

        if !permissions.accessibility.isGranted {
            showPermissionsWindow()
        }
    }

    func stop() {
        state.armedTask?.cancel()
        state.liveTestPollingTask?.cancel()
        state.configScanTask?.cancel()
        state.crossAppRefreshTask?.cancel()
        monitorRetry?.cancel()
        monitorRetry = nil
        monitor.stop()
        appContext.stop()
        appDirectory.stop()
        permissions.stopPolling()
        permissions.stopObservingSystemChanges()
        state.isListening = false
        dismissEverything()
    }

    // MARK: - Settings

    private func apply(settings newValue: AppSettingsSnapshot) {
        let previous = state.settings
        state.settings = newValue
        // The diagnostics switches take effect immediately: a user turning verbose logging on
        // to reproduce a problem should not have to restart the app first.
        Diag.applySettings(newValue)
        logSettingsDelta(from: previous, to: newValue)
        localization.update(preference: newValue.language)
        applyHotkeySwallowing()

        if previous.triggerMode != newValue.triggerMode {
            state.doubleTapCommand = CommandDoubleTap()
        }
        if previous.language != newValue.language {
            reloadSystemHotkeys()
            state.searchCorpus = nil
        }
        if previous.keyStyle != newValue.keyStyle {
            state.searchCorpus = nil
        }

        if previous.language != newValue.language || previous.includeBuiltInCatalog != newValue.includeBuiltInCatalog {
            reloadCatalog(force: true)
        }
        if previous.showAppleMenu != newValue.showAppleMenu {
            // The scan itself changes shape, so the in-memory snapshot and the disk entry
            // (whose fingerprint covers this setting) are both stale now.
            reloadCatalog(force: true)
        }
        if previous.excludedBundleIDs != newValue.excludedBundleIDs {
            evaluateExclusion()
        }
        if previous.sortMode != newValue.sortMode
            || previous.showDisabledItems != newValue.showDisabledItems
            || previous.ignoredCommands != newValue.ignoredCommands {
            state.orderedHitsCache = nil
        }
        // Turning the scanners off has to forget what they found, or the conflict list would
        // keep blaming tools the user just asked us to stop reading.
        if previous.scanConfigFiles != newValue.scanConfigFiles {
            scanConfigFiles()
        }
        if state.panel.isVisible {
            rebuildPanel()
        }
        publishInputState()
    }

    /// Which settings changed, by name only. Values are deliberately left out: the exclusion
    /// list and the favourites describe how someone uses their Mac, and a diagnostic does not
    /// need to.
    private func logSettingsDelta(from old: AppSettingsSnapshot, to new: AppSettingsSnapshot) {
        var changed: [String] = []
        if old.triggerMode != new.triggerMode { changed.append("triggerMode") }
        if old.holdDelay != new.holdDelay { changed.append("holdDelay") }
        if old.doubleTapWindow != new.doubleTapWindow { changed.append("doubleTapWindow") }
        if old.panelHotkey != new.panelHotkey { changed.append("panelHotkey") }
        if old.searchHotkey != new.searchHotkey { changed.append("searchHotkey") }
        if old.switchHotkey != new.switchHotkey { changed.append("switchHotkey") }
        if old.panelPlacement != new.panelPlacement { changed.append("panelPlacement") }
        if old.columnCount != new.columnCount { changed.append("columnCount") }
        if old.sortMode != new.sortMode { changed.append("sortMode") }
        if old.language != new.language { changed.append("language") }
        if old.showAppleMenu != new.showAppleMenu { changed.append("showAppleMenu") }
        if old.includeBuiltInCatalog != new.includeBuiltInCatalog { changed.append("includeBuiltInCatalog") }
        if old.scanConfigFiles != new.scanConfigFiles { changed.append("scanConfigFiles") }
        if old.excludedBundleIDs != new.excludedBundleIDs { changed.append("excludedBundleIDs") }
        if old.ignoredCommands != new.ignoredCommands { changed.append("ignoredCommands") }
        if old.diagnosticsEnabled != new.diagnosticsEnabled { changed.append("diagnosticsEnabled") }
        if old.verboseDiagnostics != new.verboseDiagnostics { changed.append("verboseDiagnostics") }
        guard !changed.isEmpty else { return }
        Diag.info(.settings, "changed: \(changed.joined(separator: ", "))")
    }

    /// Wipes every cached scan, memory and disk. Called after a settings reset, where the
    /// fingerprints alone cannot be trusted to catch everything that changed.
    func invalidateScanCaches() {
        catalogLoader.invalidateAll()
    }

    func setPaused(_ paused: Bool) {
        state.isPaused = paused
        if paused {
            dismissEverything()
        }
    }

    func togglePaused() {
        setPaused(!state.isPaused)
    }

    // MARK: - Permissions

    func refreshPermissions() {
        // Re-read symbolic hotkeys on activation: the user may have changed them in
        // System Settings while KagiPeek was in the background.
        reloadSystemHotkeys()
        permissions.refreshAll(noticedBy: "activation")
        permissionStateChanged()
    }

    private func permissionStateChanged() {
        let granted = permissions.accessibility.isGranted
        let changed = granted != state.hasAccessibility
        let inputMonitoring = permissions.inputMonitoring.isGranted
        if changed {
            // The single most common support question has this exact answer: the permission
            // was revoked (often by a reinstall under a new signature).
            Diag.info(.perm, "accessibility \(granted ? "granted" : "revoked")")
        }
        if inputMonitoring != state.hasInputMonitoring {
            Diag.info(.perm, "input monitoring \(inputMonitoring ? "granted" : "revoked")")
        }
        state.hasAccessibility = granted
        state.hasInputMonitoring = inputMonitoring

        if granted {
            if !monitor.isActive {
                startMonitor()
            }
            // A permission flip invalidates whatever was read before — rows that were
            // empty, or fell back to the built-in catalog — so that reload is forced. The
            // first load of a session is not: frontmostChanged has already asked for it
            // (this runs before that async load comes back, hence the empty catalog), and
            // it is exactly what the caches exist for. Forcing here would rescan on every
            // cold start and the disk cache would never answer.
            if changed {
                reloadCatalog(force: true)
            } else if state.catalog.appIdentity.isEmpty {
                reloadCatalog(force: false)
            }
        } else {
            if monitor.isActive {
                monitor.stop()
                state.isListening = false
            }
            if changed {
                // Revoked Accessibility is not a cache miss: every cached row was read under
                // a grant this process no longer has.
                catalogLoader.invalidateMemory()
                clearCatalogForIdentityChange()
                state.scanState = .permissionDenied
                state.isCatalogLoading = false
                reloadCatalog(force: true)
            }
        }
    }

    /// Called when the system wakes from sleep.
    ///
    /// Sleep is the quiet killer of a background helper: the event tap is dropped across
    /// sleep, permissions can change while the screen is locked, and the frontmost app is
    /// rarely the one that was in front before. Re-assert all three instead of waiting for
    /// the user to notice that nothing works.
    func handleWake() {
        Diag.info(.tap, "woke from sleep: re-asserting the event tap")
        refreshPermissions()
        if state.hasAccessibility, !monitor.isActive {
            startMonitor()
        }
        reloadCatalog(force: false)
    }

    func requestAccessibility() {
        permissions.accessibility.performRequest()
        refreshPermissions()
    }

    func requestInputMonitoring() {
        permissions.inputMonitoring.performRequest()
        state.hasInputMonitoring = permissions.inputMonitoring.isGranted
    }

    func openAccessibilitySettings() {
        permissions.accessibility.openSettingsPane()
    }

    func openInputMonitoringSettings() {
        permissions.inputMonitoring.openSettingsPane()
    }

    func showPermissionsWindow() {
        dismissEverything()
        presenters.permissions.showPermissions()
    }


    func bringPermissionsWindowForward() {
        presenters.permissions.showPermissions()
    }

    private func startMonitor() {
        monitor.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // The composed-stroke swallow decision no longer calls the engine: the tap answers
        // it on its own thread from `publishInputState()`. A synchronous main-actor call
        // inside the tap callback is what let a wedged main thread freeze the keyboard.
        // The tap can decide that it is not worth keeping. It stops itself first — the one
        // thing that must never happen is an installed tap that cannot answer, because every
        // key and click in the session then waits out its timeout.
        monitor.onTeardown = { [weak self] reason in
            MainActor.assumeIsolated { self?.tapToreItselfDown(reason) }
        }
        do {
            try monitor.start()
            state.isListening = true
            state.statusMessage = nil
            armHealthReset()
            Diag.info(.tap, "event tap installed (accessibility granted)")
        } catch {
            state.isListening = false
            state.statusMessage = error.localizedDescription
            Diag.error(.tap, "event tap failed: \(error.localizedDescription)")
            // The one failure that makes every shortcut stop working at once. The file log
            // gets the domain and code, not just the localised sentence.
            let nsError = error as NSError
            Diag.error(.tap, "event tap failed: \(nsError.domain) code=\(nsError.code) — \(error.localizedDescription)")
            // A tap that could not be created is almost always a permission that is not
            // (or not yet) granted; the poller is what notices when that changes.
            permissions.startPolling()
        }
    }

    /// The monitor stopped itself because the tap could not be kept alive.
    ///
    /// Two different problems land here. Losing Accessibility is the user's own action and
    /// has a UI of its own, so the state is refreshed and the permissions window is the
    /// answer. An unresponsive tap means the machine stopped servicing callbacks for long
    /// enough that retrying made things worse; global shortcuts stay off until a later
    /// attempt succeeds, which is the honest trade — a paused shortcut is visible, a frozen
    /// keyboard is not.
    private func tapToreItselfDown(_ reason: KeyboardMonitor.TeardownReason) {
        state.isListening = false
        switch reason {
        case .permissionLost:
            refreshPermissions()
        case .unresponsive:
            // One automatic recovery, then none. A tap torn down for unresponsiveness is
            // evidence the input chain is in a bad state; rebuilding it on a timer puts the
            // same tap back in front of the same stream and can re-create the freeze. So
            // the first teardown retries once (a genuine one-off must not kill shortcuts
            // for the session), and a second teardown inside the same unhealthy stretch
            // stops the automation: the app goes quiet and says so, and only a relaunch —
            // or the next healthy start — arms it again.
            unresponsiveTeardowns += 1
            if unresponsiveTeardowns == 1 {
                state.statusMessage = localization.text(.errorEventTapStalled)
                scheduleMonitorRetry()
            } else {
                state.statusMessage = localization.text(.errorEventTapStalledPermanent)
                presenters.notices.showNotice(text: localization.text(.errorEventTapStalledPermanent))
                Diag.error(.tap, "tap torn down again after a retry: automatic recovery stopped to keep the input stream free")
            }
        }
    }

    /// Forgets past teardowns after five minutes of service: a tap that has run that long is
    /// a different tap from the one that stalled.
    private func armHealthReset() {
        monitorHealthResetTask?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.unresponsiveTeardowns = 0 }
        monitorHealthResetTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }

    /// One delayed attempt, not a loop: each rebuild costs the same six chances the tap just
    /// spent, and a machine that cannot answer taps will not answer this one either.
    private func scheduleMonitorRetry() {
        monitorRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.monitorRetry = nil
            guard !self.monitor.isActive, self.permissions.accessibility.isGranted else { return }
            Diag.info(.tap, "retrying the event tap after a teardown")
            self.startMonitor()
        }
        monitorRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    // MARK: - Catalog
    func reloadCatalog(force: Bool = true) {
        guard !isPreviewing else { return }
        guard let app = appContext.frontmost else {
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
            guard !self.isPreviewing else { return }
            guard generation == self.state.catalogGeneration else {
                Diag.debug(.scan, "dropping stale scan for \(snapshot.appIdentity)")
                return
            }
            self.state.isCatalogLoading = false
            self.state.catalog = snapshot
            self.state.catalogSize = snapshot.items.count
            self.state.usedBuiltInCatalog = snapshot.usedBuiltInCatalog
            self.state.scanDuration = snapshot.readDuration
            self.state.scanState = snapshot.state
            self.recomputeConflicts(for: snapshot.items)
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

    private func frontmostChanged(_ app: FrontmostApp) {
        guard !isPreviewing else { return }
        guard !app.isSelf else { return }
        // Remembered so a live shortcut test can hand focus back here: a menu shortcut only
        // fires for the app in front, and letting KagiPeek stay frontmost would rig it.
        lastExternalFrontmost = NSRunningApplication(processIdentifier: app.pid)
        Diag.debug(.scan, "frontmost changed: \(app.bundleID ?? "?") pid=\(app.pid)")
        Diag.action("app.activate", target: app.bundleID)
        dismissPanel()
        clearCatalogForIdentityChange()
        state.appName = app.name
        state.appIcon = app.icon
        evaluateExclusion()
        // Not forced: switching apps is the moment the caches exist for. The identity
        // changed, so the in-memory snapshot misses anyway; the disk cache then gets its
        // chance to hand back the rows the user last saw for this app instead of a walk of
        // the whole menu bar. An explicit refresh (a settings
        // change, a permission grant) stays forced and always rescans.
        reloadCatalog(force: false)
        if state.search.isVisible { refreshSearch() }
    }

    /// Old rows belong to the old process. Keeping them behind a new app name made a
    /// half-finished scan look like app B's complete catalog.
    private func clearCatalogForIdentityChange() {
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

    private func evaluateExclusion() {
        guard let bundleID = appContext.frontmost?.bundleID else {
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

    // MARK: - Input

    private func handle(_ event: KeyEvent) {
        // The tap decides the next event from what is published here: every branch above
        // and below mutates the composed-stroke state, so the snapshot leaves with the
        // handler whatever path it took.
        defer { publishInputState() }
        if let target = state.recordingTarget, handleRecording(event, target: target) {
            return
        }
        // While a live test is listening, every key belongs to the test. Anything KagiPeek
        // did here — arming the panel, consuming a stroke — would make it the thing that
        // swallowed the key, which is the one result this feature must never report.
        if state.isTestingShortcut { return }
        if state.isPaused { return }

        switch event.kind {
        case .interruption:
            state.doubleTapCommand.cancel()
            dismissEverything()
        case .flagsChanged:
            handleModifiers(event)
        case .keyDown:
            handleKeyDown(event)
        case .keyUp:
            handleKeyUp(event)
        }
    }

    private func handleModifiers(_ event: KeyEvent) {
        let modifiers = event.modifiers
        let previous = state.previousModifiers
        state.previousModifiers = modifiers

        if PermissionCenter.isSecureInputEnabled {
            logSecureInputOnce()
            // Only when the panel was actually up: the user just saw it vanish. A toast while
            // they type a password elsewhere would point at the password field.
            if state.phase == .active {
                presenters.notices.showNotice(text: localization.text(.permissionSecureInput))
            }
            dismissPanel()
            return
        }

        if state.settings.triggerMode == .doubleTapCommand,
           state.doubleTapCommand.process(
               modifiers: modifiers,
               previous: previous,
               now: event.happenedAt,
               window: state.settings.doubleTapWindow
           ) {
            togglePinnedPanel()
            return
        }

        switch state.phase {
        case .active:
            narrowWithHeldModifiers(modifiers, previous: previous, event: event)
        case .idle, .armed:
            considerArming(with: modifiers)
        }
    }

    /// Held or tapped modifiers while the panel is open: escape, latch, narrow.
    ///
    /// This is the which-key behaviour at the centre of the app — hold ⌘ and only the ⌘
    /// shortcuts are left — plus the two gestures layered on it: a lone hyper press closes
    /// the panel, and a quick tap ticks a modifier so ⌥ ⌘ C can be typed one key at a time.
    private func narrowWithHeldModifiers(_ modifiers: ModifierSet, previous: ModifierSet, event: KeyEvent) {
        // A lone hyper press (⌃⌥⇧⌘) is the user's "Escape" key: do not narrow the panel to a
        // prefix no menu could match; close it on a clean release instead. The gesture is a
        // pure state machine (`HyperEscape`), tested on its own.
        switch state.hyperEscape.process(modifiers: modifiers, now: event.happenedAt) {
        case .arm:
            state.modifierTap.reset()
            state.panel.heldModifiers = modifiers
            rebuildPanel()
            return
        case .releaseDismiss:
            dismissPanel()
            return
        case .clear, .none:
            break
        }

        // A lone ⇧ never counts — it also arrives while typing capital letters.
        let held = modifiers == [.shift] ? ModifierSet() : modifiers
        state.panel.heldModifiers = held
        // A tap — press and let go quickly, with nothing typed in between — sticks: it ticks
        // the modifier instead of narrowing only while the finger is down. Holding still
        // narrows temporarily. The difference is the point: holding is looking, tapping is
        // composing.
        if let tapped = state.modifierTap.flagsChanged(
            held,
            previous: previous,
            now: event.happenedAt,
            window: Self.modifierTapWindow
        ) {
            toggleLatched(tapped)
            return
        }
        // Only a modifier-only prefix is re-seeded. A real chord prefix (⌘K of ⌘K ⌘C) must
        // survive the modifier being released between strokes, which is what used to drop the
        // user back to the top level mid-chord.
        //
        // The seed is what the user is composing, not just what is down: a ticked ⌥ keeps
        // narrowing after the physical key is let go. Latched modifiers are deliberately
        // *not* cleared here — pressing a physical modifier while a sequence is being
        // composed is the normal case, not a reason to abandon it.
        if state.prefix.isEmpty || state.prefix.isModifierOnly {
            let effective = state.pending.effective
            state.prefix = effective.isEmpty ? .empty : .modifiers(effective)
        }
        state.panel.pageIndex = 0
        // Deliberately no `selectionIndex = -1` here. Narrowing is exactly the case where the
        // user is about to press Return, and a narrowed panel often has one row left: clearing
        // the selection here is what made Return do nothing.
        rebuildPanel()
        updateKeyCapture()
    }

    /// Hold-to-open, and the release that cancels it before the panel ever appears.
    private func considerArming(with modifiers: ModifierSet) {
        guard state.settings.triggerMode == .holdModifiers else { return }
        if modifiers.isEmpty || modifiers == [.shift] {
            cancelArm()
            if state.phase == .armed {
                state.phase = .idle
                state.prefix = .empty
            }
            return
        }
        armShow()
    }

    /// Secure input is the one system restriction that turns KagiPeek off silently: the OS
    /// stops delivering keys to taps while a password field has focus. One line per few
    /// seconds is enough to explain a session, and cheap enough for the modifier path.
    private func logSecureInputOnce() {
        let now = Date()
        if let last = state.lastSecureInputLog, now.timeIntervalSince(last) < 5 { return }
        state.lastSecureInputLog = now
        Diag.info(.perm, "secure input is on (password field or login window): key handling suspended")
    }

    private func handleKeyDown(_ event: KeyEvent) {
        // A modifier-only double-tap candidate must not survive a real key press: ⌘C is a
        // chord, not half of a gesture.
        state.doubleTapCommand.cancel()
        if PermissionCenter.isSecureInputEnabled {
            // Same restriction as in `handleModifiers`, reached by a different door: a key
            // pressed while secure input is on is not ours to act on, and the log says so.
            logSecureInputOnce()
            return
        }

        let action = routeKeyDown(event)
        noteGestureUse(action, event: event)
        perform(action, event: event)
    }

    /// The decision is made in pure code (`KeyEventRouter`), exactly as the walk used to run:
    /// hotkeys first (they answer in any phase), then the phase, then the panel's own keys,
    /// then chord composition. `handleKeyDown` only executes what this returns.
    private func routeKeyDown(_ event: KeyEvent) -> KeyDownAction {
        KeyEventRouter.route(
            event,
            in: RoutingContext(
                phase: state.phase,
                settings: state.settings,
                panel: state.panel,
                prefix: state.prefix,
                pending: state.pending,
                items: state.catalog.items
            )
        )
    }

    /// Two gestures watch the keys that pass through here.
    ///
    /// A key the panel consumed while a hyper is armed marks the hyper as used, so a clean
    /// release no longer counts as Escape. A key pressed while a modifier is down means the
    /// modifier was part of a shortcut, not a tap to be ticked.
    private func noteGestureUse(_ action: KeyDownAction, event: KeyEvent) {
        if state.phase == .active, event.key != nil, action != .dismiss, state.hyperEscape.armedAt != nil {
            state.hyperEscape.noteKeyUsed()
        }
        if state.phase == .active {
            state.modifierTap.noteKeyPress()
        }
    }

    /// Executes the router's answer. One case, one effect; anything longer than a line is
    /// named after what the user sees happen.
    private func perform(_ action: KeyDownAction, event: KeyEvent) {
        switch action {
        case .hotkey(let choice):
            switch choice {
            case .panel: togglePinnedPanel()
            case .search: toggleSearch()
            case .switcher: toggleShortcutSurface()
            }
        case .none:
            break
        case .cancelArm:
            abandonArm()
        case .dismiss:
            dismissPanel()
        case .showSearch:
            showSearchFromPanel()
        case .moveSelection(let delta):
            moveSelection(delta)
        case .page(let step):
            turnPage(step)
        case .performRow(let rowAction):
            performSelectedPanelRow(action: rowAction)
        case .undoLatched:
            undoLatchedOrGoUp()
        case .goUpLevel:
            goUpOneLevel()
        case .passThrough(let item, let probe):
            passThrough(item, probe: probe)
        case .replayComposed(let item, let probe):
            replayComposed(item, probe: probe)
        case .descend(let probe):
            descend(probe)
        case .noMatch(let heldModifiers):
            noteNoMatch(held: heldModifiers, event: event)
        }
    }

    private func abandonArm() {
        cancelArm()
        state.phase = .idle
        state.prefix = .empty
    }

    private func turnPage(_ step: Int) {
        if step > 0 { nextPage() } else { previousPage() }
    }

    /// The router answers from `latchedOrder`, so this usually pops; the fallback keeps the
    /// old behaviour if the tick vanished in between.
    private func undoLatchedOrGoUp() {
        if popLatched() {
            refreshAfterLatchedChange()
        } else if !state.prefix.isEmpty {
            goUpOneLevel()
        }
    }

    /// Nothing was assembled: the physical event already *is* the shortcut, so the front app
    /// performs it. Flash the row and let the key through.
    private func passThrough(_ item: BindingItem, probe: KeyChord) {
        Diag.debug(.inject, """
            passthrough: chord=\(KeyFormatter.render(probe, style: .symbols)) \
            reason=uncomposed title=\(Sanitizer.clamp(item.title))
            """)
        complete(item, probe: probe)
    }

    /// The tap swallowed this key, so the panel owes the app the shortcut: replay the
    /// assembled chord — ⌥⌘C, not C — the same way clicking a row does.
    private func replayComposed(_ item: BindingItem, probe: KeyChord) {
        usageStore.record(usageKey: item.usageKey)
        dismissPanel()
        Diag.info(
            .inject,
            "replaying composed \(KeyFormatter.render(probe, style: .symbols)) into the front app"
        )
        if state.settings.showExecutedHUD {
            presenters.notices.show(
                chord: KeyFormatter.render(probe, style: state.settings.keyStyle),
                title: item.title
            )
        }
        DispatchQueue.main.async {
            ShortcutInjector.post(probe, delay: 0.12)
        }
    }

    private func descend(_ probe: KeyChord) {
        state.prefix = probe
        // The ticked modifiers have been folded into this stroke; keeping them would apply
        // them a second time to the next one.
        state.panel.latchedModifiers = []
        state.panel.latchedOrder = []
        state.panel.pageIndex = 0
        state.panel.selectionIndex = -1
        rebuildPanel()
        updateKeyCapture()
    }

    /// Keep the panel open, and keep the ticks: the user is mid-sequence and has not made a
    /// mistake yet. A bare key with no match is not swallowed, so the app receives it and
    /// nothing is lost.
    private func noteNoMatch(held: ModifierSet, event: KeyEvent) {
        Diag.debug(.tap, """
            nomatch: prefix=\(KeyFormatter.render(state.prefix, style: .symbols)) \
            key=\(event.key?.raw ?? "-") latched=\(state.panel.latchedModifiers.rawValue)
            """)
        state.panel.heldModifiers = held
        rebuildPanel()
    }

    /// Karabiner's "hyper tap → Escape" rule usually emits Escape on key-up, so the tap
    /// consumes Esc releases as well and closes the panel from either direction.
    private func handleKeyUp(_ event: KeyEvent) {
        guard state.phase == .active else { return }
        if event.keyCode == KeyCode.escape {
            dismissPanel()
        }
    }


    /// Publishes everything the tap thread needs to answer "swallow or pass?" on its own —
    /// the decision itself lives in `ComposedSwallow.decide` and runs where the event
    /// arrives. The decision's rules (⌫ while composing, the panel's own navigation keys,
    /// then `ChordComposition`) are documented there, and the tap reading the same pure
    /// call the key handler makes is what keeps the two from running a shortcut twice.
    ///
    /// Called after every mutation that touches the published fields; the tap reading a
    /// snapshot one event stale is one wrong answer about one keystroke, while a
    /// synchronous main-thread call was a frozen keyboard, so the direction of staleness is
    /// chosen deliberately.
    /// Internal for `PreviewScenarios`. Everything else that publishes is in this file.
    func publishInputState() {
        let snapshot = ComposedSwallowState(
            isTestingShortcut: state.isTestingShortcut,
            panelIsActive: state.panel.isVisible && state.phase == .active,
            hasLatchedModifiers: !state.panel.latchedModifiers.isEmpty,
            prefix: state.prefix,
            pending: state.pending,
            heldModifiers: state.panel.heldModifiers,
            runRowKey: state.settings.runRowKey,
            copyRowKey: state.settings.copyRowKey,
            catalogItems: state.catalog.items
        )
        monitor.updateComposedSwallowState(snapshot)
    }

    private func applyHotkeySwallowing() {
        var rules: [SwallowRule] = []
        if state.recordingTarget == nil {
            for spec in [state.settings.panelHotkey, state.settings.searchHotkey, state.settings.switchHotkey] {
                rules.append(SwallowRule(
                    keyCode: spec.keyCode,
                    modifiers: spec.modifiers,
                    tolerant: spec.modifiers.count >= 3
                ))
            }
        }
        monitor.updateSwallowRules(rules)
        refreshKeyDecoding()
    }

    /// Decoding a key into a character costs a CFString per keystroke, and the tap sees every
    /// key press in the session. The engine only reads characters while a surface is taking
    /// them (the panel, a binding being recorded) — the palette's field reads its own — and
    /// the rest of the time
    /// key codes and modifiers are enough, even for hotkey matching.
    private func refreshKeyDecoding() {
        let needed = state.recordingTarget != nil || (state.panel.isVisible && state.phase == .active)
        monitor.updateDecodesKeyEvents(needed)
    }

    // MARK: - Panel lifecycle

    private func armShow() {
        guard state.phase == .idle || state.phase == .armed else { return }
        state.phase = .armed
        state.armedTask?.cancel()
        let delay = state.settings.holdDelay
        state.armedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.state.phase == .armed else { return }
            self.activatePanel(seedPrefix: true)
        }
    }

    private func cancelArm() {
        state.armedTask?.cancel()
        state.armedTask = nil
    }

    /// Opens the persistent panel. The keys used to trigger it are deliberately not used
    /// as a prefix, and the panel stays until a complete shortcut or Esc.
    ///
    /// A hold-to-summon seeds the prefix with the modifiers still down, so the panel opens
    /// already narrowed to them; the hotkey and double-⌘ paths start empty, where every row
    /// is a complete combination. Either way the rows keep their full chord — a ⌘ that is
    /// held is lit up in the row, not removed from it.
    func activatePanel(seedPrefix: Bool = false) {
        guard !state.isFrontAppExcluded else { return }
        state.search.isVisible = false
        cursorReturnPoint = Self.cursorPoint()
        state.phase = .active
        let seed = (state.previousModifiers == [.shift]) ? ModifierSet() : state.previousModifiers
        state.prefix = seedPrefix && !seed.isEmpty ? .modifiers(seed) : .empty
        state.panel.isVisible = true
        state.panel.isPinned = true
        state.panel.pageIndex = 0
        state.panel.selectionIndex = -1
        state.panel.completedRowID = nil
        state.hyperEscape = HyperEscape()
        // A modifier held down to summon the panel is the trigger, not a tap: letting go of
        // it must not tick anything.
        state.modifierTap.reset()
        state.panel.heldModifiers = state.previousModifiers == [.shift] ? [] : state.previousModifiers
        // A sequence belongs to one panel session: opening a new one starts from nothing.
        state.panel.latchedModifiers = []
        state.panel.latchedOrder = []
        state.panel.isScanning = state.isCatalogLoading
        rebuildPanel()
        updateKeyCapture()
        publishInputState()
    }

    func dismissPanel() {
        state.completionTask?.cancel()
        state.completionTask = nil
        cancelArm()
        state.phase = .idle
        state.prefix = .empty
        state.hyperEscape = HyperEscape()
        state.modifierTap.reset()
        state.panel = .hidden
        updateKeyCapture()
        publishInputState()
        presenters.panel.presentPanel(state: state.panel, settings: state.settings)
        // One run loop later: `showSearch()` closes the panel on its way to opening the
        // search palette, and pulling the pointer back out from under a surface that is
        // about to want it would be worse than leaving it where it is.
        DispatchQueue.main.async { [weak self] in self?.putCursorBack() }
    }

    /// Arms the tap to eat the click that dismisses the panel.
    ///
    /// Without it, clicking away closes the panel *and* clicks whatever sits behind it in
    /// the app the user was working in — moving the insertion point, changing the selection.
    /// Only clicks inside that app's window are eaten; the menu bar, the Dock and other apps
    /// are left alone.
    func updateOutsideMouseSwallow(panelFrame: CGRect?, appWindowFrame: CGRect?) {
        monitor.updateOutsideMouseSwallow(panelFrame: panelFrame, appWindowFrame: appWindowFrame)
    }

    /// Puts the pointer back where it was when the panel opened.
    ///
    /// Only when it actually moved. A panel opened by hotkey and dismissed with Esc never
    /// took the pointer anywhere, and warping it then would only fight the user — the same
    /// point, announced as a jump.
    private func putCursorBack() {
        guard let origin = cursorReturnPoint else { return }
        cursorReturnPoint = nil
        // A screenshot session is not a user session: moving the real pointer while a
        // preview is being captured would only ruin the capture.
        guard !isPreviewing else { return }
        // Nothing is showing any more: not the panel (it may have been reopened in the
        // meantime), and not the search palette, which has its own pointer to worry about.
        guard !state.panel.isVisible, !state.search.isVisible else { return }
        guard let current = Self.cursorPoint() else { return }
        let moved = hypot(current.x - origin.x, current.y - origin.y)
        guard moved > 2 else { return }
        CGWarpMouseCursorPosition(origin)
        // Keep the pointer and the hardware cursor in step, or the next physical move can
        // snap it back to where the device last thought it was.
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }

    /// The pointer in CG coordinates, which is both what `CGWarpMouseCursorPosition` takes
    /// and what a freshly created event reports.
    private static func cursorPoint() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    private func dismissEverything() {
        dismissPanel()
        state.search.isVisible = false
        presenters.panel.close()
    }

    /// Closes whichever surface is showing; used before opening Settings.
    func closeSurfaces() {
        dismissEverything()
    }

    private func goUpOneLevel() {
        // A tick is undone before a level is popped: the tick is what the user did most
        // recently, and ⌫ on an empty prefix would otherwise close the panel outright.
        if popLatched() {
            refreshAfterLatchedChange()
            return
        }
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

    private func complete(_ item: BindingItem, probe: KeyChord) {
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

    // MARK: - Panel content

    /// In fill-screen mode the panel can show everything at once, so the page grows with the
    /// screen instead of sticking to the small-window row limit. The arithmetic is pure
    /// (`OverlayMetrics`) and holds no `Theme` values: how rows are counted must not move
    /// when a corner radius does.
    /// Internal for `PreviewScenarios`, which computes the boundary page from it.
    var panelPageSize: Int {
        guard state.settings.panelPlacement == .fillScreen, let screen = NSScreen.main else {
            return max(1, state.settings.maxItemsPerPage)
        }
        return OverlayMetrics.fillScreenPageSize(
            visibleFrame: screen.visibleFrame.size,
            maxItemsPerPage: state.settings.maxItemsPerPage
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
    private var favoritesPolicy: FavoritesPolicy {
        FavoritesPolicy(
            showsFavoritesOnly: state.showsFavoritesOnly,
            pinToTop: state.settings.pinFavoritesToTop,
            canBeFiltered: state.settings.favoritesCanBeFiltered
        )
    }

    private func unnarrowedBudget() -> (rows: Int, headings: Int) {
        let key = RowBudgetKey(
            scannedAt: state.catalog.scannedAt,
            showsFavoritesOnly: favoritesPolicy.showsFavoritesOnly,
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
        ).filter { !isIgnored($0.item) }
        hits = favoritesPolicy.favoritesOnly(hits) { usageStore.isFavorite($0.item.usageKey) }
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
        state.appName.isEmpty ? (appContext.frontmost?.name ?? "") : state.appName
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
            sectionTitle: sectionTitle
        )
        if isPreviewing {
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

    /// One row per entry, described for the builder.
    private func rowSpecs(
        for entries: [PanelEntry],
        highlighted: Set<String>,
        systemTitle: String,
        sectionTitle: String
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
                // Two sections, never interleaved: the app's rows keep the flat chord order
                // under the app's name, the system's hotkeys under theirs. Each title is a
                // card header, so the boundary is a shape rather than a line of text.
                groupTitle: entry.isSystem ? systemTitle : sectionTitle,
                // The chevron and the click share one answer: a row without a chevron is a
                // shortcut the user can run (`KeyChord.isFinalStroke`).
                isGroup: !hit.item.chord.isFinalStroke(after: state.prefix),
                isEnabled: hit.item.isEnabled,
                hasConflict: state.conflictIDs.contains(hit.item.id),
                isHighlighted: highlighted.contains(hit.item.id),
                isCompleted: state.panel.completedRowID == hit.item.id,
                isFavorite: usageStore.isFavorite(hit.item.usageKey)
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
    private func isIgnored(_ item: BindingItem) -> Bool {
        IgnoredCommands.isIgnored(
            item.title,
            bundleID: item.appBundleID,
            in: state.settings.ignoredCommands
        )
    }

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
            favorites: favoritesPolicy,
            includeDisabled: state.settings.showDisabledItems,
            ignoredSignature: ignoredSignature
        )
        if let cached = state.orderedHitsCache, cached.key == cacheKey {
            return cached.hits
        }
        let hits = PrefixResolver.hits(
            for: state.prefix,
            in: state.catalog.items,
            includeDisabled: state.settings.showDisabledItems
        ).filter { !isIgnored($0.item) }
        // The panel is ordered by the shortcut itself, not by a score and not by the menu it
        // came from: ⌘C, ⌘V and ⌘X belong together. The modifiers being composed decide which
        // block comes first, so pressing ⌘ — or ticking it — answers the question without
        // hiding the answer for every other modifier.
        let emphasized = state.pending.effective
        var sorted = hits.sorted {
            PanelOrdering.areInIncreasingOrder($0.item, $1.item, emphasizing: emphasized)
        }
        sorted = favoritesPolicy.favoritesOnly(sorted) { usageStore.isFavorite($0.item.usageKey) }
        sorted = favoritesPolicy.pinningFavoritesFirst(sorted) { usageStore.isFavorite($0.item.usageKey) }
        state.orderedHitsCache = (cacheKey, sorted)
        return sorted
    }

    /// The panel's rows as one sequence: the app's section, then the system's.
    ///
    /// `orderedHits()` stays app-only — it is what the prefix, the held modifiers and the
    /// order cache reason about. The system section is appended here, once, so pagination and
    /// "jump to the page of this row" walk exactly the sequence the panel draws.
    /// What the palette's window is sending keys to, for the fixture's `/` round-trip log.
    /// Nothing else asks: the app's own `/` handling reads the responder directly.
    var paletteKeyFocusDescription: String { presenters.panel.keyFocusDescription }

    /// Internal for `PreviewScenarios`, which needs the page a heading lands on.
    func panelSequence() -> [PanelEntry] {
        let appHits = orderedHits()
        guard state.prefix == .empty, !state.systemBindings.isEmpty else {
            return PanelSections.combine(app: appHits, system: [])
        }
        let items = favoritesPolicy.favoritesOnly(state.systemBindings) { usageStore.isFavorite($0.usageKey) }
        var sorted = PanelOrdering.sorted(items, emphasizing: state.pending.effective)
        sorted = favoritesPolicy.pinningFavoritesFirst(sorted) { usageStore.isFavorite($0.usageKey) }
        return PanelSections.combine(app: appHits, system: PanelSections.hits(for: sorted))
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
        // A command with no keyboard shortcut still gets a row; its shortcut column says so
        // with a dash instead of going blank and reading as a rendering bug.
        if hit.item.chord.isEmpty {
            return [KeyFormatter.Segment(kind: .label, text: localization.text(.overlayNoShortcut))]
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
        publishInputState()
    }

    /// Undoes one tick, the most recent one first.
    @discardableResult
    private func popLatched() -> Bool {
        guard let next = LatchedTicks.popping(
            latched: state.panel.latchedModifiers,
            order: state.panel.latchedOrder
        ) else { return false }
        state.panel.latchedModifiers = next.latched
        state.panel.latchedOrder = next.order
        publishInputState()
        return true
    }

    /// Re-seeds the prefix and redraws after the ticked set changed.
    private func refreshAfterLatchedChange() {
        if state.prefix.isEmpty || state.prefix.isModifierOnly {
            let effective = state.pending.effective
            state.prefix = effective.isEmpty ? .empty : .modifiers(effective)
        }
        state.orderedHitsCache = nil
        state.panel.pageIndex = 0
        rebuildPanel()
        updateKeyCapture()
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

    /// The Accessibility element behind a row, taken from the snapshot that owns the row.
    ///
    /// Ids carry the app's bundle id, so a row can only ever be found in one of the two
    /// scanned snapshot — the front app's — and looking in it
    /// is the honest way to say "whichever app this row belongs to". A snapshot restored
    /// from the disk cache carries no elements, so its rows are resolved on demand by
    /// re-walking the menu path.
    private func element(forRowID rowID: String) -> AXUIElement? {
        if state.search.scopeAppID != nil {
            if let element = state.searchScopeCatalog.elements[rowID] { return element }
            if let resolved = resolveCachedElement(in: &state.searchScopeCatalog, rowID: rowID) {
                return resolved
            }
        }
        if let element = state.catalog.elements[rowID] { return element }
        if let resolved = resolveCachedElement(in: &state.catalog, rowID: rowID) { return resolved }
        return nil
    }

    /// Re-walks a restored row's menu path into a live element and verifies the title, so a
    /// menu that changed under the cache resolves to nil instead of to the command that
    /// took the row's place. The element is memoised on the snapshot: pressing the same row
    /// twice costs one walk.
    private func resolveCachedElement(in snapshot: inout CatalogSnapshot, rowID: String) -> AXUIElement? {
        // A real scan already carries its elements; only a restored snapshot needs this.
        // Built-in fallback rows have no menu path either, and keep replaying their chord.
        guard snapshot.elements.isEmpty,
              let pid = snapshot.appPID,
              let item = snapshot.items.first(where: { $0.id == rowID }),
              let axPath = item.axPath,
              let resolved = MenuScanner.element(atAxPath: axPath, pid: pid, expectingTitle: item.title)
        else { return nil }
        snapshot.elements[rowID] = resolved
        return resolved
    }

    func copyShortcut(rowID: String) {
        guard let item = item(forRowID: rowID) else { return }
        let text = KeyFormatter.render(item.chord, style: state.settings.keyStyle)
        // Copying an empty string would wipe the pasteboard and report success.
        guard !text.isEmpty else {
            presenters.notices.show(chord: "!", title: localization.text(.panelNothingToCopy))
            return
        }
        copyToPasteboard(text)
    }

    /// Copy with the toast both surfaces share, so a copy that changes nothing on screen
    /// still answers the click.
    func copyRow(rowID: String) {
        guard let item = item(forRowID: rowID) else { return }
        let text = KeyFormatter.render(item.chord, style: state.settings.keyStyle)
        // A command with no shortcut has nothing to put on the pasteboard; saying "copied"
        // after clearing it would be a lie the user only notices later.
        guard !text.isEmpty else {
            presenters.notices.show(chord: "!", title: localization.text(.panelNothingToCopy))
            return
        }
        guard copyToPasteboard(text) else {
            presenters.notices.show(chord: "!", title: localization.text(.panelCopyFailed))
            return
        }
        presenters.notices.show(chord: text, title: localization.text(.panelCopied))
    }

    func showSettings() {
        dismissEverything()
        presenters.settings.showSettings()
    }

    func nextPage() {
        guard state.panel.pageIndex + 1 < state.panel.pageCount else { return }
        state.panel.pageIndex += 1
        state.panel.selectionIndex = -1
        rebuildPanel()
    }

    func previousPage() {
        guard state.panel.pageIndex > 0 else { return }
        state.panel.pageIndex -= 1
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
            replaySystemHotkey(system)
        } else {
            // Neither namespace knows this id. Reachable only if a row and the catalog
            // disagree, which used to present itself as "clicking does nothing".
            Diag.error(.run, "row \(rowID) is in neither the catalog nor the system hotkeys")
        }
    }

    /// A catalog row either opens the level below it or runs the command.
    private func activateCatalogItem(_ item: BindingItem, rowID: String) {
        if let step = nextLevelStep(for: item) {
            enterNextLevel(of: item, step: step)
            return
        }
        guard item.isEnabled else {
            Diag.info(.run, "ignoring disabled row \(item.title)")
            return
        }
        usageStore.record(usageKey: item.usageKey)
        dismissPanel()
        pressOrReplay(item, rowID: rowID)
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
        updateKeyCapture()
    }

    /// Triggering the command is the point, so the menu item itself is pressed first: it
    /// works for commands that have no shortcut at all, and for the ones that do it is
    /// exactly what clicking the menu would do. Replaying the chord is the fallback — for a
    /// stale element, or an app that refuses the press.
    private func pressOrReplay(_ item: BindingItem, rowID: String) {
        let rendered = KeyFormatter.render(item.chord, style: state.settings.keyStyle)
        if let element = element(forRowID: rowID), MenuTrigger.press(element) {
            Diag.action("panel.run", target: item.appBundleID ?? appContext.frontmost?.bundleID)
            Diag.debug(.run, "pressed menu item \(Sanitizer.clamp(item.title))")
            showExecutedNotice(
                chord: item.chord.isEmpty ? KeyFormatter.noShortcutPlaceholder : rendered,
                title: item.title
            )
            return
        }
        if item.chord.isEmpty {
            // No shortcut to replay either: the row is unreachable until the next scan.
            Diag.error(.run, """
                menu press failed and \(item.title) has no shortcut \
                to replay
                """)
            // Two ways out, both gone: the press was refused and there is no chord. This
            // is the row that "does nothing" until the next scan.
            Diag.error(.inject, """
                ax-press failed and no chord to replay row=\(rowID) \
                title=\(Sanitizer.clamp(item.title)) target=\(item.appBundleID ?? "?")
                """)
            return
        }
        Diag.debug(.run, """
            ax-press refused, replaying \(KeyFormatter.render(item.chord, style: .symbols)) \
            row=\(rowID) title=\(Sanitizer.clamp(item.title))
            """)
        Diag.action("panel.run.replay", target: item.appBundleID ?? appContext.frontmost?.bundleID)
        showExecutedNotice(chord: rendered, title: item.title)
        DispatchQueue.main.async {
            ShortcutInjector.post(item.chord, delay: 0.12)
        }
    }

    /// The panel has to show the toast too: the setting promises a confirmation and a run
    /// that vanishes without one reads as a failure.
    private func showExecutedNotice(chord: String, title: String) {
        guard state.settings.showExecutedHUD else { return }
        presenters.notices.show(chord: chord, title: title)
    }

    private func replaySystemHotkey(_ system: BindingItem) {
        usageStore.record(usageKey: system.usageKey)
        dismissPanel()
        Diag.info(.inject, "replaying system hotkey into the front app")
        showExecutedNotice(
            chord: KeyFormatter.render(system.chord, style: state.settings.keyStyle),
            title: system.title
        )
        DispatchQueue.main.async {
            ShortcutInjector.post(system.chord, delay: 0.12)
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

    private func updateKeyCapture() {
        var identifiers: Set<UInt32> = []
        var capturedKeyCodes: Set<UInt16> = []
        if state.panel.isVisible, state.phase == .active {
            // While the list is narrowed the user is physically holding the modifiers, so
            // every key the panel consumes arrives carrying them. Both spellings have to be
            // captured — the bare one and the one with the held set — or the panel answers a
            // key it never swallowed and the front app acts on it as well. ⌃↩ used to reach
            // the front app while the panel did nothing at all.
            let held = state.panel.heldModifiers
            func capture(_ keyCode: UInt16, _ modifiers: ModifierSet) {
                identifiers.insert(KeySwallowRules.identifier(keyCode: keyCode, modifiers: modifiers))
                if !held.isEmpty {
                    identifiers.insert(
                        KeySwallowRules.identifier(keyCode: keyCode, modifiers: modifiers.union(held))
                    )
                }
            }
            for keyCode in KeyCode.arrows {
                capture(keyCode, [])
            }
            // The two row keys, whatever they are recorded to, including the Enter alias.
            // Swallowing them keeps the front app from also acting on a chord the panel
            // has just handled.
            for pair in RowKeyRouter.capturedIdentifiers(run: state.settings.runRowKey, copy: state.settings.copyRowKey) {
                capture(pair.keyCode, pair.modifiers)
            }
            // Esc closes the panel whatever the modifiers are.
            capturedKeyCodes.insert(KeyCode.escape)
            // Emacs-style arrows are consumed by the panel as well.
            for keyCode in [KeyCode.ctrlF, KeyCode.ctrlB, KeyCode.ctrlP, KeyCode.ctrlN] {
                capture(keyCode, [.control])
            }
            // ; / ' page through the list.
            capture(KeyCode.semicolon, [])
            capture(KeyCode.quote, [])
            // Backspace only belongs to the panel while navigating a chord.
            if !state.prefix.isEmpty {
                capture(KeyCode.delete, [])
            }
            // A bare `/` is the panel's own key: it opens the palette. Without capturing it
            // the app behind would also see it — in a browser that is "quick find", which
            // would then open on top of the palette that just opened.
            identifiers.insert(KeySwallowRules.identifier(keyCode: KeyCode.slash, modifiers: []))
        }
        monitor.updateCapturedKeys(identifiers)
        monitor.updateCapturedKeyCodes(capturedKeyCodes)
        refreshKeyDecoding()
    }

    // MARK: - Statistics

    /// The per-app list the statistics tab expands: shortcut, command, presses.
    ///
    /// Usage records keep only an owner and a key, so the titles have to be joined from
    /// whatever the app knows — the live catalog, the built-in list,
    /// the config scanners, and the disk cache for apps that are not in front.
    func usageEntries(for bundleID: String) -> [UsageEntry] {
        let signature = [
            String(usageStore.totalPresses),
            String(state.catalog.scannedAt.timeIntervalSince1970),
            state.settings.language.rawValue,
            // The order is part of the answer now: without the mode here, changing the
            // picker would keep serving the previous list from the cache.
            state.settings.sortMode.rawValue
        ].joined(separator: "|")
        if let cached = state.usageBreakdownCache[bundleID], cached.signature == signature {
            return cached.entries
        }
        let joined = UsageBreakdown.entries(
            for: bundleID,
            records: usageStore.records,
            known: knownBindings(for: bundleID)
        )
        let entries = UsageOrdering.entries(joined, mode: state.settings.sortMode)
        state.usageBreakdownCache[bundleID] = (signature, entries)
        return entries
    }

    private func knownBindings(for bundleID: String) -> [BindingItem] {
        switch bundleID {
        case "system":
            return state.systemBindings
        case "*":
            return BuiltInCatalog.items(language: L10n.resolvedLanguage(state.settings.language))
        default:
            var items = state.catalog.items + externalBindings
            items += MenuScanCache.cachedItems(identity: bundleID)
            return items
        }
    }

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
        if app.pid == appContext.frontmost?.pid, !state.catalog.items.isEmpty {
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

    /// Internal for `PreviewScenarios` (screenshot fixture). Not API: the engine calls it
    /// from `apply(settings:)`.
    func reloadSystemHotkeys() {
        state.systemBindings = SystemHotkeyReader.read(language: localization.language)
        if isPreviewing {
            // "Named" means the name table knew the chord; the rest render as an em dash, so
            // counting non-empty titles would report 79 of 79 named and tell us nothing.
            let named = state.systemBindings.filter { $0.title != DescriptionCleaner.placeholder }.count
            Diag.info(.ui, "system hotkeys: \(state.systemBindings.count) read, \(named) named, first: \(state.systemBindings.prefix(6).map { "\(KeyFormatter.render($0.chord, style: .symbols))=\($0.title)" }.joined(separator: " | "))")
        }
        state.searchCorpus = nil
        recomputeConflicts(for: state.catalog.items)
        conflicts.resetOwnerFilterIfGone()
    }


    // MARK: - Cross-app conflicts

    /// The scan itself lives in `ConflictCenter`; these are the three entry points the
    /// settings page and the launch path use.
    func prepareCrossAppConflicts() { conflicts.prepare() }

    func rescanCrossAppConflicts() { conflicts.rescan() }

    /// Internal for `PreviewScenarios`: the fixture has no scan to derive conflicts from.
    func recomputeConflicts(for items: [BindingItem]) { conflicts.recompute(items: items) }

    var conflictOwnerOptions: [ConflictOwnerFilter] { conflicts.ownerOptions }

    // MARK: - Third-party config files

    /// Everything that is not part of the frontmost app's own menus but can still claim a
    /// combo: the system's own hotkeys plus whatever the config scanners found.
    private var externalBindings: [BindingItem] { state.systemBindings + state.configBindings }

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
        guard !isPreviewing else { return }
        state.configScan = result
        state.configBindings = result.items
        state.searchCorpus = nil
        recomputeConflicts(for: state.catalog.items)
        conflicts.resetOwnerFilterIfGone()
        Diag.info(.scan, "config scan: \(result.totalCount) shortcuts")
    }

    /// The display name of an app that owns a binding, used by the live test verdict.
    func ownerName(forBundleID bundleID: String) -> String? {
        if let name = appDirectory.apps.first(where: { $0.bundleID == bundleID })?.name { return name }
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .localizedName
    }

    /// Who a binding belongs to, in words the user will recognise.
    ///
    /// Menu items carry no owner of their own: they belong to whoever was frontmost when
    /// they were scanned, which only the engine knows.
    func displayOwner(of item: BindingItem) -> String {
        if let tool = item.configTool { return tool.displayName }
        if item.source == .system { return "macOS" }
        if let bundleID = item.appBundleID, let name = ownerName(forBundleID: bundleID) { return name }
        if item.appBundleID == nil { return localization.text(.ownerBuiltIn) }
        return state.appName.isEmpty ? (item.appBundleID ?? item.title) : state.appName
    }

    /// The row's name. macOS reports some system hotkeys without one, and the placeholder it
    /// leaves behind ("—") also means "no keyboard shortcut" a few rows down, so the chord
    /// stands in for the missing name wherever a title is drawn.
    func displayName(of item: BindingItem) -> String {
        guard item.title == DescriptionCleaner.placeholder else { return item.title }
        let rendered = KeyFormatter.render(item.chord, style: state.settings.keyStyle)
        return rendered.isEmpty ? item.title : rendered
    }

    // MARK: - Live shortcut test

    func startLiveTest(for chord: KeyChord) {
        dismissPanel()
        shortcutTester.start(for: chord)
        state.liveTestState = shortcutTester.state
    }

    func cancelLiveTest() {
        shortcutTester.cancel()
        state.liveTestState = shortcutTester.state
    }

    /// The verdict of a finished test for `chord`, or nil when no test of it has run.
    func liveTestVerdict(for chord: KeyChord) -> LiveTestVerdict? {
        shortcutTester.verdict(
            for: chord,
            items: state.catalog.items + externalBindings
        ) { [weak self] bundleID in self?.ownerName(forBundleID: bundleID) }
    }

    /// The combo the tester is currently busy with, so a row knows whether the countdown on
    /// screen belongs to it or to a different chord.
    var liveTestChord: KeyChord? { shortcutTester.testedChord }

    /// Polls the tester while it is listening. The tester owns the timing and mutates its own
    /// state, so published state has to be pulled across rather than pushed from inside it.
    private func startLiveTestCountdown() {
        state.liveTestPollingTask?.cancel()
        state.liveTestPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                let current = self.shortcutTester.state
                if self.state.liveTestState != current {
                    self.state.liveTestState = current
                }
            }
        }
    }

    // MARK: - Search

    func showSearch() {
        openSearch(keepingQuery: false)
    }

    /// `/` in the panel: the palette opens on the query it was last left with.
    ///
    /// The panel and the palette are two views of one window, and `/` is the door between
    /// them. Coming back from the palette and pressing `/` again is a round trip through the
    /// same search, so the query, the scope and the selection survive it — losing typed text
    /// to a view switch would make the switch not worth using.
    func showSearchFromPanel() {
        guard state.panel.isVisible, !state.search.isVisible else { return }
        Diag.info(.ui, "panel: `/` opens the search palette (query kept: \(state.search.query.isEmpty ? "no" : "yes"))")
        openSearch(keepingQuery: true)
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

    private func openSearch(keepingQuery: Bool) {
        dismissPanel()
        if !keepingQuery {
            state.search.query = ""
            // Always open on the frontmost app: a scope left over from the last session
            // would answer a question the user is not asking.
            selectSearchScope(nil)
        } else if let pid = state.searchScopeProcessID,
                  NSRunningApplication(processIdentifier: pid)?.isTerminated != false {
            // A kept scope whose app has quit in the meantime would answer from a list that
            // can no longer be run; fall back to the frontmost app, keeping the query.
            selectSearchScope(nil)
        }
        state.search.selection = 0
        state.search.scrollRequest &+= 1
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
        // With a scope, the app to run in is the one being searched — it is usually *not* in
        // front, because the palette took the keyboard from whatever was.
        let scoped = state.searchScopeProcessID.flatMap { NSRunningApplication(processIdentifier: $0) }
        let target = scoped ?? presenters.panel.searchTargetApplication ?? NSWorkspace.shared.frontmostApplication
        hideSearch()
        if let scoped, !scoped.isActive {
            // Bring it forward first, then trigger: a menu press into a background app and a
            // chord replayed to the wrong window are both ways to do nothing visible.
            scoped.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.triggerSearchItem(item, target: scoped)
            }
            return
        }
        triggerSearchItem(item, target: target)
    }

    /// The trigger itself, split out so the scoped path can activate first and still share it.
    private func triggerSearchItem(_ item: BindingItem, target: NSRunningApplication?) {
        guard RowEligibility.canActivate(isEnabled: item.isEnabled) else { return }
        // Pressing the menu item is the primary trigger, exactly as in the panel and the
        // search: it reaches commands that have no shortcut at all. The palette gives no
        // confirmation either way, so the HUD stays out of this path.
        if let element = element(forRowID: item.id), MenuTrigger.press(element) {
            Diag.info(.run, "pressed menu item \(item.title) from search")
            Diag.action("search.run", target: item.appBundleID ?? appContext.frontmost?.bundleID)
            DispatchQueue.main.async { target?.activate() }
            usageStore.record(usageKey: item.usageKey)
            return
        }
        guard !item.chord.isEmpty else {
            Diag.error(.run, """
                menu press failed and \(item.title) has no shortcut \
                to replay
                """)
            Diag.error(.inject, """
                ax-press failed and no chord to replay (from search) \
                title=\(Sanitizer.clamp(item.title)) target=\(item.appBundleID ?? "?")
                """)
            return
        }
        Diag.debug(.run, "search replay \(KeyFormatter.render(item.chord, style: .symbols)) title=\(Sanitizer.clamp(item.title))")
        Diag.action("search.run.replay", target: item.appBundleID ?? appContext.frontmost?.bundleID)
        DispatchQueue.main.async {
            target?.activate()
            ShortcutInjector.post(item.chord, delay: 0.18)
        }
        usageStore.record(usageKey: item.usageKey)
    }

    /// Return in the search palette behaves exactly like a click: close it, return to
    /// the front app and replay the shortcut there.
    func confirmSearchSelection() {
        guard state.search.results.indices.contains(state.search.selection) else { return }
        activateSearchResult(state.search.selection)
    }

    /// Rows the palette searches: the scoped app's commands, or the frontmost app's plus the
    /// system's own hotkeys.
    private var searchItems: [BindingItem] {
        state.search.scopeAppID == nil ? state.catalog.items + state.systemBindings : state.search.scopeItems
    }

    /// Points the palette at another app, or back at the frontmost one with nil.
    func selectSearchScope(_ appID: String?) {
        guard appID != state.search.scopeAppID else { return }
        state.search.scopeAppID = appID
        state.search.scopeName = ""
        state.search.scopeItems = []
        state.searchScopeIcon = nil
        state.searchScopeProcessID = nil
        state.searchScopeCatalog = .empty
        state.searchCorpus = nil
        guard let appID, let app = state.runningApps.first(where: { $0.id == appID }) else {
            state.search.loadState = .idle
            state.search.usedBuiltInCatalog = false
            refreshSearch()
            return
        }
        state.search.scopeName = app.name
        state.searchScopeIcon = app.icon
        state.searchScopeProcessID = app.pid
        state.search.loadState = .loading
        state.search.usedBuiltInCatalog = false
        refreshSearch()
        // Cache first: switching scope should feel like flipping a page, not like a scan.
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.catalogLoader.load(
                app: FrontmostApp(pid: app.pid, bundleID: app.bundleID, name: app.name, icon: app.icon),
                language: self.state.settings.language,
                includeBuiltIn: false,
                showAppleMenu: self.state.settings.showAppleMenu,
                force: false
            )
            guard self.state.search.scopeAppID == appID else { return }
            self.state.search.scopeItems = snapshot.items
            self.state.searchScopeCatalog = snapshot
            self.state.searchCorpus = nil
            self.state.search.loadState = snapshot.state == .permissionDenied ? .permissionDenied : .ready
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
        guard isStarted else { return }
        // The corpus is built from the *scoped* items, not from the frontmost catalog: the
        // palette existed to search one app, and a corpus built from somebody else's menus
        // answers every keystroke with the wrong app's list. The key makes the scope part of
        // the cache identity, so a scope switch (or its catalog arriving a moment later)
        // cannot be answered from the previous app's documents.
        let corpusKey = [
            state.search.scopeAppID ?? "-",
            String(state.catalog.scannedAt.timeIntervalSince1970),
            String(state.searchScopeCatalog.scannedAt.timeIntervalSince1970),
            String(searchItems.count),
            state.settings.keyStyle.rawValue,
            localization.language.rawValue
        ].joined(separator: "|")
        if state.searchCorpus == nil || state.searchCorpusKey != corpusKey {
            state.searchCorpus = SearchCorpus(items: searchItems, style: state.settings.keyStyle)
            state.searchCorpusKey = corpusKey
        }
        // A query that spells out a combo gets a direct answer about who owns it, even when
        // the answer is "one thing, so no conflict" — which is exactly the case the conflict
        // list stays silent about.
        state.search.comboAnswer = ComboLookup.answer(forQuery: state.search.query, in: searchItems + externalBindings)
        // An empty field means "show this app's list", not "show the first 60 of it".
        let isEmptyQuery = state.search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let includeDisabled = state.settings.showDisabledItems
        var results = (state.searchCorpus?.search(state.search.query, limit: isEmptyQuery ? 400 : 60) ?? [])
            .filter {
                !isIgnored($0)
                    && (includeDisabled || RowEligibility.canActivate(isEnabled: $0.isEnabled))
            }
        if !favoritesPolicy.canBeFiltered,
           !state.search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let existing = Set(results.map(\.id))
            let favorites = searchItems.filter {
                usageStore.isFavorite($0.usageKey)
                    && !isIgnored($0)
                    && (includeDisabled || RowEligibility.canActivate(isEnabled: $0.isEnabled))
                    && !existing.contains($0.id)
            }
            results.append(contentsOf: favorites)
        }
        results = favoritesPolicy.pinningFavoritesFirst(results) { usageStore.isFavorite($0.usageKey) }
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
        if isPreviewing {
            // A screenshot cannot show which app's list it is showing; this line can.
            Diag.info(.ui, """
                search: scope=\(state.search.scopeAppID ?? "frontmost") items=\(searchItems.count) \
                results=\(results.count) first=\(Sanitizer.clamp(results.first?.title ?? "-"))
                """)
        }
    }

    // MARK: - Hotkey recording

    func beginRecording(_ target: HotkeyTarget) {
        state.recordingTarget = target
        dismissPanel()
        applyHotkeySwallowing()
    }

    func cancelRecording() {
        guard state.recordingTarget != nil else { return }
        state.recordingTarget = nil
        applyHotkeySwallowing()
    }

    private func handleRecording(_ event: KeyEvent, target: HotkeyTarget) -> Bool {
        switch event.kind {
        case .flagsChanged:
            return true
        case .keyUp:
            return true
        case .interruption:
            state.recordingTarget = nil
            applyHotkeySwallowing()
            return true
        case .keyDown:
            // A held key would otherwise be recorded as the binding and then fire.
            if event.isRepeat { return true }
            if event.keyCode == KeyCode.escape, event.modifiers.isEmpty {
                state.recordingTarget = nil
                applyHotkeySwallowing()
                return true
            }
            // A global hotkey needs a modifier, otherwise typing would trigger it. A row key
            // is read only while the panel owns the keyboard, so it may
            // be a bare Return — but still not a bare character, which would break chord
            // entry and filtering.
            switch target {
            case .runRow, .copyRow:
                // Esc and the arrows are the panel's own navigation, so they stay reserved.
                let reserved: Set<UInt16> = Set([KeyCode.escape] + KeyCode.arrows)
                guard !reserved.contains(event.keyCode) else { return true }
                let isCharacter = (event.key?.raw.count ?? 0) == 1
                guard !event.modifiers.isEmpty || !isCharacter else { return true }
            case .panel, .search, .switcher:
                guard event.modifiers.contains(.command)
                        || event.modifiers.contains(.option)
                        || event.modifiers.contains(.control) else {
                    return true
                }
            }
            let spec = HotkeySpec(keyCode: event.keyCode, modifiers: event.modifiers)
            switch target {
            case .panel:
                settingsStore.settings.panelHotkey = spec
            case .search:
                settingsStore.settings.searchHotkey = spec
            case .switcher:
                settingsStore.settings.switchHotkey = spec
            case .runRow:
                settingsStore.settings.runRowKey = spec
            case .copyRow:
                settingsStore.settings.copyRowKey = spec
            }
            state.recordingTarget = nil
            applyHotkeySwallowing()
            return true
        }
    }

    // MARK: - Commands from the UI

    func togglePinnedPanel() {
        if state.panel.isVisible, state.phase == .active {
            dismissPanel()
            return
        }
        activatePanel()
    }

    /// One shortcut that swaps between the panel and the search palette.
    func toggleShortcutSurface() {
        if state.search.isVisible {
            hideSearch()
            activatePanel()
        } else if state.panel.isVisible, state.phase == .active {
            dismissPanel()
            showSearch()
        } else {
            activatePanel()
        }
    }

    func resetUsage() {
        usageStore.reset()
        state.orderedHitsCache = nil
        rebuildPanel()
    }

    func showHUD(chord: String, title: String) {
        presenters.notices.show(chord: chord, title: title)
    }

    // MARK: - Diagnostics

    /// One JSON report for a bug report: what the app can see, what it persisted, and the
    /// command that prints the matching log lines. Nothing is uploaded; the user saves the
    /// file and decides who gets it.
    func diagnosticsReport() -> Data? {
        let info = Bundle.main.infoDictionary
        var payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "bundleID": Bundle.main.bundleIdentifier ?? "?",
            "bundlePath": Bundle.main.bundlePath,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "schemaVersion": AppSettingsSnapshot.currentSchemaVersion,
            "hasAccessibility": state.hasAccessibility,
            "hasInputMonitoring": state.hasInputMonitoring,
            "isListening": state.isListening,
            "catalogSize": state.catalogSize,
            "frontmost": state.appName,
            "frontmostBundleID": appContext.frontmost?.bundleID ?? "",
            "usedBuiltInCatalog": state.usedBuiltInCatalog,
            // The three numbers a "Return did nothing" report needs: was a row selected, how
            // many rows were there, and what prefix was the panel matching against.
            "panelSelectionIndex": state.panel.selectionIndex,
            "panelRowCount": state.panel.flatRowIDs.count,
            "prefix": KeyFormatter.render(state.prefix, style: state.settings.keyStyle),
            "scanDuration": state.scanDuration,
            "scanState": {
                switch state.scanState {
                case .ok: return "ok"
                case .noMenus: return "noMenus"
                case .permissionDenied: return "permissionDenied"
                }
            }(),
            "conflicts": state.conflicts.count,
            "systemHotkeys": state.systemBindings.count,
            "usageTracked": usageStore.trackedCount,
            "usageTotalPresses": usageStore.totalPresses,
            "favorites": usageStore.favorites.count,
            "dataFolder": usageStore.dataFolderURL.path,
            "windowTitles": NSApp.windows.filter(\.isVisible).map(\.title),
            "logCommand": "log show --last 10m --predicate 'subsystem == \"\(Bundle.main.bundleIdentifier ?? "")\"'"
        ]
        if let data = try? JSONEncoder().encode(settingsStore.settings),
           let object = try? JSONSerialization.jsonObject(with: data) {
            payload["settings"] = object
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}
