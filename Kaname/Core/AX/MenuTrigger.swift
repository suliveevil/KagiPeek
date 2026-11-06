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
    ///
    /// Runs off the main actor: a wedged app used to freeze the panel for every synchronous
    /// `AXUIElementPerformAction`. The element crosses as `ResolvedAXElement`, the same
    /// wrapper the catalog loader uses for its background walk.
    ///
    /// The timeout is set on the element being pressed, not inherited from an application
    /// element: the API documents the timeout against the object's application, but relying
    /// on an earlier `AXUIElementCreateApplication` call having set it would make this
    /// correct only by accident. Every element this function messages gets it explicitly.
    ///
    /// A menu press normally answers in milliseconds. The 250 ms timeout is long enough to
    /// absorb a busy app and short enough that the panel's running row does not turn into a
    /// beachball; past it the caller takes the existing "press failed" path.
    @concurrent
    nonisolated static func press(_ element: ResolvedAXElement) async -> Bool {
        let axElement = element.element
        AXUIElementSetMessagingTimeout(axElement, 0.25)
        let error = AXUIElementPerformAction(axElement, kAXPressAction as CFString)
        guard error == .success else {
            // A silent failure here is indistinguishable from "the command did nothing",
            // which is the bug this whole path exists to remove.
            Diag.error(.inject, "ax-press failed err=\(error.rawValue)")
            return false
        }
        return true
    }
}
