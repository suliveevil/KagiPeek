import AppKit

struct FrontmostApp {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?

    var identity: String { bundleID ?? "pid:\(pid)" }

    /// True for KagiPeek itself. The app activates itself for the search palette, the
    /// Settings window, and a menu bar agent has no menu bar of its own — so
    /// treating itself as a shortcut source would empty the panel.
    var isSelf: Bool { pid == ProcessInfo.processInfo.processIdentifier }
}

/// Tracks which app is frontmost and reports app launches/terminations so the menu cache
/// can be dropped at the right moments.
@MainActor
final class AppContextService {
    private(set) var frontmost: FrontmostApp?

    /// Called whenever the frontmost app changes.
    var onFrontmostChange: (@MainActor (FrontmostApp) -> Void)?
    /// Called when an app launches or terminates (menu cache invalidation).
    var onAppsChanged: (@MainActor () -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var lastIdentity: String?

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        })

        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onAppsChanged?()
                }
            })
        }

        refresh()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    func refresh() {
        // The menu bar has exactly one owning app, and during a switch it is not always the
        // frontmost one. The rows we read are the menus the user sees on screen, so the
        // owner wins (Menu-Bar-Search's `menuBarOwningApplication`); the frontmost app is
        // the fallback for the moments nobody owns the bar.
        let owner = NSWorkspace.shared.menuBarOwningApplication
        guard let app = owner ?? NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        // Activating for our own window makes us frontmost. Keep reporting the last real app
        // instead: the panel still shows the shortcuts of the app the user came from, and
        // the settings window does not get its own menu bar as a "dictionary".
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let bundleID = app.bundleIdentifier
        let identity = bundleID ?? "pid:\(pid)"
        let context = FrontmostApp(
            pid: pid,
            bundleID: bundleID,
            name: app.localizedName ?? bundleID ?? "?",
            icon: app.icon
        )
        frontmost = context
        guard identity != lastIdentity else { return }
        lastIdentity = identity
        onFrontmostChange?(context)
    }
}
