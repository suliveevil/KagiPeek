import AppKit
import os

/// Owns the menu bar item explicitly.
///
/// This used to be SwiftUI's `MenuBarExtra`, which is convenient but hands the item to the
/// system with no handle back: when macOS or a menu bar manager (Thaw, Ice, Bartender…) drops
/// or re-parents the item, the app cannot tell, and the icon is simply gone while the process
/// keeps running — exactly the failure this app kept hitting.
///
/// An `NSStatusItem` is a plain object we own. That buys three things:
/// * we can watch it, and rebuild it when its window disappears;
/// * the identity a menu bar manager records (bundle id + button description) is stable and
///   ours to set, instead of being decided inside a SwiftUI scene;
/// * a rebuilt item is a *new* item, which is also the cheapest way to make a manager
///   re-register one it has lost track of.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let engine: ShortcutEngine
    private var statusItem: NSStatusItem?
    private var healthTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Guards against a rebuild loop: a manager that keeps swallowing the item must not make
    /// the app re-create it on every tick.
    private var lastRebuildAt = Date.distantPast
    private static let rebuildCooldown: TimeInterval = 20

    init(engine: ShortcutEngine) {
        self.engine = engine
        super.init()
    }

    func install() {
        createItem()
        observeEnvironment()
        startHealthChecks()
        // One check shortly after launch, while the item is still being laid out: this is the
        // line that tells a future bug report whether the item is on screen at x=… or was
        // taken by a menu bar manager before the user ever saw it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.logPresence()
        }
    }

    private func logPresence() {
        guard let window = statusItem?.button?.window else {
            Diag.warning(.ui, "menu bar item has no window after launch: a menu bar manager may have taken it")
            return
        }
        let frame = window.frame
        if frame.width <= 0 || frame.maxX <= 0 {
            Diag.warning(.ui, "menu bar item is off-screen (x=\(Int(frame.origin.x)) w=\(Int(frame.width))): hidden by the system or a menu bar manager")
        } else {
            Diag.info(.ui, "menu bar item on screen at x=\(Int(frame.origin.x)) w=\(Int(frame.width))")
        }
    }

    func uninstall() {
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        healthTimer?.invalidate()
        healthTimer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Item

    private func createItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A stable autosave name is what lets the system (and managers that read it) keep the
        // item's position across launches. The bundle id changed case at some point, and an
        // item without a name of its own inherits that churn.
        item.autosaveName = "KagiPeekMenuBarItem"

        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon") ?? NSImage(
                systemSymbolName: "keyboard",
                accessibilityDescription: "KagiPeek"
            )
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            // The description is the identity a menu bar manager shows and records. Keeping
            // it constant across launches and languages keeps the recorded arrangement valid.
            button.setAccessibilityLabel("KagiPeek")
            button.toolTip = "KagiPeek"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        AppLog.ui.notice("status item created")
        Diag.info(.ui, "menu bar item created (autosave=KagiPeekMenuBarItem)")
    }

    /// Removes and re-creates the item. Used when the button has lost its window, which is
    /// what "the icon vanished" looks like from inside the app.
    private func rebuild(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastRebuildAt) > Self.rebuildCooldown else { return }
        lastRebuildAt = now
        Diag.warning(.ui, "menu bar item lost (\(reason)); rebuilding it")
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        createItem()
        // A manager that captured the old item needs to see the app ask for a place again.
        statusItem?.isVisible = true
    }

    // MARK: - Health

    private func observeEnvironment() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The system drops event taps across sleep; the icon can go with them.
                self?.revalidate(reason: "wake from sleep")
                self?.engine.handleWake()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidate(reason: "display change") }
        })
    }

    private func startHealthChecks() {
        // A minute is often enough to notice, rare enough to be free: the check is two
        // property reads, and the timer has a tolerance so it never wakes the CPU by itself.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidate(reason: "periodic check") }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    /// Rebuilds only when the item is genuinely gone. An item that a manager moved off-screen
    /// is still alive and deliberately hidden — fighting that would make the icon flicker.
    func revalidate(reason: String) {
        guard let statusItem else {
            rebuild(reason: "\(reason): no item")
            return
        }
        guard let button = statusItem.button else {
            rebuild(reason: "\(reason): no button")
            return
        }
        if button.window == nil {
            rebuild(reason: "\(reason): button has no window")
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(
            title: engine.state.appName.isEmpty ? engine.localization.text(.appName) : engine.state.appName,
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(entry(.menuSearch, symbol: "magnifyingglass", action: #selector(openSearch)))
        menu.addItem(entry(.menuPanel, symbol: "rectangle.on.rectangle", action: #selector(togglePanel)))

        if !engine.state.hasAccessibility {
            menu.addItem(entry(.permissionWizard, symbol: "lock.shield", action: #selector(openPermissions)))
        }

        menu.addItem(.separator())
        menu.addItem(entry(
            engine.state.isPaused ? .menuResume : .menuPause,
            symbol: engine.state.isPaused ? "play.circle" : "pause.circle",
            action: #selector(togglePaused)
        ))
        menu.addItem(entry(.menuSettings, symbol: "gearshape", action: #selector(openSettings)))

        menu.addItem(.separator())
        menu.addItem(entry(.menuQuit, symbol: "power", action: #selector(quit)))
    }

    private func entry(_ key: L10nKey, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(
            title: engine.localization.text(key),
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    // MARK: - Actions

    @objc private func openSearch() { engine.showSearch() }
    @objc private func togglePanel() { engine.togglePinnedPanel() }
    @objc private func openPermissions() { engine.showPermissionsWindow() }
    @objc private func togglePaused() { engine.togglePaused() }
    @objc private func openSettings() { engine.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
