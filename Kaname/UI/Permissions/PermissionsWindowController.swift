import AppKit
import SwiftUI

/// Owns the permission guide window. It is shown on first launch when Accessibility is
/// missing and can be reopened from Settings or the menu bar.
@MainActor
final class PermissionsWindowController {
    private let engine: ShortcutEngine
    /// The window to attach to as a sheet when it is open. `nil` makes the guide stand
    /// alone, which is what first launch needs (Settings has not been opened yet).
    private let sheetHost: () -> NSWindow?
    private var window: NSWindow?
    private weak var sheetParent: NSWindow?

    init(engine: ShortcutEngine, sheetHost: @escaping () -> NSWindow? = { nil }) {
        self.engine = engine
        self.sheetHost = sheetHost
    }

    func show() {
        // A sheet cannot take focus away from the app, and it cannot be either behind the
        // settings window or in another Space — the two ways a free-floating guide got lost.
        if let host = sheetHost(), host.isVisible {
            if window == nil {
                makeWindow()
            }
            guard let window else { return }
            window.title = engine.localization.text(.permissionsTitle)
            if sheetParent == nil {
                sheetParent = host
                host.beginSheet(window) { [weak self] _ in
                    self?.sheetParent = nil
                }
            }
            return
        }
        if window == nil {
            makeWindow()
        }
        guard let window else { return }
        window.title = engine.localization.text(.permissionsTitle)
        // Same rule as Settings: the window belongs to the Space it was last ordered into,
        // and this app is never active, so ordering it front from the menu bar used to take
        // the user to whatever Space the window had last lived in. `.moveToActiveSpace` only
        // re-parents an off-screen window, so one left visible elsewhere is taken down first.
        if window.isVisible, !window.isOnActiveSpace {
            window.orderOut(nil)
        }
        // Activation belongs to the user's explicit open (or to the first-launch guide).
        // Permission-state polling no longer funnels through here, and the window keeps the
        // frame it already has instead of being re-centred under the pointer.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        if let sheetParent, let window {
            sheetParent.endSheet(window)
            self.sheetParent = nil
            return
        }
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
        // The guide is also opened from the menu bar of whichever Space the user is looking
        // at; `.fullScreenAuxiliary` covers a click made from a full-screen app's menu bar.
        // As a sheet it follows its parent's Space instead and this behaviour stays dormant.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: root)
        panel.center()
        window = panel
    }
}

/// The port the engine drives (`Core/Ports/PresentationPorts.swift`).
extension PermissionsWindowController: PermissionsPresenting {
    func showPermissions() { show() }
}
