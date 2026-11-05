import AppKit
import Combine
import CoreGraphics
import Foundation
import os

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
    /// Recording is edited in the settings window; its rules live in `RecordingPolicy` and
    /// the bookkeeping here.
    private lazy var bindingEditor = BindingEditor(
        state: state,
        settingsStore: settingsStore,
        onChange: { [weak self] in self?.applyHotkeySwallowing() }
    )
    /// Pressing a row's menu item, replaying its chord, and saying what happened.
    private lazy var rowRunner = RowRunner(
        state: state,
        catalogLoader: catalogLoader,
        usageStore: usageStore,
        localization: localization,
        presenters: presenters,
        frontmostBundleID: { [weak self] in self?.appContext.frontmost?.bundleID },
        injectionTargetForFrontmost: { [weak self] in
            guard let frontmost = self?.appContext.frontmost else { return nil }
            return InjectionTarget(processID: frontmost.pid, bundleID: frontmost.bundleID)
        },
        dismissPanel: { [weak self] in self?.dismissPanel() }
    )
    /// Scanning policy: whom to scan, which generation may publish, and which external
    /// sources feed the conflict list.
    private lazy var catalogCoordinator = CatalogCoordinator(
        state: state,
        catalogLoader: catalogLoader,
        appDirectory: appDirectory,
        localization: localization,
        presenters: presenters,
        isPreviewing: { [weak self] in self?.isPreviewing ?? false },
        frontmost: { [weak self] in self?.appContext.frontmost },
        dismissPanel: { [weak self] in self?.dismissPanel() },
        recomputeConflicts: { [weak self] items in self?.recomputeConflicts(for: items) },
        resetConflictOwnerFilter: { [weak self] in self?.conflicts.resetOwnerFilterIfGone() },
        publishInputState: { [weak self] in self?.publishInputState() },
        rebuildPanel: { [weak self] in self?.rebuildPanel() },
        refreshSearch: { [weak self] in self?.refreshSearch() }
    )
    /// The "test this shortcut" flow: listening, polling, and the verdict.
    private lazy var liveTest = LiveTestCoordinator(
        state: state,
        externalBindings: { [weak self] in self?.externalBindings ?? [] },
        ownerName: { [weak self] bundleID in self?.ownerName(forBundleID: bundleID) },
        dismissPanel: { [weak self] in self?.dismissPanel() },
        // No `assumeIsolated`: `onListeningChanged` is a plain (non-`Sendable`) closure owned
        // by the `@MainActor` `ShortcutTester`, so under main-actor default isolation both the
        // literal here and its two call sites are statically main-actor — the compiler is the
        // guarantee, not a runtime assertion.
        onListeningChanged: { [weak self] listening in
            self?.state.isTestingShortcut = listening
            self?.publishInputState()
        },
        appToRestore: { [weak self] in self?.lastExternalFrontmost }
    )
    /// The search palette's own session.
    private lazy var search = SearchSession(
        state: state,
        usageStore: usageStore,
        localization: localization,
        rowRunner: rowRunner,
        catalogCoordinator: catalogCoordinator,
        presenters: presenters,
        isStarted: { [weak self] in self?.isStarted ?? false },
        isPreviewing: { [weak self] in self?.isPreviewing ?? false },
        dismissPanel: { [weak self] in self?.dismissPanel() },
        activatePanel: { [weak self] in self?.activatePanel() },
        externalBindings: { [weak self] in self?.externalBindings ?? [] }
    )
    /// The panel's session: rows, ordering, paging, selection and row actions.
    private lazy var panel = PanelSession(
        state: state,
        usageStore: usageStore,
        localization: localization,
        presenters: presenters,
        rowRunner: rowRunner,
        isPreviewing: { [weak self] in self?.isPreviewing ?? false },
        frontmostName: { [weak self] in self?.appContext.frontmost?.name ?? "" },
        dismissPanel: { [weak self] in self?.dismissPanel() },
        dismissEverything: { [weak self] in self?.dismissEverything() },
        onCapturedKeysChanged: { [weak self] in self?.updateKeyCapture() },
        onInputStateChanged: { [weak self] in self?.publishInputState() }
    )
    /// The support report, built from visible state on demand.
    private lazy var diagnostics = DiagnosticsReporter(
        state: state,
        settingsStore: settingsStore,
        usageStore: usageStore,
        frontmostBundleID: { [weak self] in self?.appContext.frontmost?.bundleID }
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
    /// 切 Space 后同一前台 App 的重扫合并窗口。
    private var spaceRescanGate = SpaceRescanGate(interval: 0.75)
    /// `true` while one of the panel's context menus is tracking.
    ///
    /// SwiftUI's `contextMenu` is a real `NSMenu`, and while it tracks it owns the keyboard:
    /// Esc closes the menu, not the panel it was opened from. The engine's tap still sees
    /// that Esc, so the panel would otherwise close underneath the menu as well.
    private var menuBeginObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?
    private var isContextMenuTracking = false
    /// The Esc key-down that closed a context menu. Its key-up can arrive after the menu
    /// stopped tracking, and must not be mistaken for a fresh Esc aimed at the panel.
    private var contextMenuConsumedEscape = false
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
        if let menuBeginObserver {
            NotificationCenter.default.removeObserver(menuBeginObserver)
        }
        if let menuEndObserver {
            NotificationCenter.default.removeObserver(menuEndObserver)
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
                guard let self else { return }
                // 切 Space 会让菜单栏短暂消失，而前台 App 不一定变；只重扫当前这个 App，
                // 并让它在拿到空列表时保留旧目录（见 `CatalogPublishPolicy`）。
                let pid = self.frontmostProcessIdentifier
                guard self.spaceRescanGate.shouldScan(pid: pid, at: Date()) else { return }
                Diag.info(.scan, "space changed → forced rescan \(self.state.appName)")
                self.reloadCatalog(force: true, preserveOnEmpty: true)
            }
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }

        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isContextMenuTracking = true }
        }

        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isContextMenuTracking = false }
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

        if previous.modifierTriggerEnabled != newValue.modifierTriggerEnabled
            || previous.hotkeyTriggerEnabled != newValue.hotkeyTriggerEnabled
            || previous.triggerGesture != newValue.triggerGesture
            || previous.triggerKey != newValue.triggerKey {
            state.modifierDoubleTap = ModifierDoubleTap()
        }
        if previous.language != newValue.language {
            reloadSystemHotkeys()
            state.searchCorpus = nil
        }
        if previous.keyStyle != newValue.keyStyle {
            state.searchCorpus = nil
        }
        if previous.pagingPairs != newValue.pagingPairs {
            // The tap's swallow list is derived from the enabled pairs; without this the old
            // pair would keep being eaten and the new one would reach the app behind the panel.
            updateKeyCapture()
        }

        if previous.language != newValue.language
            || previous.includeBuiltInCatalog != newValue.includeBuiltInCatalog
            || previous.showAppleMenu != newValue.showAppleMenu {
            // All three change the shape or the labels of the scan, so the in-memory
            // snapshot and the disk entry (whose fingerprint covers these settings) are
            // stale. One reload covers whichever combination changed instead of scanning
            // twice when the language and the Apple menu move together.
            reloadCatalog(force: true)
        }
        if previous.excludedBundleIDs != newValue.excludedBundleIDs {
            catalogCoordinator.evaluateExclusion()
        }
        if previous.sortMode != newValue.sortMode
            || previous.showDisabledItems != newValue.showDisabledItems
            || previous.panelOrder != newValue.panelOrder
            || previous.ignoredCommands != newValue.ignoredCommands {
            state.orderedHitsCache = nil
        }
        // Turning the scanners off has to forget what they found, or the conflict list would
        // keep blaming tools the user just asked us to stop reading.
        if previous.scanConfigFiles != newValue.scanConfigFiles {
            scanConfigFiles()
        }
        // The panel carries no permanent mode label, so the change is announced once. Only
        // while the panel is up: editing the setting in the settings window would otherwise
        // flash a HUD behind it.
        if previous.panelOrder != newValue.panelOrder, state.panel.isVisible {
            showHUD(chord: "", title: localization.text(newValue.panelOrder.titleKey), kind: .info)
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
        if old.modifierTriggerEnabled != new.modifierTriggerEnabled { changed.append("modifierTriggerEnabled") }
        if old.hotkeyTriggerEnabled != new.hotkeyTriggerEnabled { changed.append("hotkeyTriggerEnabled") }
        if old.triggerGesture != new.triggerGesture { changed.append("triggerGesture") }
        if old.triggerKey != new.triggerKey { changed.append("triggerKey") }
        if old.holdDelay != new.holdDelay { changed.append("holdDelay") }
        if old.panelHotkey != new.panelHotkey { changed.append("panelHotkey") }
        if old.searchHotkey != new.searchHotkey { changed.append("searchHotkey") }
        if old.switchHotkey != new.switchHotkey { changed.append("switchHotkey") }
        if old.panelPlacement != new.panelPlacement { changed.append("panelPlacement") }
        if old.columnCount != new.columnCount { changed.append("columnCount") }
        if old.sortMode != new.sortMode { changed.append("sortMode") }
        if old.panelOrder != new.panelOrder { changed.append("panelOrder") }
        if old.showDisabledItems != new.showDisabledItems { changed.append("showDisabledItems") }
        if old.keyStyle != new.keyStyle { changed.append("keyStyle") }
        if old.language != new.language { changed.append("language") }
        if old.showAppleMenu != new.showAppleMenu { changed.append("showAppleMenu") }
        if old.includeBuiltInCatalog != new.includeBuiltInCatalog { changed.append("includeBuiltInCatalog") }
        if old.scanConfigFiles != new.scanConfigFiles { changed.append("scanConfigFiles") }
        if old.excludedBundleIDs != new.excludedBundleIDs { changed.append("excludedBundleIDs") }
        if old.ignoredCommands != new.ignoredCommands { changed.append("ignoredCommands") }
        if old.pagingPairs != new.pagingPairs {
            let enabled = PagingPair.allCases
                .filter(new.pagingPairs.contains)
                .map(\.rawValue)
                .joined(separator: ",")
            changed.append("pagingPairs=[\(enabled)]")
        }
        if old.diagnosticsEnabled != new.diagnosticsEnabled { changed.append("diagnosticsEnabled") }
        if old.verboseDiagnostics != new.verboseDiagnostics { changed.append("verboseDiagnostics") }
        guard !changed.isEmpty else { return }
        Diag.info(.settings, "changed: \(changed.joined(separator: ", "))")
    }

    /// Wipes every cached scan, memory and disk. Called after a settings reset, where the
    /// fingerprints alone cannot be trusted to catch everything that changed.
    func invalidateScanCaches() {
        catalogCoordinator.invalidateAll()
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
                catalogCoordinator.clearForIdentityChange()
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
                presenters.notices.showNotice(
                    text: localization.text(.errorEventTapStalledPermanent),
                    kind: .failure
                )
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
    func reloadCatalog(force: Bool = true, preserveOnEmpty: Bool = false) {
        catalogCoordinator.reload(force: force, preserveOnEmpty: preserveOnEmpty)
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
        catalogCoordinator.clearForIdentityChange()
        state.appName = app.name
        state.appIcon = app.icon
        catalogCoordinator.evaluateExclusion()
        // Not forced: switching apps is the moment the caches exist for. The identity
        // changed, so the in-memory snapshot misses anyway; the disk cache then gets its
        // chance to hand back the rows the user last saw for this app instead of a walk of
        // the whole menu bar. An explicit refresh (a settings
        // change, a permission grant) stays forced and always rescans.
        reloadCatalog(force: false)
        if state.search.isVisible { refreshSearch() }
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

        switch event.kind {
        case .interruption:
            state.modifierDoubleTap.cancel()
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

        // The trigger key is the only modifier whose press edges belong to the gesture; every
        // other modifier still narrows the panel when it is already open.
        let pressed = state.settings.modifierTriggerEnabled
            && state.settings.triggerKey.isPressed(keyCode: event.keyCode, modifiers: modifiers)

        if state.settings.modifierTriggerEnabled,
           state.settings.triggerGesture == .doubleTap,
           state.modifierDoubleTap.process(
               pressed: pressed,
               now: event.happenedAt,
               window: DoubleTapTiming.window(
                   systemDoubleClickInterval: NSEvent.doubleClickInterval
               )
           ) {
            // Both clicks of the gesture are triggers. If the second press is still down
            // when the panel opens, suppress narrowing until it is released.
            togglePinnedPanel(waitingForTriggerRelease: pressed)
            return
        }

        switch state.phase {
        case .active:
            narrowWithHeldModifiers(modifiers, previous: previous, event: event)
        case .idle, .armed:
            considerArming(pressed: pressed)
        }
    }

    /// Held or tapped modifiers while the panel is open: escape, latch, narrow.
    ///
    /// This is the which-key behaviour at the centre of the app — hold ⌘ and only the ⌘
    /// shortcuts are left — plus the two gestures layered on it: a lone hyper press closes
    /// the panel, and a quick tap ticks a modifier so ⌥ ⌘ C can be typed one key at a time.
    private func narrowWithHeldModifiers(_ modifiers: ModifierSet, previous: ModifierSet, event: KeyEvent) {
        // The press that opened the panel is a trigger, not a filter. Until that key is
        // released, a modifier event changes nothing; the release itself clears the flag
        // without rebuilding. The next press is an ordinary modifier and narrows.
        if state.panel.triggerNarrowPending {
            let triggerDown = state.settings.triggerKey.isPressed(
                keyCode: event.keyCode,
                modifiers: modifiers
            )
            switch TriggerNarrowGate.decision(
                waitingForRelease: true,
                triggerKeyDown: triggerDown
            ) {
            case .wait:
                return
            case .clearPending:
                state.panel.triggerNarrowPending = false
                state.panel.heldModifiers = []
                return
            case .narrow:
                break
            }
        }
        // A lone Shift is the hint layer: labels instead of chords, and Shift + glyph runs
        // the row. Anything else down with it is a real narrowing prefix, so the hints step
        // aside — the two would otherwise fight over the same glyph press. The tap reads the
        // flag through the published snapshot, so the flip is pushed before the rebuild.
        let hintsNow = modifiers == [.shift]
        if state.panel.shiftHintActive != hintsNow {
            state.panel.shiftHintActive = hintsNow
            publishInputState()
        }
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
        //
        // Only modifiers that went down on this edge become tokens: a press enqueues once
        // however long it is held, and a release changes nothing. Shift is the hint layer
        // and Globe has no filter chip, so neither becomes a token.
        let added = modifiers.subtracting(previous)
        for modifier in ModifierSet.canonicalOrder
        where modifier != .shift && added.contains(modifier) {
            state.panel.filter.toggleModifier(modifier)
        }
        state.panel.heldModifiers = state.panel.filter.modifiers
        // Keep the tap tracker's candidate in step, but a tap must not tick on release:
        // the press edge above already enqueued the token, and flipping it again here was
        // what would turn one press into "on, then off".
        _ = state.modifierTap.flagsChanged(
            modifiers == [.shift] ? ModifierSet() : modifiers,
            previous: previous,
            now: event.happenedAt,
            window: Self.modifierTapWindow
        )
        // The filter owns the narrowing. A prefix built from the same modifiers would
        // narrow a second time.
        state.prefix = .empty
        // An empty queue is the whole list again, so it starts at the first page. A
        // non-empty one keeps the page it had; the rebuild clamps an out-of-range index.
        if state.panel.filter.isEmpty {
            state.panel.pageIndex = 0
        }
        // Deliberately no `selectionIndex = -1` here. Narrowing is exactly the case where the
        // user is about to press Return, and a narrowed panel often has one row left: clearing
        // the selection here is what made Return do nothing.
        rebuildPanel()
        updateKeyCapture()
    }

    /// Hold-to-open, and the release that cancels it before the panel ever appears.
    ///
    /// `pressed` is the trigger key's state, so a different modifier being held — or the
    /// trigger being let go — ends the arm. The delay itself lives in `armShow`.
    private func considerArming(pressed: Bool) {
        guard state.settings.modifierTriggerEnabled, state.settings.triggerGesture == .hold else { return }
        if pressed {
            armShow()
            return
        }
        cancelArm()
        if state.phase == .armed {
            state.phase = .idle
            state.prefix = .empty
        }
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
        // An open context menu owns Esc: it closes that menu and leaves the panel open.
        if isContextMenuTracking, event.keyCode == KeyCode.escape {
            contextMenuConsumedEscape = true
            return
        }
        if event.keyCode == KeyCode.escape {
            // A fresh Esc starts a new decision; any earlier menu-owned Esc is over.
            contextMenuConsumedEscape = false
        }
        // A modifier-only double-tap candidate must not survive a real key press: ⌘C is a
        // chord, not half of a gesture.
        state.modifierDoubleTap.cancel()
        if PermissionCenter.isSecureInputEnabled {
            // Same restriction as in `handleModifiers`, reached by a different door: a key
            // pressed while secure input is on is not ours to act on, and the log says so.
            logSecureInputOnce()
            return
        }

        // The token queue answers before the router: a letter that the filter owns must not
        // become a chord stroke, and ⌫ while the queue is non-empty pops a token instead of
        // going up a level.
        switch PanelFilterPlan.decision(
            for: event,
            filter: state.panel.filter,
            phase: state.phase,
            shiftHintActive: state.panel.shiftHintActive,
            triggerPending: state.panel.triggerNarrowPending,
            triggerKey: state.settings.triggerKey
        ) {
        case .append(let character):
            noteGestureUse(.none, event: event)
            state.panel.filter.appendLetter(character)
            state.panel.heldModifiers = state.panel.filter.modifiers
            state.prefix = .empty
            rebuildPanel()
            updateKeyCapture()
            return
        case .popToken:
            noteGestureUse(.none, event: event)
            state.panel.filter.popLastToken()
            state.panel.heldModifiers = state.panel.filter.modifiers
            if state.panel.filter.isEmpty {
                state.panel.pageIndex = 0
            }
            rebuildPanel()
            updateKeyCapture()
            return
        case .none:
            break
        }

        let action = routeKeyDown(event)
        noteGestureUse(action, event: event)
        perform(action, event: event)
    }

    /// The decision is made in pure code (`KeyEventRouter`), exactly as the walk used to run:
    /// hotkeys first (they answer in any phase), then the phase, then the panel's own keys,
    /// then chord composition. `handleKeyDown` only executes what this returns.
    private func routeKeyDown(_ event: KeyEvent) -> KeyDownAction {
        // The Shift-hint layer answers before anything else: the typed glyph is not a chord
        // stroke, it is a row address, so it must not be offered to chord composition or to
        // the front app.
        if let hinted = shiftHintItem(for: event) {
            return .replayComposed(item: hinted, probe: hinted.chord)
        }
        return KeyEventRouter.route(
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

    /// The row a Shift + glyph press addresses, or nil when the hint layer is not in charge.
    ///
    /// Only the top level of the panel carries hints: one level down the rows are the
    /// continuations of a chord, and numbering them would answer a question the user did not
    /// ask. The search palette never reaches here — while it is visible the text field owns
    /// Shift, which is why the panel and the palette are separate surfaces.
    private func shiftHintItem(for event: KeyEvent) -> BindingItem? {
        guard state.phase == .active,
              state.panel.shiftHintActive,
              state.prefix.isEmpty,
              event.modifiers == [.shift],
              let raw = event.key?.raw,
              let index = ShiftHintLayer.index(forCharacter: raw) else { return nil }
        let sequence = panelSequence()
        guard index < sequence.count else { return nil }
        return sequence[index].hit.item
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
            panel.goUpOneLevel()
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
        if panel.popLatched() {
            panel.refreshAfterLatchedChange()
        } else if !state.prefix.isEmpty {
            panel.goUpOneLevel()
        }
    }

    /// Nothing was assembled: the physical event already *is* the shortcut, so the front app
    /// performs it. Flash the row and let the key through.
    private func passThrough(_ item: BindingItem, probe: KeyChord) {
        Diag.debug(.inject, """
            passthrough: chord=\(KeyFormatter.render(probe, style: .symbols)) \
            reason=uncomposed title=\(Sanitizer.clamp(item.title))
            """)
        panel.complete(item, probe: probe)
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
        Task { @MainActor in
            await ShortcutInjector.post(probe, delay: 0.12)
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
            // The context menu, not the panel, consumes the Esc that closes it. The menu may
            // already have stopped tracking by the time the key-up arrives.
            if contextMenuConsumedEscape {
                contextMenuConsumedEscape = false
                return
            }
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
            filter: state.panel.filter,
            runRowKey: state.settings.runRowKey,
            copyRowKey: state.settings.copyRowKey,
            pagingPairs: state.settings.pagingPairs,
            catalogItems: state.catalog.items,
            shiftHintsActive: state.panel.shiftHintActive
        )
        monitor.updateComposedSwallowState(snapshot)
    }

    /// Hotkeys are only swallowed while their switch is on and nothing is being recorded;
    /// otherwise the combinations reach the front app, which is the pause behaviour.
    private func applyHotkeySwallowing() {
        var rules: [SwallowRule] = []
        if state.recordingTarget == nil, state.settings.hotkeyTriggerEnabled {
            for spec in [state.settings.panelHotkey, state.settings.searchHotkey, state.settings.switchHotkey]
                .compactMap({ $0 }) {
                rules.append(SwallowRule(
                    keyCode: spec.keyCode,
                    modifiers: spec.modifiers,
                    tolerant: spec.modifiers.count >= 3
                ))
            }
        }
        monitor.updateSwallowRules(rules)
        applyTriggerSwallowing()
        refreshKeyDecoding()
    }

    /// Publishes the trigger key the tap owns, so the front app never sees the press that
    /// the gesture may consume. Nothing is swallowed while recording (the recorder needs the
    /// modifier) or while the gesture is switched off.
    private func applyTriggerSwallowing() {
        let keyCodes: Set<UInt16> = state.recordingTarget == nil
            && state.settings.modifierTriggerEnabled
            ? state.settings.triggerKey.swallowedKeyCodes
            : []
        monitor.updateModifierSwallow(keyCodes: keyCodes)
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
            self.activatePanel(waitingForTriggerRelease: true)
        }
    }

    private func cancelArm() {
        state.armedTask?.cancel()
        state.armedTask = nil
    }

    /// Opens the persistent panel. The keys used to trigger it are deliberately not used
    /// as a prefix, and the panel stays until a complete shortcut or Esc.
    ///
    /// Every trigger opens the full list. A hold-to-summon passes
    /// `waitingForTriggerRelease: true` so the still-down modifier cannot narrow until it
    /// has been released and pressed again; a hotkey or menu action passes `false`. In
    /// both cases the rows keep their full chord — a ⌘ that is held is lit up in the row,
    /// not removed from it.
    func activatePanel(waitingForTriggerRelease: Bool = false) {
        guard !state.isFrontAppExcluded else { return }
        state.search.isVisible = false
        cursorReturnPoint = Self.cursorPoint()
        state.phase = .active
        // Nothing is composed on open: the trigger press is not a filter, and a hotkey's
        // own modifiers are part of the hotkey rather than a prefix. The panel starts on
        // the whole list and narrows only on a later, separate press.
        state.prefix = .empty
        state.panel.isVisible = true
        state.panel.isPinned = true
        state.panel.beginNewSession()
        state.panel.triggerNarrowPending = waitingForTriggerRelease
        state.hyperEscape = HyperEscape()
        // A modifier held down to summon the panel is the trigger, not a tap: letting go of
        // it must not tick anything. It is also not a held filter, so the rows keep their
        // full chords instead of arriving narrowed.
        state.modifierTap.reset()
        state.panel.heldModifiers = []
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
        // The filter corpus is the biggest cache this session holds, and only a visible panel
        // can ask for it. The next open rebuilds it from whatever catalog is current.
        state.panelFilterCorpus = nil
        state.panelFilterCorpusKey = nil
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

    // MARK: - Panel session

    var panelPageSize: Int { panel.panelPageSize }
    var paletteKeyFocusDescription: String { presenters.panel.keyFocusDescription }
    func rebuildPanel() { panel.rebuildPanel() }
    func panelSequence() -> [PanelEntry] { panel.panelSequence() }
    func toggleFavoritesFilter() { panel.toggleFavoritesFilter() }
    func toggleToolSection() { panel.toggleToolSection() }
    func toggleModifier(_ modifier: ModifierSet) { panel.toggleModifier(modifier) }
    func toggleFavorite(rowID: String) { panel.toggleFavorite(rowID: rowID) }
    func copyShortcut(rowID: String) { panel.copyShortcut(rowID: rowID) }
    func copyMenuPath(rowID: String) { panel.copyMenuPath(rowID: rowID) }
    func copyRow(rowID: String) { panel.copyRow(rowID: rowID) }
    func showSettings() { panel.showSettings() }
    func showConflicts() { panel.showConflicts() }
    func nextPage() { panel.nextPage() }
    func previousPage() { panel.previousPage() }
    func moveSelection(_ delta: Int) { panel.moveSelection(delta) }
    func performSelectedPanelRow(action: RowAction) { panel.performSelectedPanelRow(action: action) }
    func performPanelRow(rowID: String, action: RowAction) { panel.performPanelRow(rowID: rowID, action: action) }
    func clickPanelRow(rowID: String) { panel.clickPanelRow(rowID: rowID) }
    func select(rowID: String) { panel.select(rowID: rowID) }
    func activate(rowID: String) { panel.activate(rowID: rowID) }

    private func updateKeyCapture() {
        var identifiers: Set<UInt32> = []
        var capturedKeyCodes: Set<UInt16> = []
        var activePagingCharacters: Set<Character> = []
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
            // The enabled punctuation pairs page through the list. The key codes describe
            // the physical spelling; the characters are published separately because a CJK
            // layout types `；` for the semicolon key.
            for pair in PagingPair.allCases where state.settings.pagingPairs.contains(pair) {
                capture(pair.previous.keyCode, pair.previous.modifiers)
                capture(pair.next.keyCode, pair.next.modifiers)
            }
            activePagingCharacters = PagingKeyPlan.characters(for: state.settings.pagingPairs)
            // Backspace only belongs to the panel while navigating a chord or while the
            // filter queue has a token to pop.
            if !state.prefix.isEmpty || !state.panel.filter.isEmpty {
                capture(KeyCode.delete, [])
            }
            // A bare `/` is the panel's own key: it opens the palette. Without capturing it
            // the app behind would also see it — in a browser that is "quick find", which
            // would then open on top of the palette that just opened.
            identifiers.insert(KeySwallowRules.identifier(keyCode: KeyCode.slash, modifiers: []))
        }
        monitor.updateCapturedKeys(identifiers)
        monitor.updateCapturedKeyCodes(capturedKeyCodes)
        monitor.updateCapturedCharacters(activePagingCharacters)
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
        catalogCoordinator.refreshRunningApps()
    }

    /// Command titles of a running app, for the ignored-command picker.
    ///
    /// Reads whatever is already cached — the frontmost catalog, or the disk cache behind
    /// `CatalogLoader` — instead of forcing a scan: the picker is a convenience, and making it
    /// pay for a full AX walk of a big app would be felt as a hang in Settings.
    func commandTitles(for app: AppEntry, completion: @escaping ([String]) -> Void) {
        catalogCoordinator.commandTitles(for: app, completion: completion)
    }

    /// Internal for `PreviewScenarios` (screenshot fixture). Not API: the engine calls it
    /// from `apply(settings:)`.
    func reloadSystemHotkeys() {
        catalogCoordinator.reloadSystemHotkeys()
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
        catalogCoordinator.scanConfigFiles()
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
        liveTest.start(for: chord)
    }

    func cancelLiveTest() {
        liveTest.cancel()
    }

    /// The verdict of a finished test for `chord`, or nil when no test of it has run.
    func liveTestVerdict(for chord: KeyChord) -> LiveTestVerdict? {
        liveTest.verdict(for: chord)
    }

    /// The combo the tester is currently busy with, so a row knows whether the countdown on
    /// screen belongs to it or to a different chord.
    var liveTestChord: KeyChord? { liveTest.chord }

    private func startLiveTestCountdown() {
        liveTest.startCountdown()
    }

    // MARK: - Search

    func showSearch() {
        search.showSearch()
    }

    func showSearchFromPanel() {
        search.showSearchFromPanel()
    }

    func returnToPanelFromSearch() {
        search.returnToPanelFromSearch()
    }

    func hideSearch() {
        search.hideSearch()
    }

    func toggleSearch() {
        search.toggleSearch()
    }

    func selectSearchResult(_ index: Int, scrollIntoView: Bool = true) {
        search.selectSearchResult(index, scrollIntoView: scrollIntoView)
    }

    func moveSearchSelection(_ delta: Int) {
        search.moveSearchSelection(delta)
    }

    func activateSearchResult(_ index: Int) {
        search.activateSearchResult(index)
    }

    func confirmSearchSelection() {
        search.confirmSearchSelection()
    }

    func selectSearchScope(_ appID: String?) {
        search.selectSearchScope(appID)
    }

    func makeSearchMarkdown() -> String {
        search.makeSearchMarkdown()
    }

    func refreshSearch() {
        search.refreshSearch()
    }

    // MARK: - Hotkey recording

    func beginRecording(_ target: HotkeyTarget) {
        dismissPanel()
        bindingEditor.begin(target)
    }

    func cancelRecording() {
        bindingEditor.cancel()
    }

    /// Removes a binding. The key then reaches the front app, and the recorder can record a
    /// replacement in the same slot.
    func clearBinding(_ target: HotkeyTarget) {
        bindingEditor.clear(target)
    }

    private func handleRecording(_ event: KeyEvent, target: HotkeyTarget) -> Bool {
        bindingEditor.handle(event, target: target)
    }

    // MARK: - Commands from the UI

    func togglePinnedPanel(waitingForTriggerRelease: Bool = false) {
        if state.panel.isVisible, state.phase == .active {
            dismissPanel()
            return
        }
        activatePanel(waitingForTriggerRelease: waitingForTriggerRelease)
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

    func showHUD(chord: String, title: String, kind: NoticeKind = .success) {
        presenters.notices.show(chord: chord, title: title, kind: kind)
    }

    // MARK: - Diagnostics

    /// One JSON report for a bug report: what the app can see, what it persisted, and the
    /// command that prints the matching log lines. Nothing is uploaded; the user saves the
    /// file and decides who gets it.
    ///
    /// Throws when the report itself cannot be serialized. The settings snapshot is the one
    /// exception: it is an enrichment, so a failure there is recorded *inside* the report
    /// (`settingsError`) rather than failing it — a report without settings is still worth
    /// attaching, but dropping the section in silence is how a broken encoder goes unnoticed.
    func diagnosticsReport() throws -> Data {
        try diagnostics.makeReport()
    }
}
