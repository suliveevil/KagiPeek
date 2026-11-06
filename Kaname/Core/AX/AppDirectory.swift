import AppKit
import Combine

struct AppEntry: Identifiable, Hashable {
    let pid: pid_t
    let bundleID: String
    let name: String

    var id: String { bundleID + ":#" + String(pid) }

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

/// Running apps the search palette can scope itself to.
@MainActor
final class AppDirectory: ObservableObject {
    @Published private(set) var apps: [AppEntry] = []
    private let observation = WorkspaceObservation()

    func start() {
        guard !observation.isRunning else { return }
        observation.observe([
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]) { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        observation.stop()
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.bundleIdentifier != nil
                && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        apps = running
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return AppEntry(pid: app.processIdentifier, bundleID: bundleID, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
