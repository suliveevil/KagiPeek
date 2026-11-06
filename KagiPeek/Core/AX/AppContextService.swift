import AppKit

nonisolated struct FrontmostApp {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?

    var identity: String { bundleID ?? "pid:\(pid)" }

    /// True for Kaname itself. The app activates itself for the search palette, the
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

    private let observation = WorkspaceObservation()
    private var lastIdentity: String?
    private var lastPID: pid_t?

    func start() {
        guard !observation.isRunning else { return }
        observation.observe(NSWorkspace.didActivateApplicationNotification) { [weak self] in
            self?.refresh()
        }
        observation.observe([
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]) { [weak self] in
            self?.onAppsChanged?()
        }
        refresh()
    }

    func stop() {
        observation.stop()
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
        // A relaunch or a second instance keeps the bundle identity but changes the PID;
        // the rendered catalog and its AX elements still belong to the old process.
        guard identity != lastIdentity || pid != lastPID else { return }
        lastIdentity = identity
        lastPID = pid
        onFrontmostChange?(context)
    }
}
