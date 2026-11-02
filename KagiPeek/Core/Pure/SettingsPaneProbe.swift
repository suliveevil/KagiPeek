import CoreGraphics
import Foundation

/// What System Settings' own preferences can tell the drag guide, without asking for Screen
/// Recording or Accessibility to read them.
///
/// Only the sidebar width survives here, and the negative half of the result is written
/// down here so nobody re-adds it: `CurrentExtensionURL` looks exactly like "the page
/// Settings is showing", but it is not usable as one. Measured on macOS 27 —
///
/// - the value is a file path (`…/ExtensionKit/Extensions/SecurityPrivacyExtension.appex`),
///   never the `com.apple.settings.PrivacySecurity.extension` identifier a deep link uses;
/// - it does not change while Settings runs. With the app parked on Accessibility it still
///   reported the software-update page from before.
///
/// A "you left this page" detector built on it is therefore wrong for every user, and
/// because that phase hid the drag icon it took away the only action the panel exists to
/// offer. LobeHub detects the same thing from the window title, which needs Screen
/// Recording, or from a sidebar click; neither is available here, so the phase is gone.
nonisolated enum SettingsPaneProbe {
    /// The sidebar width in points, from a saved `NSSplitView` frame row.
    ///
    /// The stored string is `"x, y, width, height, NO, NO"`; the first row is the sidebar.
    /// Returns nil when the value is not a usable width, which makes the caller centre the
    /// panel on the whole window — LobeHub's own fallback for unmeasured macOS versions.
    static func sidebarWidth(fromSplitFrame frame: String?) -> CGFloat? {
        guard let frame else { return nil }
        let fields = frame.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3, let width = Double(fields[2]), width > 0 else { return nil }
        return CGFloat(width)
    }
}
