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
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
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
