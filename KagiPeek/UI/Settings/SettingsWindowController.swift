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
        if window == nil {
            makeWindow()
        }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let root = SettingsView()
            .environmentObject(engine)
            .environmentObject(engine.settingsStore)
            .environmentObject(engine.usageStore)
            .environmentObject(engine.localization)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = engine.localization.text(.settingsTitle)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        self.window = window
    }
}
