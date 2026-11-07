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
            applyTitle(initialTab)
        }
        guard let window else { return }
        // A window belongs to the Space it was ordered into, and a menu bar extra is never
        // the active app: "the Space the app is in" is only ever the Space it last had a
        // window on, which is a full-screen app's often enough. Ordering it front from
        // there switched the user to that Space, so Settings opened over the full-screen
        // app instead of the desktop the gear was clicked on. `.moveToActiveSpace` re-parents
        // the window on order-front, and that only applies while the window is off screen —
        // one left visible on another Space is taken down first.
        if window.isVisible, !window.isOnActiveSpace {
            window.orderOut(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Keeps the title on the pane the user is looking at, the way macOS settings windows
    /// behave. The view owns the selection, so it reports changes back through `makeRoot`.
    private func applyTitle(_ tab: SettingsTab) {
        window?.title = engine.localization.text(tab.titleKey)
    }

    /// The window the permission guide attaches to as a sheet. Nil until Settings has been
    /// opened once.
    var hostingWindow: NSWindow? { window }

    private func makeRoot(initialTab: SettingsTab) -> some View {
        SettingsView(initialTab: initialTab, onTabChange: { [weak self] tab in
            self?.applyTitle(tab)
        })
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
        window.title = engine.localization.text(initialTab.titleKey)
        window.isReleasedWhenClosed = false
        // Settings is a window the user opens from the menu bar of whichever Space they are
        // looking at, so it has to follow that Space rather than stay where it was born.
        // `.fullScreenAuxiliary` covers the same click made from a full-screen app's menu
        // bar, where the active Space belongs to another process.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: makeRoot(initialTab: initialTab))
        // Settings is a single utility window: HIG asks for the zoom control to be dimmed
        // rather than offering a maximised settings window nobody asked for.
        window.standardWindowButton(.zoomButton)?.isEnabled = false
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
