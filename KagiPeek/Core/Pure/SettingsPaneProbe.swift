import CoreGraphics
import Foundation

/// Reads the two things the drag guide needs out of System Settings' own preferences,
/// without asking for Screen Recording or Accessibility to get them.
///
/// LobeHub detects "the user left this page" from the Settings window *title* when Screen
/// Recording is granted and otherwise guesses from a sidebar click — but this app's whole
/// premise is that the only permission it wants is the one being granted, so the title is
/// out of reach. `com.apple.systempreferences` records the pane it is showing in
/// `CurrentExtensionURL`, and the sidebar width in its saved split-view frames, both of
/// which are readable with no permission at all.
///
/// The page it reports is the containing extension, not the sub-page: every privacy list
/// (Accessibility, Input Monitoring, Screen Recording…) lives in
/// `PrivacySecurity.extension`, so a jump from Accessibility to Displays is caught while a
/// move between two privacy lists is not. The panel's instruction ("drag into the list
/// above") stays true in that case, which is why the coarser signal is enough.
enum SettingsPaneProbe {
    /// The privacy page that holds both lists this app cares about.
    static let privacyExtension = "com.apple.settings.PrivacySecurity.extension"

    /// The Ventura-and-earlier spelling, still accepted so the check does not misfire on an
    /// OS that kept the old identifier.
    static let legacySecurityPane = "com.apple.preference.security"

    /// The pane Settings was last showing, from `CurrentExtensionURL`.
    ///
    /// Nil means "no opinion": the key is absent on a fresh profile and after a Settings
    /// reset. Callers treat that as still-on-the-right-page rather than inventing a
    /// "you left" message the user cannot act on.
    static func privacyPageShown(inPaneURL paneURL: String?) -> Bool? {
        guard let paneURL, !paneURL.isEmpty else { return nil }
        return paneURL.contains(privacyExtension) || paneURL.contains(legacySecurityPane)
    }

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
