import AppKit
import CoreGraphics

/// Finds the System Settings window the drag guide anchors to, and reads the two pieces of
/// Settings state the guide reacts to.
///
/// Settings is identified by owning process, never by window title, and only the owner,
/// layer and bounds fields of the window list are read — `kCGWindowName` would drag Screen
/// Recording permission into a flow whose whole point is that nothing but the TCC toggle
/// is needed.
enum SettingsWindowLocator {
    static let settingsBundleIdentifier = "com.apple.systempreferences"

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == settingsBundleIdentifier
    }

    /// Every on-screen, layer-0 window System Settings owns, largest first, in AppKit
    /// screen coordinates.
    ///
    /// More than one means a password / Touch ID prompt is up: the system raises that as a
    /// second Settings window centred over the main one. Sorting by area keeps "the main
    /// window" a single well-defined answer even when a stray palette joins the list.
    static func settingsWindows() -> [NSRect] {
        let settingsPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: settingsBundleIdentifier)
            .first?.processIdentifier
        guard
            let settingsPID,
            let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        let appKitTopY = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let rects = rawList.compactMap { info -> CGRect? in
            guard
                (info[kCGWindowOwnerPID as String] as? Int32) == settingsPID,
                (info[kCGWindowLayer as String] as? Int) == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.width > 1, bounds.height > 1
            else { return nil }
            return PermissionGuidePlacement.appKitFrame(ofCGFrame: bounds, appKitTopY: appKitTopY)
        }
        return rects.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// The largest on-screen, layer-0 window owned by System Settings, in AppKit screen
    /// coordinates. Nil when Settings is not running or shows no window.
    static func settingsWindowFrame() -> NSRect? {
        settingsWindows().first
    }

    /// Whether one of the Settings windows is a password / Touch ID prompt sitting over the
    /// main window. Used only to tell "waiting for confirmation" apart from "the user
    /// cancelled", so the test is deliberately loose: a second window that is smaller than
    /// the main one and overlaps its centre.
    static func showsConfirmationPrompt(windows: [NSRect]) -> Bool {
        guard windows.count > 1, let main = windows.first else { return false }
        let centre = CGPoint(x: main.midX, y: main.midY)
        return windows.dropFirst().contains { sheet in
            let sheetIsSmaller = sheet.width * sheet.height < main.width * main.height * 0.9
            return sheetIsSmaller && sheet.contains(centre)
        }
    }

    /// The visible frame the anchored panel is clamped to: the screen showing the Settings
    /// window, falling back to the main screen.
    static func screenVisibleFrame(forSettingsFrame frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        return screen?.visibleFrame ?? .zero
    }

    /// The visible frame of the main screen — where the guide lands when Settings is gone
    /// and there is no window left to point at.
    static var mainScreenVisibleFrame: NSRect {
        NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
    }

    // MARK: - Settings state, permission-free

    /// System Settings' preference domain. Reading another app's defaults is allowed for an
    /// unsandboxed app and needs no TCC grant, which is the whole reason the guide reads it.
    private static var settingsDefaults: UserDefaults? {
        UserDefaults(suiteName: settingsBundleIdentifier)
    }

    /// The pane Settings is currently showing, or nil when it has not recorded one.
    static func currentPaneURL() -> String? {
        settingsDefaults?.string(forKey: "CurrentExtensionURL")
    }

    /// The sidebar width Settings last laid out, or nil when it has never saved one. Keys
    /// have been spelled with both a lowercase and a capitalised split-view name across
    /// releases, so both are tried before giving up.
    static func sidebarWidth() -> CGFloat? {
        guard let defaults = settingsDefaults else { return nil }
        let keys = [
            "NSSplitView Subview Frames Main, SidebarNavigationSplitView",
            "NSSplitView Subview Frames main, SidebarNavigationSplitView",
            "NSSplitView Subview Frames main, SidebarNavigationView"
        ]
        for key in keys {
            let frames = defaults.stringArray(forKey: key)
            if let width = SettingsPaneProbe.sidebarWidth(fromSplitFrame: frames?.first) {
                return width
            }
        }
        return nil
    }

    /// Brings an already-running Settings to the front.
    ///
    /// A deep link does not raise a running Settings — the open request is coalesced and the
    /// window stays behind — so the guide would float over whatever the user was looking at.
    static func activateSettings() {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: settingsBundleIdentifier)
            .first
        else { return }
        app.activate(options: [.activateAllWindows])
    }
}
