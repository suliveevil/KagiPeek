import ApplicationServices
import CoreGraphics

/// Cross-process "is a popup on screen right now?" guard.
///
/// Two problems share one answer:
///
/// 1. Kaname must not open its panel over a popup the user is working in.
/// 2. It must not swallow a modifier that a popup needs — Dock's "Force Quit" only appears
///    while Option is held down over the item, so eating Option breaks the menu.
///
/// A menu cannot be found by accessibility hit testing (`AXUIElementCopyElementAtPosition`
/// returns the element *under* the menu, never the menu), and the front app's
/// `NSMenu.didBeginTrackingNotification` never fires for another process' menu. The window
/// server is the only cross-process signal: a popup menu is the window parked at
/// `CGWindowLevelForKey(.popUpMenuWindow)` (101 on macOS), whichever process owns it — a
/// Dock menu belongs to `DockHelper`, not to the Dock or to the front app.
///
/// Sheets and dialogs are the opposite case: a sheet appends no CG window at a menu layer,
/// so it is read out of the frontmost app's AX windows instead.
nonisolated enum PopupGate {
    /// A popup menu is on screen.
    ///
    /// `excludingOwner` drops menus owned by that process. Kaname's own status menu is still
    /// on screen while the item the user picked is being dispatched, and it is the one popup
    /// that must not stop the app: the user asked for the panel by choosing an item from it.
    static func menuPresent(excludingOwner ownPID: pid_t? = nil) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.contains { window in
            guard (window[kCGWindowLayer as String] as? Int) == menuLevel else { return false }
            guard let ownPID else { return true }
            return (window[kCGWindowOwnerPID as String] as? Int) != Int(ownPID)
        }
    }

    /// A popup menu, sheet, or dialog is on screen.
    ///
    /// `ignoringOwnMenu` applies the same exception as `menuPresent(excludingOwner:)`: a
    /// sheet or dialog keeps its vote, because those belong to the app in front and the
    /// panel would still cover what the user is deciding in them.
    static func present(pid: pid_t?, ignoringOwnMenu: Bool = false) -> Bool {
        let ownPID: pid_t? = ignoringOwnMenu ? ProcessInfo.processInfo.processIdentifier : nil
        if menuPresent(excludingOwner: ownPID) { return true }
        guard let pid, pid > 0 else { return false }
        return dialogPresent(pid: pid)
    }

    private static func dialogPresent(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        // A busy or wedged app must not stall the caller. The read then falls back to
        // "no dialog", which is the pre-existing behaviour rather than a new failure mode.
        AXUIElementSetMessagingTimeout(app, 0.15)
        for window in AXValueReader.elements(kAXWindowsAttribute, of: app) {
            if isDialog(window) { return true }
            if AXValueReader.children(of: window).contains(where: isDialog) { return true }
        }
        return false
    }

    private static func isDialog(_ element: AXUIElement) -> Bool {
        let role = AXValueReader.string(kAXRoleAttribute, of: element)
        let subrole = AXValueReader.string(kAXSubroleAttribute, of: element)
        return role == "AXSheet" || role == "AXDialog"
            || subrole == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog"
    }
}
