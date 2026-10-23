import AppKit
import ApplicationServices
import os

/// Performs a menu command by pressing its Accessibility element.
///
/// This is the only way to reach a command that has no keyboard shortcut: replaying a chord
/// needs a chord, and such a menu item has none. It is also the more faithful trigger for
/// commands that *do* have one — pressing the item is exactly what clicking the menu does,
/// so the app's own validation and current state apply — which is why the engine tries it
/// first and only falls back to replaying the chord when the press fails (a stale element
/// after the menu changed, an app that ignores the action).
///
/// The element does not have to belong to the frontmost app: the Accessibility API reaches
/// background processes, so a row can be triggered without stealing focus from the app the
/// user is working in.
enum MenuTrigger {
    /// - Returns: whether the app accepted the press. `false` means the caller should fall
    ///   back to whatever else it knows about the row.
    static func press(_ element: AXUIElement) -> Bool {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard error == .success else {
            // A silent failure here is indistinguishable from "the command did nothing",
            // which is the bug this whole path exists to remove.
            AppLog.input.error("menu press failed with AXError \(error.rawValue)")
            Diag.error(.inject, "ax-press failed err=\(error.rawValue)")
            return false
        }
        return true
    }
}
