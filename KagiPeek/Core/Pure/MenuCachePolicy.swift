import Foundation

/// The pure half of the menu-scan disk cache: what a cached scan depends on, and when it
/// stops being trustworthy.
///
/// Borrowed from Menu-Bar-Search's cache, which pairs every entry with a control file
/// recording the settings it was written under. Two rules are ours: the fingerprint
/// covers the one setting that shapes a scan, and an entry has an age cap — menus change
/// while an app runs, so an unbounded cache would serve rows that no longer exist.
enum MenuCachePolicy {
    /// Bumped whenever the entry layout changes; entries written by an older build stop
    /// loading, because their fingerprint no longer matches.
    static let schemaVersion = 1

    /// How long a cached scan stays usable.
    ///
    /// Ten minutes: long enough that re-opening the panel for the same app — or relaunching
    /// KagiPeek — skips the AX walk, short enough that a menu which changed while the app
    /// ran is refreshed quickly. Inside the window a press re-walks the row's path and
    /// verifies its title, so staleness costs a failed press at worst, never a wrong
    /// command.
    static let entryMaxAge: TimeInterval = 600

    /// Identifies the settings a cached scan was written under. A scan-shaping setting
    /// added later means adding it here, and every entry written before that change stops
    /// loading on its own.
    static func fingerprint(showAppleMenu: Bool) -> String {
        "schema=\(schemaVersion);appleMenu=\(showAppleMenu ? 1 : 0)"
    }

    /// The control file records the fingerprint every entry was written under. A mismatch
    /// — a setting changed, the schema was bumped, the file was hand-edited — invalidates
    /// the whole cache at once, without reading a single entry.
    static func isControlCurrent(_ controlFingerprint: String?, fingerprint: String) -> Bool {
        controlFingerprint == fingerprint
    }

    /// An entry is usable when it was written under the current settings and is young
    /// enough. A future timestamp counts as unusable: a clock that jumped backwards must
    /// not resurrect an old scan forever.
    static func isEntryUsable(
        scannedAt: Date,
        entryFingerprint: String,
        fingerprint: String,
        now: Date = Date()
    ) -> Bool {
        guard entryFingerprint == fingerprint else { return false }
        let age = now.timeIntervalSince(scannedAt)
        return age >= 0 && age < entryMaxAge
    }
}
