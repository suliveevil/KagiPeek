import Foundation

/// Which sentence a press failure earns.
///
/// The two failures used to share one line. One is the ordinary dead end: the row was walked,
/// the menu had moved, and the item has no chord to replay. The other is a property of the
/// moment, not of the row — the app's menu bar is not readable right now (a full-screen app,
/// "Automatically hide and show the menu bar", Mission Control), so a row standing in from an
/// earlier scan cannot be pressed and its chord is the only way it could run. The second one
/// has an answer the user can act on, so it gets its own sentence instead of "could not run".
nonisolated enum RunFailureNotice {
    static func key(scanState: ScanState) -> L10nKey {
        scanState == .menuBarUnavailable ? .panelRunMenuBarHidden : .panelRunFailed
    }
}
