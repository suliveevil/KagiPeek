import AppKit
import SwiftUI

/// Owns the permission guide window. It is shown on first launch when Accessibility is
/// missing and can be reopened from Settings or the menu bar.
@MainActor
final class PermissionsWindowController {
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
        window.title = engine.localization.text(.permissionsTitle)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    private func makeWindow() {
        let root = PermissionsView(
            permissions: engine.permissions,
            onQuit: { NSApp.terminate(nil) },
            onContinue: { [weak self] in self?.close() }
        )
        .environmentObject(engine)
        .environmentObject(engine.settingsStore)
        .environmentObject(engine.localization)

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = engine.localization.text(.permissionsTitle)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: root)
        panel.center()
        window = panel
    }
}
