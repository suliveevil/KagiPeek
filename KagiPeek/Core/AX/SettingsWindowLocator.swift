import AppKit
import CoreGraphics

/// Finds the System Settings window the drag guide anchors to.
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

    /// The largest on-screen, layer-0 window owned by System Settings, in AppKit screen
    /// coordinates. Nil when Settings is not running or shows no window.
    static func settingsWindowFrame() -> NSRect? {
        let settingsPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: settingsBundleIdentifier)
            .first?.processIdentifier
        guard
            let settingsPID,
            let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        let candidates = rawList.compactMap { info -> (frame: CGRect, area: CGFloat)? in
            guard
                (info[kCGWindowOwnerPID as String] as? Int32) == settingsPID,
                (info[kCGWindowLayer as String] as? Int) == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return (bounds, bounds.width * bounds.height)
        }
        // Settings is effectively single-window; "largest" only defends against a stray
        // palette (a color picker, a sheet) being mistaken for the main window.
        guard let largest = candidates.max(by: { $0.area < $1.area }) else { return nil }

        let appKitTopY = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return PermissionGuidePlacement.appKitFrame(ofCGFrame: largest.frame, appKitTopY: appKitTopY)
    }

    /// The visible frame the anchored panel is clamped to: the screen showing the Settings
    /// window, falling back to the main screen.
    static func screenVisibleFrame(forSettingsFrame frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        return screen?.visibleFrame ?? .zero
    }
}
