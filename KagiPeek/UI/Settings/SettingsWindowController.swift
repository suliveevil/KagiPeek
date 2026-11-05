import AppKit
import SwiftUI

/// Owns the settings window.
///
/// The app is a menu bar agent with no auto-opening scenes; the SwiftUI Settings
/// scene is not reachable from an AppKit-hosted panel, so the gear button and the
/// menu items open this window directly.
@MainActor
final class SettingsWindowController {
    private let engine: ShortcutEngine
    private var window: NSWindow?

    init(engine: ShortcutEngine) {
        self.engine = engine
    }

    func show() {
        present(initialTab: nil)
    }

    /// Re-opens the settings window on the Conflicts page.
    ///
    /// `SettingsView` owns the selected tab, so the only way to force one without threading a
    /// binding through every call site is to replace the hosted view with a freshly seeded one.
    /// The panel's conflict badge does this once; ordinary settings opens keep their state.
    private func present(initialTab: SettingsTab?) {
        if window == nil {
            makeWindow(initialTab: initialTab ?? .general)
        } else if let initialTab, let window {
            window.contentView = NSHostingView(rootView: makeRoot(initialTab: initialTab))
        }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The window the permission guide attaches to as a sheet. Nil until Settings has been
    /// opened once.
    var hostingWindow: NSWindow? { window }

    private func makeRoot(initialTab: SettingsTab) -> some View {
        SettingsView(initialTab: initialTab)
            .environmentObject(engine)
            .environment(engine.state)
            .environmentObject(engine.settingsStore)
            .environmentObject(engine.usageStore)
            .environmentObject(engine.localization)
    }

    private func makeWindow(initialTab: SettingsTab) {
        let window = NSWindow(
            // Wide enough for the sidebar plus the widest settings row; the reason for
            // 720 is worked out at the `.frame(minWidth:)` in `SettingsView`.
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            // No `.miniaturizable`: Settings is a single utility window, and a minimised
            // copy used to sit in the Dock while the menu item had to hunt for it. Close
            // and the existing menu restore path are the only ways out.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = engine.localization.text(.settingsTitle)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: makeRoot(initialTab: initialTab))
        window.center()
        self.window = window
    }
}

/// The port the engine drives (`Core/Ports/PresentationPorts.swift`). The controller's own
/// name for this is `show()`, which says nothing about what gets shown; the port says it.
extension SettingsWindowController: SettingsPresenting {
    func showSettings() { show() }
    func showConflicts() { present(initialTab: .conflicts) }
}
