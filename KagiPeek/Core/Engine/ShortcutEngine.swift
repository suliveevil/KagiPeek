import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI
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
    /// The panel session phase, defined in pure code so `KeyEventRouter` can read it
    /// without importing the engine.
    typealias Phase = EnginePhase

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
    private lazy var surface = SurfacePanelController(engine: self)
    private lazy var hud = HUDPanelController()
    private lazy var permissionsWindow = PermissionsWindowController(engine: self)
    private lazy var settingsWindow = SettingsWindowController(engine: self)
    private lazy var shortcutTester = ShortcutTester(
        appToRestore: { [weak self] in self?.lastExternalFrontmost },
        onListeningChanged: { [weak self] listening in
            MainActor.assumeIsolated { self?.state.isTestingShortcut = listening }
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
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false
    private var isPreviewing = false
    private var previewWindow: NSWindow?
    /// The most recent app that was not KagiPeek, handed focus back to during a live test.
    private var lastExternalFrontmost: NSRunningApplication?

    var frontmostProcessIdentifier: pid_t { appContext.frontmost?.pid ?? 0 }

    // MARK: - Lifecycle

    init(settingsStore: SettingsStore, usageStore: UsageStore) {
        self.settingsStore = settingsStore
        self.usageStore = usageStore
        state.settings = settingsStore.settings
        localization.update(preference: settingsStore.settings.language)
        state.defaultTitle = localization.text(.appName)
        state.searchChangeHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSearch() }
        }

        permissions.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.permissionStateChanged() }
        }

        settingsStore.$settings
            .dropFirst()
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.apply(settings: value) }
            }
            .store(in: &cancellables)
    }

    deinit {
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
            self?.dismissPanel()
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

        permissions.startPolling()
        refreshPermissions()
        applyHotkeySwallowing()
        appDirectory.start()
        refreshRunningApps()
        reloadSystemHotkeys()
        // The stored cross-app scan, not a new one: one small file instead of fifteen menu
        // walks. A scan happens when the Conflicts page has nothing to show, or on request.
        loadCachedCrossAppConflicts()
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
        monitor.stop()
        appContext.stop()
        appDirectory.stop()
        permissions.stopPolling()
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
        permissions.refreshAll()
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
        } else if monitor.isActive {
            monitor.stop()
            state.isListening = false
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
        permissionsWindow.show()
    }


    func bringPermissionsWindowForward() {
        permissionsWindow.show()
    }

    private func startMonitor() {
        monitor.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        monitor.shouldSwallow = { [weak self] event in
            MainActor.assumeIsolated { self?.shouldSwallowComposed(event) ?? false }
        }
        do {
            try monitor.start()
            state.isListening = true
            state.statusMessage = nil
            AppLog.input.notice("event tap installed")
            Diag.info(.tap, "event tap installed (accessibility granted)")
        } catch {
            state.isListening = false
            state.statusMessage = error.localizedDescription
            AppLog.input.error("event tap failed: \(error.localizedDescription, privacy: .public)")
            // The one failure that makes every shortcut stop working at once. The file log
            // gets the domain and code, not just the localised sentence.
            let nsError = error as NSError
            Diag.error(.tap, "event tap failed: \(nsError.domain) code=\(nsError.code) — \(error.localizedDescription)")
            permissions.accessibility.startPolling()
        }
    }

    // MARK: - Catalog

    func reloadCatalog(force: Bool = true) {
        guard !isPreviewing else { return }
        guard let app = appContext.frontmost else { return }
        // KagiPeek is an accessory app that activates itself for the search palette, the
        // settings window. Scanning its own menu bar would replace the real
        // app's shortcuts with the built-in fallback, so it is never a catalog source.
        guard !app.isSelf else {
            AppLog.scan.debug("skipping own process as a catalog source")
            return
        }
        if state.panel.isVisible {
            state.panel.isScanning = true
            surface.presentPanel(state: state.panel, settings: state.settings)
        }
        // Scans run on a background queue with a concurrency of two, so a slow scan for the
        // previous app can finish after a fast one for the current app. Only the newest
        // request is allowed to publish.
        state.catalogGeneration &+= 1
        let generation = state.catalogGeneration
        catalogLoader.load(
            app: app,
            language: state.settings.language,
            includeBuiltIn: state.settings.includeBuiltInCatalog,
            showAppleMenu: state.settings.showAppleMenu,
            force: force
        ) { [weak self] snapshot in
            guard let self, !self.isPreviewing else { return }
            guard generation == self.state.catalogGeneration else {
                AppLog.scan.debug("dropping stale scan for \(snapshot.appIdentity, privacy: .public)")
                return
            }
            self.state.catalog = snapshot
            self.state.catalogSize = snapshot.items.count
            self.state.usedBuiltInCatalog = snapshot.usedBuiltInCatalog
            self.state.scanDuration = snapshot.readDuration
            self.state.scanState = snapshot.state
            self.state.conflicts = ConflictDetector.conflicts(in: snapshot.items, external: self.externalBindings)
            self.state.conflictIDs = Set(self.state.conflicts.flatMap { $0.items.map(\.id) })
            self.state.panel.isScanning = false
            self.state.searchCorpus = nil
            self.state.orderedHitsCache = nil
            self.evaluateExclusion()
            if self.state.panel.isVisible {
                self.rebuildPanel()
            }
            self.refreshSearch()
            AppLog.scan.info("""
                scanned \(snapshot.appIdentity, privacy: .public): \
                \(snapshot.items.count) items, menus \(snapshot.hasMenuBar), \
                built-in \(snapshot.usedBuiltInCatalog)
                """)
            // The file-log counterpart is what a user can actually send: same facts, but
            // written where a bug report can reach them.
            Diag.info(.scan, """
                scanned \(snapshot.appIdentity): \(snapshot.items.count) items, \
                menus=\(snapshot.hasMenuBar), built-in=\(snapshot.usedBuiltInCatalog), \
                state=\(snapshot.state.diagnosticCode), \(Int(snapshot.readDuration * 1000))ms
                """)
            if !snapshot.hasMenuBar, !snapshot.usedBuiltInCatalog {
                AppLog.scan.notice("no menu bar exposed and no fallback allowed: the panel will be empty")
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
        state.appName = app.name
        state.appIcon = app.icon
        evaluateExclusion()
        // Not forced: switching apps is the moment the caches exist for. The identity
        // changed, so the in-memory snapshot misses anyway; the disk cache then gets its
        // chance to hand back the rows the user last saw for this app instead of a walk of
        // the whole menu bar. An explicit refresh (a settings
        // change, a permission grant) stays forced and always rescans.
        reloadCatalog(force: false)
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
            // A lone hyper press (⌃⌥⇧⌘) is the user's "Escape" key: do not narrow the
            // panel to a prefix no menu could match; close it on a clean release instead.
            // The gesture is a pure state machine (`HyperEscape`), tested on its own.
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

            // Modifiers held while the panel is open narrow it, which-key style (the core
            // behaviour: hold ⌘ and only the ⌘ shortcuts are left). A lone ⇧ never counts —
            // it also arrives while typing capital letters.
            let held = modifiers == [.shift] ? ModifierSet() : modifiers
            state.panel.heldModifiers = held
            // A tap — press and let go quickly, with nothing typed in between — sticks: it
            // ticks the modifier instead of narrowing only while the finger is down, so
            // ⌥ ⌘ C can be typed one key at a time and each tap narrows on top of the last.
            // Holding still narrows temporarily. The difference is the point: holding is
            // looking, tapping is composing.
            if let tapped = state.modifierTap.flagsChanged(
                held,
                previous: previous,
                now: event.happenedAt,
                window: Self.modifierTapWindow
            ) {
                toggleLatched(tapped)
                return
            }
            // Only a modifier-only prefix is re-seeded. A real chord prefix (⌘K of ⌘K ⌘C)
            // must survive the modifier being released between strokes, which is what used
            // to drop the user back to the top level mid-chord.
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
            // Deliberately no `selectionIndex = -1` here. Narrowing is exactly the case where
            // the user is about to press Return, and a narrowed panel often has one row left:
            // clearing the selection here is what made Return do nothing.
            rebuildPanel()
            updateKeyCapture()
        case .idle, .armed:
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
        if PermissionCenter.isSecureInputEnabled {
            // Same restriction as in `handleModifiers`, reached by a different door: a key
            // pressed while secure input is on is not ours to act on, and the log says so.
            logSecureInputOnce()
            return
        }

        // The decision is made in pure code (`KeyEventRouter`), exactly as the walk used to
        // run: hotkeys first (they answer in any phase), then the phase, then the panel's
        // own keys, then chord composition. This method only executes side effects.
        let action = KeyEventRouter.route(
            keyCode: event.keyCode,
            key: event.key,
            modifiers: event.modifiers,
            isRepeat: event.isRepeat,
            phase: state.phase,
            settings: state.settings,
            panel: state.panel,
            prefix: state.prefix,
            pending: state.pending,
            items: state.catalog.items
        )

        // A key the panel consumed while a hyper is armed marks the hyper as used, so a
        // clean release no longer counts as Escape. The guard mirrors the old inline code:
        // only a key with a token, while the panel is active, and not Escape itself.
        if state.phase == .active, event.key != nil, action != .dismiss, state.hyperEscape.armedAt != nil {
            state.hyperEscape.noteKeyUsed()
        }
        // A key pressed while a modifier is down means the modifier was part of a shortcut,
        // not a tap to be ticked.
        if state.phase == .active {
            state.modifierTap.noteKeyPress()
        }

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
            cancelArm()
            state.phase = .idle
            state.prefix = .empty
        case .dismiss:
            dismissPanel()
        case .showSearch:
            showSearchFromPanel()
        case .moveSelection(let delta):
            moveSelection(delta)
        case .page(let step):
            if step > 0 { nextPage() } else { previousPage() }
        case .performRow(let rowAction):
            performSelectedPanelRow(action: rowAction)
        case .undoLatched:
            // The router answers from `latchedOrder`, so this usually pops; the fallback
            // keeps the old behaviour if the tick vanished in between.
            if popLatched() {
                refreshAfterLatchedChange()
            } else if !state.prefix.isEmpty {
                goUpOneLevel()
            }
        case .goUpLevel:
            goUpOneLevel()
        case .passThrough(let item, let probe):
            // Nothing was assembled: the physical event already *is* the shortcut, so the
            // front app performs it. Flash the row and let the key through.
            Diag.debug(.inject, """
                passthrough: chord=\(KeyFormatter.render(probe, style: .symbols)) \
                reason=uncomposed title=\(Sanitizer.clamp(item.title))
                """)
            complete(item, probe: probe)
        case .replayComposed(let item, let probe):
            // The tap swallowed this key, so the panel owes the app the shortcut: replay
            // the assembled chord — ⌥⌘C, not C — the same way clicking a row does.
            usageStore.record(usageKey: item.usageKey)
            dismissPanel()
            AppLog.input.info(
                "replaying composed \(KeyFormatter.render(probe, style: .symbols), privacy: .public) into the front app"
            )
            if state.settings.showExecutedHUD {
                hud.show(
                    chord: KeyFormatter.render(probe, style: state.settings.keyStyle),
                    title: item.title
                )
            }
            DispatchQueue.main.async {
                ShortcutInjector.post(probe, delay: 0.12)
            }
        case .descend(let probe):
            state.prefix = probe
            // The ticked modifiers have been folded into this stroke; keeping them would
            // apply them a second time to the next one.
            state.panel.latchedModifiers = []
            state.panel.latchedOrder = []
            state.panel.pageIndex = 0
            state.panel.selectionIndex = -1
            rebuildPanel()
            updateKeyCapture()
        case .noMatch(let heldModifiers):
            // Keep the panel open, and keep the ticks: the user is mid-sequence and has
            // not made a mistake yet. A bare key with no match is not swallowed, so the
            // app receives it and nothing is lost.
            Diag.debug(.tap, """
                nomatch: prefix=\(KeyFormatter.render(state.prefix, style: .symbols)) \
                key=\(event.key?.raw ?? "-") latched=\(state.panel.latchedModifiers.rawValue)
                """)
            state.panel.heldModifiers = heldModifiers
            rebuildPanel()
        }
    }
    /// Karabiner's "hyper tap → Escape" rule usually emits Escape on key-up, so the tap
    /// consumes Esc releases as well and closes the panel from either direction.
    private func handleKeyUp(_ event: KeyEvent) {
        guard state.phase == .active else { return }
        if event.keyCode == KeyCode.escape {
            dismissPanel()
        }
    }


    /// Whether the tap must consume this key because the panel supplied part of the chord.
    ///
    /// This runs for every key press of the session, so the cheap refusal comes first: no
    /// ticked modifiers means no composed stroke is possible and the answer is always no.
    /// Everything after that is `ChordComposition`'s decision — the same pure call the key
    /// handler makes, so the tap and the handler cannot disagree and run the shortcut twice.
    ///
    /// Two refusals come before that, both about keys the panel would consume as *itself*
    /// rather than as a stroke:
    ///
    /// - **⌫ while composing.** It undoes a tick, so the panel owns it. Letting it reach the
    ///   front app as well would delete a character the user never aimed at.
    /// - **navigation, paging, the row keys, `/` and Escape.** With a ticked modifier these
    ///   arrive carrying nothing, so `⌥;` is a real binding and the composition below would
    ///   swallow the `;` as its first stroke — while the engine pages the list. The tap reads
    ///   `PanelKeyIntake`, the same list the handler walks, so the two cannot diverge.
    private func shouldSwallowComposed(_ event: KeyEvent) -> Bool {
        guard !state.isTestingShortcut else { return false }
        guard !state.panel.latchedModifiers.isEmpty else { return false }
        guard state.panel.isVisible, state.phase == .active else { return false }
        guard let key = event.key else { return false }
        if event.modifiers.isEmpty, key == .backspace { return true }
        if PanelKeyIntake.isConsumedBeforeComposition(
            keyCode: event.keyCode,
            modifiers: event.modifiers,
            held: state.panel.heldModifiers,
            run: state.settings.runRowKey,
            copy: state.settings.copyRowKey
        ) { return false }
        let resolution = ChordComposition.resolve(
            prefix: state.prefix,
            physical: event.modifiers,
            pending: state.pending,
            key: key,
            in: state.catalog.items
        )
        return resolution.shouldSwallow
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
        state.panel.isScanning = state.catalog.items.isEmpty
        rebuildPanel()
        updateKeyCapture()
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
        surface.presentPanel(state: state.panel, settings: state.settings)
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
        surface.close()
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
    /// screen instead of sticking to the small-window row limit.
    private var panelPageSize: Int {
        guard state.settings.panelPlacement == .fillScreen, let screen = NSScreen.main else {
            return max(1, state.settings.maxItemsPerPage)
        }
        let columns = max(1, min(4, Int((screen.visibleFrame.width - Theme.padding * 2) / 300)))
        let usableRows = max(1, Int((screen.visibleFrame.height - 150) / Theme.rowHeight))
        return max(state.settings.maxItemsPerPage, columns * usableRows)
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
        // Both sections flow through the same pages, so the widest page is a full page of
        // rows and the system section contributes a heading rather than extra rows on the
        // last page. `OverlayMetrics` adds the heading height on top of the row budget.
        // Two cards, so two title strips: the app's always, the system's when it has rows.
        let headings = state.systemBindings.isEmpty ? 1 : 2
        guard total > 0 || headings > 0 else {
            // Nothing to size for yet (an app with no rows, or a scan still running): the
            // window falls back to the rows on screen instead of reserving a full page.
            state.rowBudgetCache = (key, 0, 0)
            return (0, 0)
        }
        state.rowBudgetCache = (key, pageSize, headings)
        return (pageSize, headings)
    }

    private func rebuildPanel() {
        guard state.panel.isVisible else { return }
        let sequence = panelSequence()
        let pageSize = panelPageSize
        let pageCount = max(1, Int(ceil(Double(sequence.count) / Double(pageSize))))
        let pageIndex = min(max(0, state.panel.pageIndex), pageCount - 1)
        let pageEntries = Array(sequence.dropFirst(pageIndex * pageSize).prefix(pageSize))
        let pageHits = pageEntries.map(\.hit)
        let highlighted = highlightedIDs(for: pageHits)
        let systemTitle = localization.text(.groupSystemHotkeys)
        // Both sections get a card, and a card needs a name: the app's own section is the one
        // the title bar names, so the same name heads it — with the count the title bar has
        // no room for.
        let sectionTitle = state.appName.isEmpty ? (appContext.frontmost?.name ?? "") : state.appName

        let specs: [PanelRowBuilder.Spec] = pageEntries.map { entry in
            let hit = entry.hit
            return PanelRowBuilder.Spec(
                id: hit.id,
                keySegments: keySegments(for: hit),
                title: DescriptionCleaner.truncate(hit.item.title, maxLength: state.settings.maxDescriptionLength),
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

        if isPreviewing {
            let systemRows = sequence.filter(\.isSystem).count
            Diag.info(.ui, "panel sequence: app=\(sequence.count - systemRows) system=\(systemRows) page=\(pageIndex + 1)/\(pageCount) rows=\(specs.count)")
        }

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
        state.panel.pageIndex = pageIndex
        state.panel.pageCount = pageCount
        state.panel.totalCount = sequence.count
        state.panel.appName = state.appName.isEmpty ? (appContext.frontmost?.name ?? "") : state.appName
        state.panel.hasConflicts = !state.conflicts.isEmpty
        state.panel.showsFavoritesOnly = state.showsFavoritesOnly
        state.panel.usedBuiltInCatalog = state.usedBuiltInCatalog
        state.panel.isPinned = state.phase == .active
        surface.presentPanel(state: state.panel, settings: state.settings)
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
    private func panelSequence() -> [PanelEntry] {
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
            return [KeyFormatter.Segment(kind: .key, text: KeyFormatter.noShortcutPlaceholder)]
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
            hud.show(chord: "!", title: localization.text(.panelNothingToCopy))
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
            hud.show(chord: "!", title: localization.text(.panelNothingToCopy))
            return
        }
        guard copyToPasteboard(text) else {
            hud.show(chord: "!", title: localization.text(.panelCopyFailed))
            return
        }
        hud.show(chord: text, title: localization.text(.panelCopied))
    }

    func showSettings() {
        dismissEverything()
        settingsWindow.show()
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
            AppLog.input.notice(
                "\(name, privacy: .public) key ignored: no row selected (index \(index), rows \(rows))"
            )
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
    func activate(rowID: String) {
        if let item = state.catalog.items.first(where: { $0.id == rowID }) {
            if !item.chord.isFinalStroke(after: state.prefix),
               let step = item.chord.step(after: state.prefix),
               let key = step.key {
                // Only a row with a level below it descends. A row showing the last stroke is
                // a complete shortcut as far as the user is concerned — it is drawn without a
                // chevron — so running it replays the whole chord.
                //
                // Descending a final stroke used to push the prefix onto the complete chord;
                // `hits` then dropped that row, because `nextKey(after:)` is nil once the
                // prefix is the whole chord. The panel emptied itself instead of running.
                AppLog.input.debug("descending one level for \(item.title, privacy: .public)")
                state.prefix = PrefixResolver.probe(after: state.prefix, modifiers: step.modifiers, key: key)
                state.panel.selectionIndex = -1
                state.panel.pageIndex = 0
                rebuildPanel()
                updateKeyCapture()
                return
            }
            guard item.isEnabled else {
                AppLog.input.notice("ignoring disabled row \(item.title, privacy: .public)")
                return
            }
            usageStore.record(usageKey: item.usageKey)
            dismissPanel()
            let rendered = KeyFormatter.render(item.chord, style: state.settings.keyStyle)
            // Triggering the command is the point, so the menu item itself is pressed
            // first: it works for commands that have no shortcut at all, and for the ones
            // that do it is exactly what clicking the menu would do. Replaying the chord is
            // the fallback — for a stale element, or an app that refuses the press.
            if let element = element(forRowID: rowID), MenuTrigger.press(element) {
                AppLog.input.info("pressed menu item \(item.title, privacy: .public)")
                Diag.action("panel.run", target: item.appBundleID ?? appContext.frontmost?.bundleID)
                Diag.debug(.run, "pressed menu item \(Sanitizer.clamp(item.title))")
                // The panel has to show the toast too: the setting
                // promises a confirmation and a run that vanishes without one reads as a failure.
                if state.settings.showExecutedHUD {
                    hud.show(
                        chord: item.chord.isEmpty ? KeyFormatter.noShortcutPlaceholder : rendered,
                        title: item.title
                    )
                }
                return
            }
            if item.chord.isEmpty {
                // No shortcut to replay either: the row is unreachable until the next scan.
                AppLog.input.error("""
                    menu press failed and \(item.title, privacy: .public) has no shortcut \
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
            AppLog.input.info("replaying \(KeyFormatter.render(item.chord, style: .symbols), privacy: .public) into the front app")
            Diag.debug(.run, """
                ax-press refused, replaying \(KeyFormatter.render(item.chord, style: .symbols)) \
                row=\(rowID) title=\(Sanitizer.clamp(item.title))
                """)
            Diag.action("panel.run.replay", target: item.appBundleID ?? appContext.frontmost?.bundleID)
            // The panel has to show the toast too: the setting
            // promises a confirmation and a run that vanishes without one reads as a failure.
            if state.settings.showExecutedHUD {
                hud.show(chord: rendered, title: item.title)
            }
            DispatchQueue.main.async {
                ShortcutInjector.post(item.chord, delay: 0.12)
            }
            return
        }
        if let system = state.systemBindings.first(where: { $0.id == rowID }) {
            usageStore.record(usageKey: system.usageKey)
            dismissPanel()
            AppLog.input.info("replaying system hotkey into the front app")
            if state.settings.showExecutedHUD {
                hud.show(chord: KeyFormatter.render(system.chord, style: state.settings.keyStyle), title: system.title)
            }
            DispatchQueue.main.async {
                ShortcutInjector.post(system.chord, delay: 0.12)
            }
            return
        }
        // Neither namespace knows this id. Reachable only if a row and the catalog disagree,
        // which used to present itself as "clicking does nothing".
        AppLog.input.error("row \(rowID, privacy: .public) is in neither the catalog nor the system hotkeys")
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
            AppLog.ui.error("pasteboard refused \(text.count, privacy: .public) characters")
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
                identifiers.insert(KeyboardMonitor.identifier(keyCode: keyCode, modifiers: modifiers))
                if !held.isEmpty {
                    identifiers.insert(
                        KeyboardMonitor.identifier(keyCode: keyCode, modifiers: modifiers.union(held))
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
            identifiers.insert(KeyboardMonitor.identifier(keyCode: KeyCode.slash, modifiers: []))
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
        catalogLoader.load(
            app: target,
            language: state.settings.language,
            includeBuiltIn: false,
            showAppleMenu: state.settings.showAppleMenu,
            force: false
        ) { snapshot in
            completion(snapshot.items.map(\.title))
        }
    }

    private func reloadSystemHotkeys() {
        state.systemBindings = SystemHotkeyReader.read(language: localization.language)
        if isPreviewing {
            // "Named" means the name table knew the chord; the rest render as an em dash, so
            // counting non-empty titles would report 79 of 79 named and tell us nothing.
            let named = state.systemBindings.filter { $0.title != DescriptionCleaner.placeholder }.count
            Diag.info(.ui, "system hotkeys: \(state.systemBindings.count) read, \(named) named, first: \(state.systemBindings.prefix(6).map { "\(KeyFormatter.render($0.chord, style: .symbols))=\($0.title)" }.joined(separator: " | "))")
        }
        state.searchCorpus = nil
        state.conflicts = ConflictDetector.conflicts(in: state.catalog.items, external: externalBindings)
        state.conflictIDs = Set(state.conflicts.flatMap { $0.items.map(\.id) })
        resetOwnerFilterIfGone()
    }

    /// A filter pointing at an owner that no longer appears would show an empty page with no
    /// explanation; fall back to "all" instead.
    private func resetOwnerFilterIfGone() {
        if state.conflictOwner != .all, !conflictOwnerOptions.contains(state.conflictOwner) {
            state.conflictOwner = .all
        }
        if let category = state.conflictCategory, !state.conflictTypeOptions.contains(where: { $0.category == category }) {
            state.conflictCategory = nil
        }
    }

    // MARK: - Cross-app conflicts

    /// Restores the stored scan. One small file, read once at launch — cheap, and it is the
    /// difference between a Conflicts page that opens instantly and one that scans fifteen
    /// apps every time.
    func loadCachedCrossAppConflicts() {
        guard state.crossAppConflicts.isEmpty, let payload = ConflictCache.load() else { return }
        state.crossAppConflicts = payload.conflicts
            .map { BindingConflict(id: $0.chordKey, chordKey: $0.chordKey, items: $0.items) }
            .map { $0.scoped(to: $0.appBundleIDs.sorted().first) }
        state.crossAppScannedAt = payload.scannedAt
        resetOwnerFilterIfGone()
    }

    /// The Conflicts page's entry point: show what is stored, and scan only if there is
    /// nothing to show yet.
    func prepareCrossAppConflicts() {
        loadCachedCrossAppConflicts()
        guard state.crossAppConflicts.isEmpty, !state.isScanningCrossApp else { return }
        rescanCrossAppConflicts()
    }

    /// Scans every running app's menus. User-initiated, or the first time the page is opened.
    ///
    /// Runs in the background and appends as it goes: the AX walk is already off the main
    /// thread, but grouping a 2 500-item catalog is not, and neither is redrawing a findings
    /// list of several hundred cards. The first is detached, the second is throttled to one
    /// publish a second — the page stays usable while it fills in.
    func rescanCrossAppConflicts() {
        state.crossAppRefreshTask?.cancel()
        let ownBundleID = Bundle.main.bundleIdentifier
        let apps = state.runningApps.filter { $0.bundleID != ownBundleID }
        guard !apps.isEmpty else { return }
        state.isScanningCrossApp = true
        lastCrossAppPublish = .distantPast
        state.crossAppRefreshTask = Task { [weak self] in
            guard let self else { return }
            let externals = self.externalBindings
            var builder = CrossAppConflictBuilder()
            builder.addGlobal(await Self.detectConflicts(in: [], externals: externals))
            for app in apps {
                if Task.isCancelled {
                    self.state.isScanningCrossApp = false
                    return
                }
                let items = await self.catalogItems(for: app)
                if Task.isCancelled {
                    self.state.isScanningCrossApp = false
                    return
                }
                builder.add(await Self.detectConflicts(in: items, externals: externals), keepingAppsOnly: true)
                self.publishIfDue(builder.sorted())
            }
            let scannedAt = Date()
            self.state.crossAppConflicts = builder.sorted()
            self.state.crossAppScannedAt = scannedAt
            self.state.isScanningCrossApp = false
            self.resetOwnerFilterIfGone()
            ConflictCache.save(self.state.crossAppConflicts, at: scannedAt)
            let owners = Set(self.state.crossAppConflicts.flatMap(\.appBundleIDs)).count
            Diag.info(.scan, "cross-app scan: \(self.state.crossAppConflicts.count) findings across \(owners) app(s)")
        }
    }

    private var lastCrossAppPublish = Date.distantPast

    /// At most one publish a second. Every publish redraws the findings list, and sixteen
    /// redraws of a few hundred cards is exactly the stall this is meant to avoid.
    private func publishIfDue(_ conflicts: [BindingConflict]) {
        let now = Date()
        guard now.timeIntervalSince(lastCrossAppPublish) >= 1 else { return }
        lastCrossAppPublish = now
        state.crossAppConflicts = conflicts
    }

    /// Conflict detection over one app's catalog, off the main thread.
    private nonisolated static func detectConflicts(
        in items: [BindingItem],
        externals: [BindingItem]
    ) async -> [BindingConflict] {
        await Task.detached(priority: .utility) {
            ConflictDetector.conflicts(in: items, external: externals)
        }.value
    }

    /// Rescans every running app's menus for the Conflicts page.
    ///
    /// Cache-first on purpose: a page that shows what was already read, then quietly fills
    /// in the rest, is worth more than a spinner. Results are published per app, so a slow
    /// app does not hold back the other nine.
    func refreshCrossAppConflicts() {
        state.crossAppRefreshTask?.cancel()
        let ownBundleID = Bundle.main.bundleIdentifier
        let apps = state.runningApps.filter { $0.bundleID != ownBundleID }
        guard !apps.isEmpty else { return }
        state.crossAppRefreshTask = Task { [weak self] in
            guard let self else { return }
            var builder = CrossAppConflictBuilder()
            builder.addGlobal(ConflictDetector.conflicts(in: [], external: self.externalBindings))
            for app in apps {
                if Task.isCancelled { return }
                let items = await self.catalogItems(for: app)
                if Task.isCancelled { return }
                builder.add(
                    ConflictDetector.conflicts(in: items, external: self.externalBindings),
                    keepingAppsOnly: true
                )
                self.state.crossAppConflicts = builder.sorted()
            }
            self.resetOwnerFilterIfGone()
            Diag.info(.scan, "cross-app conflicts: \(self.state.crossAppConflicts.count) findings across \(apps.count) apps")
        }
    }

    /// Catalog of one running app, cache first (`force: false`).
    private func catalogItems(for app: AppEntry) async -> [BindingItem] {
        await withCheckedContinuation { continuation in
            catalogLoader.load(
                app: FrontmostApp(pid: app.pid, bundleID: app.bundleID, name: app.name, icon: app.icon),
                language: state.settings.language,
                includeBuiltIn: false,
                showAppleMenu: state.settings.showAppleMenu,
                force: false
            ) { snapshot in
                continuation.resume(returning: snapshot.items)
            }
        }
    }

    /// Collects conflicts from several apps, keeping the ids unique and the list ordered.
    private struct CrossAppConflictBuilder {
        private var conflicts: [BindingConflict] = []
        private var seen = Set<String>()

        /// Global findings (no app in them) belong here exactly once.
        mutating func addGlobal(_ items: [BindingConflict]) {
            for conflict in items where conflict.isGlobalOnly {
                insert(conflict.scoped(to: nil))
            }
        }

        /// Per-app findings: the ones where that app's menus take part. Global ones are
        /// already in the list and would otherwise repeat once per app.
        mutating func add(_ items: [BindingConflict], keepingAppsOnly: Bool) {
            for conflict in items {
                if keepingAppsOnly, conflict.isGlobalOnly { continue }
                insert(conflict.scoped(to: conflict.appBundleIDs.sorted().first))
            }
        }

        private mutating func insert(_ conflict: BindingConflict) {
            guard seen.insert(conflict.id).inserted else { return }
            conflicts.append(conflict)
        }

        func sorted() -> [BindingConflict] {
            conflicts.sorted { lhs, rhs in
                if lhs.category != rhs.category { return lhs.category > rhs.category }
                if lhs.ownerCount != rhs.ownerCount { return lhs.ownerCount > rhs.ownerCount }
                return lhs.chordKey < rhs.chordKey
            }
        }
    }

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
        let enabled = state.settings.scanConfigFiles
        // The scan itself is the only part that leaves the main actor, and it takes nothing
        // but a Bool across: keeping `self` out of the detached closure is what lets the
        // result come back on the main actor without a data race to reason about.
        state.configScanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                enabled ? ConfigFileScanner.scan() : ConfigScanResult()
            }.value
            self?.applyConfigScan(result)
        }
    }

    private func applyConfigScan(_ result: ConfigScanResult) {
        guard !isPreviewing else { return }
        state.configScan = result
        state.configBindings = result.items
        state.searchCorpus = nil
        state.conflicts = ConflictDetector.conflicts(in: state.catalog.items, external: externalBindings)
        state.conflictIDs = Set(state.conflicts.flatMap { $0.items.map(\.id) })
        resetOwnerFilterIfGone()
        AppLog.scan.info("config scan: \(result.totalCount) shortcuts")
    }

    /// Owners that actually appear in the current conflicts, for the filter picker.
    ///
    /// Built from the findings rather than from the installed apps: a picker listing every
    /// app on the Mac would be mostly empty answers.
    var conflictOwnerOptions: [ConflictOwnerFilter] {
        var apps = Set<String>()
        var hasGlobal = false
        for conflict in state.crossAppConflicts {
            if conflict.isGlobalOnly { hasGlobal = true }
            apps.formUnion(conflict.appBundleIDs)
        }
        var options: [ConflictOwnerFilter] = [.all]
        if hasGlobal { options.append(.global) }
        let sorted = apps.sorted { lhs, rhs in
            let left = ownerName(forBundleID: lhs) ?? lhs
            let right = ownerName(forBundleID: rhs) ?? rhs
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
        options.append(contentsOf: sorted.map { ConflictOwnerFilter.app($0) })
        return options
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
        if item.appBundleID == nil { return item.appBundleID ?? "" }
        return state.appName.isEmpty ? (item.appBundleID ?? item.title) : state.appName
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

    /// Mirrors the tester's countdown into published state so the UI can tick down.
    func refreshLiveTestState() {
        state.liveTestState = shortcutTester.state
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
        surface.closeSearch()
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
        state.searchFocusToken += 1
        refreshSearch()
        state.search.isVisible = true
        surface.presentSearch()
    }

    func hideSearch() {
        state.search.isVisible = false
        surface.closeSearch()
    }

    func toggleSearch() {
        if state.search.isVisible {
            hideSearch()
        } else {
            showSearch()
        }
    }

    func selectSearchResult(_ index: Int) {
        guard state.search.results.indices.contains(index) else { return }
        state.search.selection = index
    }

    func moveSearchSelection(_ delta: Int) {
        guard !state.search.results.isEmpty else { return }
        let next = state.search.selection + delta
        state.search.selection = min(max(0, next), state.search.results.count - 1)
    }

    /// Click in the search palette: close it, return to the previous app and replay the
    /// shortcut there.
    func activateSearchResult(_ index: Int) {
        guard state.search.results.indices.contains(index) else { return }
        let item = state.search.results[index]
        // With a scope, the app to run in is the one being searched — it is usually *not* in
        // front, because the palette took the keyboard from whatever was.
        let scoped = state.searchScopeProcessID.flatMap { NSRunningApplication(processIdentifier: $0) }
        let target = scoped ?? surface.searchTargetApplication ?? NSWorkspace.shared.frontmostApplication
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
        // Pressing the menu item is the primary trigger, exactly as in the panel and the
        // search: it reaches commands that have no shortcut at all. The palette gives no
        // confirmation either way, so the HUD stays out of this path.
        if let element = element(forRowID: item.id), MenuTrigger.press(element) {
            AppLog.input.info("pressed menu item \(item.title, privacy: .public) from search")
            Diag.action("search.run", target: item.appBundleID ?? appContext.frontmost?.bundleID)
            DispatchQueue.main.async { target?.activate() }
            usageStore.record(usageKey: item.usageKey)
            return
        }
        guard !item.chord.isEmpty else {
            AppLog.input.error("""
                menu press failed and \(item.title, privacy: .public) has no shortcut \
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
            refreshSearch()
            return
        }
        state.search.scopeName = app.name
        state.searchScopeIcon = app.icon
        state.searchScopeProcessID = app.pid
        refreshSearch()
        // Cache first: switching scope should feel like flipping a page, not like a scan.
        catalogLoader.load(
            app: FrontmostApp(pid: app.pid, bundleID: app.bundleID, name: app.name, icon: app.icon),
            language: state.settings.language,
            includeBuiltIn: false,
            showAppleMenu: state.settings.showAppleMenu,
            force: false
        ) { [weak self] snapshot in
            guard let self, self.state.search.scopeAppID == appID else { return }
            self.state.search.scopeItems = snapshot.items
            self.state.searchScopeCatalog = snapshot
            self.state.searchCorpus = nil
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

    private func refreshSearch() {
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
        var results = (state.searchCorpus?.search(state.search.query, limit: isEmptyQuery ? 400 : 60) ?? [])
            .filter { !isIgnored($0) }
        if !favoritesPolicy.canBeFiltered,
           !state.search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let existing = Set(results.map(\.id))
            let favorites = searchItems.filter {
                usageStore.isFavorite($0.usageKey) && !isIgnored($0) && !existing.contains($0.id)
            }
            results.append(contentsOf: favorites)
        }
        results = favoritesPolicy.pinningFavoritesFirst(results) { usageStore.isFavorite($0.usageKey) }
        state.search.results = results
        // The first match is always selected.
        state.search.selection = 0
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
        hud.show(chord: chord, title: title)
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

    // MARK: - Preview (screenshots)

    /// Debug helper driven by `KAGIPEEK_PREVIEW=overlay|overlay-held|overlay-chips|...`.
    /// Which settings tab a preview mode opens. Kept next to the preview switch so adding a
    /// mode is one line without touching the window setup.
    private static func previewSettingsTab(for mode: String) -> SettingsTab {
        switch mode {
        case "settings-ranking", "settings-statistics": return .statistics
        case "settings-conflicts": return .conflicts
        case "settings-diagnostics": return .diagnostics
        default: return .general
        }
    }

    /// Some panes (statistics, conflicts, and General once its lists are populated) are taller
    /// than the default preview window, and a screenshot only sees what is laid out.
    private static func previewSettingsIsTall(_ mode: String) -> Bool {
        ["settings-ranking", "settings-statistics", "settings-conflicts", "settings-tall"].contains(mode)
    }

    func startPreview(mode: String) {
        isPreviewing = true
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // English is fixed for documentation screenshots, but only in memory: writing it to
        // settings.json is how a preview run used to leave the app speaking English.
        settingsStore.beginPreviewSession()
        localization.update(preference: .english)
        // Documentation screenshots must not depend on the settings of the machine that took
        // them: fix the layout so the panel shows a full page instead of overflowing the
        // screen with someone's 60-row, three-column configuration.
        settingsStore.settings.language = .english
        settingsStore.settings.columnCount = 2
        settingsStore.settings.maxItemsPerPage = 24
        settingsStore.settings.panelPlacement = .coverWindow
        settingsStore.settings.panelTheme = .graphite
        settingsStore.settings.keyPosition = .right
        settingsStore.settings.showDisabledItems = false
        settingsStore.settings.sortMode = .smart
        // The screenshot host may not have granted Accessibility to a binary launched from a
        // shell; the banner it would draw is not what the window looks like in normal use.
        state.hasAccessibility = true
        state.hasInputMonitoring = true
        reloadSystemHotkeys()
        var items = BuiltInCatalog.items(language: .english).filter { $0.appBundleID == nil }
        // The screenshots have to show the row kind this build added: a menu command with
        // no keyboard shortcut at all. Real menus are full of them — Safari's "Zoom" has
        // no chord — and they sort after every chord: clickable, with a dash in the key
        // column, and triggered by pressing the menu item itself.
        items.append(contentsOf: [
            BindingItem(
                chord: .empty,
                title: "Zoom",
                group: ["Window"],
                source: .menu,
                appBundleID: "com.apple.Safari",
                axPath: "7,0,2"
            ),
            BindingItem(
                chord: .empty,
                title: "Clear History…",
                group: ["Safari"],
                source: .menu,
                appBundleID: "com.apple.Safari",
                axPath: "0,0,6"
            ),
            BindingItem(
                chord: .empty,
                title: "Block Pop-up Windows",
                group: ["Safari"],
                source: .menu,
                appBundleID: "com.apple.Safari",
                axPath: "0,0,9"
            )
        ])
        state.appName = "Safari"
        state.appIcon = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
        state.catalog = CatalogSnapshot(
            items: items,
            elements: [:],
            hasMenuBar: true,
            scannedAt: Date(),
            appIdentity: "preview",
            state: .ok,
            usedBuiltInCatalog: false
        )
        state.catalogSize = items.count
        state.conflicts = ConflictDetector.conflicts(in: items, external: externalBindings)
        state.conflictIDs = Set(state.conflicts.flatMap { $0.items.map(\.id) })
        // The screenshot has no running apps to scan; show the sample set on the conflicts
        // page instead of an empty one.
        state.crossAppConflicts = state.conflicts.map { $0.scoped(to: $0.appBundleIDs.sorted().first) }

        switch mode {
        case "settings", "settings-ranking", "settings-statistics", "settings-conflicts", "settings-diagnostics", "settings-tall":
            // The ranking page is long; give the ranking variant room to show the conflicts block.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: Self.previewSettingsIsTall(mode) ? 1500 : 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "KagiPeek Settings"
            // A hosting view with sizingOptions resizes the window to its fitting size
            // (600), overriding the contentRect; keep the requested size.
            let hosting = NSHostingView(
                rootView: SettingsView(initialTab: Self.previewSettingsTab(for: mode))
                    .environmentObject(self)
                    .environmentObject(state)
                    .environmentObject(settingsStore)
                    .environmentObject(usageStore)
                    .environmentObject(localization)
            )
            hosting.sizingOptions = []
            window.contentView = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            previewWindow = window
        case "permissions":
            showPermissionsWindow()
        case "panel":
            // Documents the panel after the header lost its search box: identity, chips and
            // actions only, with `/` as the way into the palette.
            activatePanel()
        case "overlay-narrow":
            // Documents the narrow end of the responsive title bar: one column, 300 pt wide.
            settingsStore.settings.columnCount = 1
            settingsStore.settings.panelPlacement = .fixedSize
            settingsStore.settings.fixedPanelWidth = 300
            settingsStore.settings.fixedPanelHeight = 620
            activatePanel()
        case "overlay-held":
            // Documents the narrowed state: ⌘ is down, so only the ⌘ shortcuts are left and
            // their ⌘ glyph is lit rather than stripped from the chord.
            activatePanel()
            state.panel.heldModifiers = [.command]
            state.prefix = .modifiers([.command])
            rebuildPanel()
        case "overlay-chips":
            // Documents the title bar's modifier chips: ⌘ and ⇧ ticked.
            activatePanel()
            toggleModifier(.command)
            toggleModifier(.shift)
        case "overlay-latch":
            // Documents the Emacs-style sequence: ⌥ and ⌘ ticked in the title bar rather
            // than held, so the panel has already narrowed to the ⌥⌘ shortcuts and the
            // next key press completes one of them (⌥⌘C typed as "click ⌥, click ⌘, press C").
            activatePanel()
            toggleModifier(.option)
            toggleModifier(.command)
        case "overlay-noshortcut":
            // Documents the other end of the list: commands with no keyboard shortcut at
            // all. They sort after every chord, so this mode jumps to the last page —
            // clickable rows with a dash in the key column, triggered by pressing the
            // menu item itself rather than by typing.
            activatePanel()
            state.panel.pageIndex = max(0, state.panel.pageCount - 1)
            rebuildPanel()
        case "overlay-system":
            // Documents the boundary between the app's section and the system's: the last page
            // has the system heading and only system rows. Waits for the scan, because the page
            // count is only known once the catalog is in.
            activatePanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                // Jump to the page that holds the boundary itself, not to the last page: the
                // heading is what this screenshot is about.
                let boundary = PanelSections.boundary(in: self.panelSequence()) ?? 0
                self.state.panel.pageIndex = boundary / self.panelPageSize
                self.rebuildPanel()
            }
        case "panel-search":
            // Documents the `/` round trip and proves it in the log: the panel opens the
            // palette with the query it was left with, `/` again comes back, and a second
            // `/` lands on the same search rather than an empty one.
            activatePanel()
            state.search.query = "copy"
            refreshSearch()
            let firstCount = state.search.results.count
            showSearchFromPanel()
            Diag.info(.ui, """
                toggle: panel->search visible=\(state.search.isVisible) query=\(Sanitizer.clamp(state.search.query)) \
                results=\(state.search.results.count)
                """)
            returnToPanelFromSearch()
            Diag.info(.ui, "toggle: search->panel visible=\(state.panel.isVisible) searchVisible=\(state.search.isVisible)")
            showSearchFromPanel()
            Diag.info(.ui, """
                toggle: reopened query=\(Sanitizer.clamp(state.search.query)) \
                results=\(state.search.results.count) first=\(Sanitizer.clamp(state.search.results.first?.title ?? "-")) \
                before=\(firstCount)
                """)
            // The palette must recognise its own field, or `/` would bounce straight back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                Diag.info(.ui, "toggle: palette focus=\(self.surface.keyFocusDescription)")
            }
        case "search-scoped":
            // Documents the scoped palette: the title, icon and list belong to the chosen app,
            // not to the one that happened to be in front.
            showSearch()
            if let app = state.runningApps.first(where: { $0.bundleID != Bundle.main.bundleIdentifier }) {
                selectSearchScope(app.id)
            }
            state.search.query = ""
        case "search":
            showSearch()
            state.search.query = ProcessInfo.processInfo.environment["KAGIPEEK_PREVIEW_QUERY"] ?? "copy"
        default:
            activatePanel()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.writePreviewArtifacts(mode: mode)
        }
    }

    private func writePreviewArtifacts(mode: String) {
        let directory = URL(fileURLWithPath: "/tmp/kagipeek-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var index = 0
        for window in NSApp.windows where window.isVisible {
            guard let view = window.contentView, view.bounds.width > 50, view.bounds.height > 50 else { continue }
            let name = mode + "-" + String(index)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent(name + ".png"))
            }
            let meta = [
                "name": name,
                "title": window.title,
                "width": Int(view.bounds.width),
                "height": Int(view.bounds.height),
                "level": Int(window.level.rawValue)
            ] as [String: Any]
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
                try? data.write(to: directory.appendingPathComponent(name + ".json"))
            }
            index += 1
        }
        writePreviewWindowFrames()
    }

    private func writePreviewWindowFrames() {
        let windows: [[String: Any]] = NSApp.windows
            .filter { $0.isVisible }
            .map { ["title": $0.title, "frame": NSStringFromRect($0.frame), "level": $0.level.rawValue] }
        let screen = NSScreen.main
        let payload: [String: Any] = [
            "windows": windows,
            "screenHeight": screen?.frame.height ?? 0,
            "screenWidth": screen?.frame.width ?? 0,
            "scale": screen?.backingScaleFactor ?? 1
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/kagipeek-preview.json"))
    }
}
