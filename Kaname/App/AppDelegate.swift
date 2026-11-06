import AppKit
import Combine
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore: SettingsStore
    let usageStore: UsageStore
    /// The only place that knows which concrete windows exist. The engine asks for the
    /// protocols in `Core/Ports`; this is where they are built and handed over, in the one
    /// direction the dependency rule allows (App → Core).
    lazy var engine = ShortcutEngine(settingsStore: settingsStore, usageStore: usageStore) { engine in
        let settings = SettingsWindowController(engine: engine)
        return EnginePresenters(
            panel: SurfacePanelController(engine: engine),
            notices: HUDPanelController(),
            settings: settings,
            permissions: PermissionsWindowController(engine: engine) { [weak settings] in
                settings?.hostingWindow
            },
            guide: PermissionGuidePanelController()
        )
    }

    private var statusItemController: StatusItemController?
    private var backgroundActivity: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        // The crash handler is installed before the first store touches disk: reading
        // settings.json is the earliest point at which this process can die, and a crash
        // there would otherwise leave nothing behind at all.
        CrashReporter.install()
        settingsStore = SettingsStore()
        usageStore = UsageStore()
        super.init()

        Diag.configure(
            enabled: settingsStore.settings.diagnosticsEnabled,
            verbose: settingsStore.settings.verboseDiagnostics
        )
        // Reports what the previous session left behind, then writes this session's sentinel.
        CrashReporter.beginSession()
        Diag.info(.start, "launch \(DeviceInfo.summary)")
        // The redaction table is a security control, and `SanitizerRuleCompilationTests` keeps
        // it intact on every test pass — but a test cannot speak for a build already shipped.
        // Say it here, at every launch, because the two reports that also carry this are only
        // produced when someone thinks to ask for one.
        let failedRedactions = Sanitizer.failedPatterns
        if !failedRedactions.isEmpty {
            Diag.warning(.start, "redaction rules not applied: \(failedRedactions.joined(separator: ", "))")
        }
        // The language preference is the one setting whose effect is visible before any UI
        // exists, and "I set it to System but the app is in English" is a support question
        // that this line answers on its own.
        Diag.info(.start, """
            language preference=\(settingsStore.settings.language.rawValue) \
            resolved=\(L10n.resolvedLanguage(settingsStore.settings.language).rawValue) \
            preferred=\(Locale.preferredLanguages.first ?? "?")
            """)
    }

    /// The trigger is the one thing a new user cannot discover by looking at the menu bar.
    /// One HUD on first launch, never again; Settings keeps a button to replay it.
    private static let triggerTipShownKey = "KanameTriggerTipShown"

    private func showTriggerTipIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.triggerTipShownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.triggerTipShownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.engine.showHUD(
                chord: "⌘",
                title: self.engine.localization.text(.triggerTip),
                kind: .info
            )
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(settingsStore.settings.showDockIcon ? .regular : .accessory)

        // Diagnostic mode runs before the single-instance guard: the whole point is to ask
        // the *installed* copy what it can see, and that copy is usually already running.
        if ProcessInfo.processInfo.environment["KANAME_SELFTEST"] != nil {
            Diag.info(.start, "selftest mode")
            engine.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.writeSelfTestAndExit()
            }
            return
        }

        guard ensureSingleInstance() else { return }
        beginBackgroundActivity()

        // Headless export: `KANAME_EXPORT_DIAGNOSTICS=/path/to/report.zip` writes the same
        // archive the settings window produces and exits. It exists so a user can hand over
        // diagnostics from a terminal when the window is the thing that is broken.
        if let path = ProcessInfo.processInfo.environment["KANAME_EXPORT_DIAGNOSTICS"] {
            do {
                try DiagnosticsExporter.export(
                    to: URL(fileURLWithPath: path),
                    settings: settingsStore.settings
                )
                print("diagnostics written to \(path)")
            } catch {
                FileHandle.standardError.write(Data("diagnostics export failed: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
            return
        }

        settingsStore.syncLaunchAtLoginIfNeeded()
        let started = Date()
        engine.start()
        Diag.info(.start, "engine started in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        showTriggerTipIfNeeded()

        // The menu bar item is ours from here on: `StatusItemController` explains why it is
        // no longer a SwiftUI `MenuBarExtra`.
        // Headless rescan: `KANAME_RESCAN_CONFLICTS=1` runs the cross-app conflict scan and
        // leaves the process running, so a support session can produce conflicts-cache.json
        // without opening the settings window.
        if ProcessInfo.processInfo.environment["KANAME_RESCAN_CONFLICTS"] != nil {
            engine.rescanCrossAppConflicts()
        }

        let controller = StatusItemController(engine: engine)
        controller.install()
        statusItemController = controller
        observeDockIconPreference()
        installMainMenu()

        if let mode = ProcessInfo.processInfo.environment["KANAME_PREVIEW"] {
            Diag.info(.start, "preview mode: \(mode)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.engine.startPreview(mode: mode)
            }
        }
    }

    /// Diagnostic mode: reports what the installed app can actually see, then quits.
    ///
    /// The exit is unconditional and always flushes. It used to bail out early when the
    /// report could not be built — quitting without a word, and without flushing, which
    /// made a failed self-test look like a clean run.
    private func writeSelfTestAndExit() {
        do {
            let data = try engine.diagnosticsReport()
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("kaname-selftest.json")
            try data.write(to: url, options: [.atomic])
            Diag.info(.ui, "selftest written to \(url.path)")
        } catch {
            Diag.error(.ui, "selftest failed: \(error.localizedDescription)")
        }
        engine.stop()
        settingsStore.flush()
        usageStore.flush()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // First: the sentinel goes before anything that could block. A delete cannot hang, a
        // flush can, and a sentinel left behind turns every normal quit into a false
        // "unexpected exit" in the next session's log.
        CrashReporter.markCleanExit()
        if let backgroundActivity {
            ProcessInfo.processInfo.endActivity(backgroundActivity)
            self.backgroundActivity = nil
        }
        statusItemController?.uninstall()
        engine.stop()
        // A screenshot session edits settings in memory only; this puts the real ones back.
        settingsStore.endPreviewSession()
        // Both stores write on a debounce; a quit would otherwise drop the last edit.
        settingsStore.flush()
        usageStore.flush()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        engine.refreshPermissions()
    }

    /// Clicking the Dock icon (only present when the user asks for it) opens the settings
    /// window: an app with no windows would otherwise appear to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { engine.showSettings() }
        return true
    }

    // MARK: - Main menu

    /// A minimal main menu, because the app now has no SwiftUI scene to build one.
    ///
    /// Only the responder chain needs it: ⌘C/⌘V in the app's own text fields and ⌘Q/⌘W in its
    /// own windows are *menu items*, not window behaviour. An agent that shows a text field
    /// without an Edit menu silently loses copy and paste.
    private func installMainMenu() {
        let localization = engine.localization
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "\(localization.text(.aboutTitle)) Kaname",
            action: #selector(openAboutPanel),
            keyEquivalent: ""
        ).target = self
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(
            withTitle: localization.text(.menuSettings),
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        let searchItem = appMenu.addItem(
            withTitle: localization.text(.menuSearchShortcuts),
            action: #selector(openSearchFromMenu),
            keyEquivalent: "f"
        )
        searchItem.keyEquivalentModifierMask = [.command, .shift]
        searchItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: localization.text(.menuQuit),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: localization.text(.menuEdit))
        // Target stays nil: these travel the responder chain to whichever field has focus.
        editMenu.addItem(withTitle: localization.text(.menuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: localization.text(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: localization.text(.menuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: localization.text(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    @objc private func openSettingsFromMenu() { engine.showSettings() }
    @objc private func openSearchFromMenu() { engine.showSearch() }

    /// The About panel, with the same version line every other surface shows.
    ///
    /// macOS would otherwise fill it from `CFBundleShortVersionString` plus
    /// `CFBundleVersion` — the "2.2.0 (220)" spelling this change exists to retire. The
    /// build number stays in the bundle for Apple's checks; it is not what identifies
    /// the build to a person.
    @objc private func openAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationVersion: Bundle.main.kanameVersionDisplay,
            .version: ""
        ])
    }

    // MARK: - Background lifetime

    /// Keeps the process out of App Nap and out of the system's "nobody is looking, terminate
    /// me" heuristics.
    ///
    /// The event tap only does useful work while the app is alive, and an agent that naps is
    /// a menu bar icon that stops responding. `userInitiatedAllowingIdleSystemSleep` is the
    /// important choice here: the plain `userInitiated` option also disables idle sleep,
    /// which would keep the whole Mac awake for a shortcut helper.
    private func beginBackgroundActivity() {
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Kaname's event tap must stay responsive while it runs in the background"
        )
        Diag.info(.start, "background activity begun (App Nap disabled, idle sleep unaffected)")
    }

    // MARK: - Dock icon

    private func observeDockIconPreference() {
        settingsStore.$settings
            .map(\.showDockIcon)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] show in
                MainActor.assumeIsolated { self?.applyDockIconPreference(show) }
            }
            .store(in: &cancellables)
    }

    private func applyDockIconPreference(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        Diag.info(.ui, "activation policy: \(show ? "regular (Dock icon)" : "accessory (menu bar only)")")
        // Switching policy can take the status item down with it on some macOS builds; give
        // the system a moment, then check the item is still there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.statusItemController?.revalidate(reason: "activation policy change")
        }
    }

    private func ensureSingleInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != current }
        guard let existing = others.first else { return true }
        Diag.info(.start, "second instance terminated, activating pid=\(existing.processIdentifier)")
        existing.activate(options: [.activateAllWindows])
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return false
    }
}
