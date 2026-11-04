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
        // Keep `.miniaturizable`: removing a window capability is a regression for users who
        // rely on it. Restoring the window instead means the menu item always reaches it,
        // minimised or merely behind another app, and the saved frame is not re-centred.
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeRoot(initialTab: SettingsTab) -> some View {
        SettingsView(initialTab: initialTab)
            .environmentObject(engine)
            .environmentObject(engine.state)
            .environmentObject(engine.settingsStore)
            .environmentObject(engine.usageStore)
            .environmentObject(engine.localization)
    }

    private func makeWindow(initialTab: SettingsTab) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
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
