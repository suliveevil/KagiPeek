import AppKit
import SwiftUI

/// The screenshot fixture: `KAGIPEEK_PREVIEW=panel|search|settings|...` drives the app into a
/// named state, waits for it to settle and writes PNGs plus window frames to
/// `/tmp/kagipeek-shots`.
///
/// It is a fixture, not engine logic, and it does not belong in `ShortcutEngine.swift`: 250
/// lines of "take a picture of this state" made the class read as a screenshot tool with a
/// shortcut engine attached. Nothing here runs unless the environment variable is set.
///
/// It lives in `App/` rather than next to the engine for the same reason `AppDelegate` does:
/// it builds windows and SwiftUI views, and `Core/` must not know those types exist. An
/// extension can live in any file of the module, so the engine gains nothing from hosting it.
///
/// Deliberately not behind `#if DEBUG`: the screenshots are taken from the installed Release
/// build, which is the one users have.
///
/// Reading engine internals from here is what makes seven members `internal` instead of
/// `private` — `rebuildPanel`, `publishInputState`, `refreshSearch`, `recomputeConflicts`,
/// `reloadSystemHotkeys`, `panelSequence`, `panelPageSize`. Each says so where it is
/// declared, so the next reader does not mistake them for API.
/// Owns the fixture's settings window.
///
/// `ShortcutEngine` used to hold this `NSWindow`, and the reason was purely mechanical: the
/// fixture is an `extension ShortcutEngine`, and an extension cannot declare stored
/// properties. A window with `isReleasedWhenClosed = false` still needs one strong
/// reference, so that reference had to live somewhere, and the engine was the only place
/// an extension could put it.
///
/// That cost was invisible to both dependency checks: enumerating the types in `UI/` cannot
/// see `NSWindow`, and neither can type-checking `Core/` alone, because AppKit is available
/// to both. So "the engine no longer holds UI objects" was half true, and this is the half
/// that was left. An extension can still *own* one indirectly — this type sits in the same
/// file as the code that makes the window, so creation and retention are in one place and
/// the engine is out of it.
private final class PreviewWindowOwner {
    static let shared = PreviewWindowOwner()
    var window: NSWindow?
}

extension ShortcutEngine {
    // MARK: - Preview (screenshots)

    /// Debug helper driven by `KAGIPEEK_PREVIEW=overlay|overlay-held|overlay-chips|...`.
    /// Which settings tab a preview mode opens. Kept next to the preview switch so adding a
    /// mode is one line without touching the window setup.
    private static func previewSettingsTab(for mode: String) -> SettingsTab {
        switch mode {
        case "settings-ranking", "settings-statistics": return .statistics
        case "settings-trigger": return .trigger
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

    /// Screenshot runs must not depend on the machine's own settings or language. The
    /// overrides are in-memory only: writing them to settings.json is how a preview run
    /// used to leave the app speaking English.
    private func pinPreviewSettings() {
        settingsStore.beginPreviewSession()
        localization.update(preference: .english)
        // Fix the layout so the panel shows a full page instead of overflowing the screen
        // with someone's 60-row, three-column configuration.
        settingsStore.settings.language = .english
        settingsStore.settings.columnCount = 2
        // Screenshot runs default to two columns; the override exists so a capture can
        // exercise the three-column layout the panel now fills down.
        if let raw = ProcessInfo.processInfo.environment["KAGIPEEK_PREVIEW_COLUMNS"],
           let columns = Int(raw), (1...3).contains(columns) {
            settingsStore.settings.columnCount = columns
        }
        settingsStore.settings.maxItemsPerPage = 24
        settingsStore.settings.panelPlacement = .coverWindow
        // Pinned dark: the generated previews are compared by eye and by test, so they must
        // not change with the machine's appearance.
        settingsStore.settings.panelTheme = .dark
        settingsStore.settings.keyPosition = .right
        settingsStore.settings.showDisabledItems = false
        settingsStore.settings.sortMode = .smart
    }

    /// The built-in catalog plus the one row kind this build added: menu commands with no
    /// keyboard shortcut at all. Real menus are full of them — Safari's "Zoom" has no
    /// chord — and they sort after every chord: clickable, with a dash in the key column,
    /// and triggered by pressing the menu item itself.
    private func previewSampleItems() -> [BindingItem] {
        var items = BuiltInCatalog.items(language: .english).filter { $0.appBundleID == nil }
        items.append(contentsOf: [
            BindingItem(chord: .empty, title: "Zoom", group: ["Window"], source: .menu, appBundleID: "com.apple.Safari", axPath: "7,0,2"),
            BindingItem(chord: .empty, title: "Clear History…", group: ["Safari"], source: .menu, appBundleID: "com.apple.Safari", axPath: "0,0,6"),
            BindingItem(chord: .empty, title: "Block Pop-up Windows", group: ["Safari"], source: .menu, appBundleID: "com.apple.Safari", axPath: "0,0,9")
        ])
        return items
    }

    func startPreview(mode: String) {
        beginPreview()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        pinPreviewSettings()
        state.hasAccessibility = true
        state.hasInputMonitoring = true
        reloadSystemHotkeys()
        let items = previewSampleItems()
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
        recomputeConflicts(for: items)
        publishInputState()
        // The screenshot has no running apps to scan; show the sample set on the conflicts
        // page instead of an empty one.
        state.crossAppConflicts = state.conflicts.map { $0.scoped(to: $0.appBundleIDs.sorted().first) }

        switch mode {
        case "settings", "settings-trigger", "settings-ranking", "settings-statistics", "settings-conflicts", "settings-diagnostics", "settings-tall":
            // The ranking page is long; give the ranking variant room to show the conflicts block.
            let window = NSWindow(
                // Matches `SettingsView`'s minimum and the real window: the sidebar needs
                // the 40 pt the old 680-wide screenshot area never had.
                contentRect: NSRect(x: 0, y: 0, width: 720, height: Self.previewSettingsIsTall(mode) ? 1500 : 600),
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
                    .environment(state)
                    .environmentObject(settingsStore)
                    .environmentObject(usageStore)
                    .environmentObject(localization)
            )
            hosting.sizingOptions = []
            window.contentView = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            PreviewWindowOwner.shared.window = window
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
                Diag.info(.ui, "toggle: palette focus=\(self.paletteKeyFocusDescription)")
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
