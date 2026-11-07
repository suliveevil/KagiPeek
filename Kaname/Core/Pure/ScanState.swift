/// Why a scan produced what it did.
///
/// Menu-Bar-Search's `initState` (`.apiDisabled` / `.noValue`): an empty list and a read
/// that never happened look identical to the user, so the reason travels with the result
/// and the surfaces can say which one it was.
///
/// Moved here from `Core/AX/MenuScanner.swift`, which produced it but was not its only
/// reader — `EngineState` holds it, `ConflictCenter` and `DiagnosticsReportBuilder` name it,
/// and a value type living inside its producer's file makes every consumer depend on that
/// file. It has no I/O and no shared state, so Pure is where it belongs; being here also
/// puts it inside the test target, which `Core/AX` and `Core/Engine` are not.
nonisolated enum ScanState: Equatable, Sendable {
    /// Menus were read.
    case ok
    /// The app exposes no menu bar, or one without any command.
    case noMenus
    /// The app's menu bar could not be read at all: the system is not showing it (a
    /// full-screen app, "Automatically hide and show the menu bar", Mission Control) or the
    /// app did not answer within the messaging timeout. The commands still exist; they are
    /// just not exposed as an Accessibility tree right now.
    case menuBarUnavailable
    /// Accessibility is not trusted: nothing could be read at all, not even to find out
    /// whether the app has menus.
    case permissionDenied

    /// Stable spelling for the file log, so a grep for `state=` gives a countable answer
    /// instead of a Swift debug description.
    var diagnosticCode: String {
        switch self {
        case .ok: return "ok"
        case .noMenus: return "noMenus"
        case .menuBarUnavailable: return "menuBarUnavailable"
        case .permissionDenied: return "permissionDenied"
        }
    }
}
