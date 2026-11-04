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
        // Activation belongs to the user's explicit open (or to the first-launch guide).
        // Permission-state polling no longer funnels through here, and the window keeps the
        // frame it already has instead of being re-centred under the pointer.
        NSApp.activate(ignoringOtherApps: true)
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
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 380),
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

/// The port the engine drives (`Core/Ports/PresentationPorts.swift`).
extension PermissionsWindowController: PermissionsPresenting {
    func showPermissions() { show() }
}
