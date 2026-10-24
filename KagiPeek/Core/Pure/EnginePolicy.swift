import Foundation

/// One rule for whether a row may be acted on. The panel and the palette both use it so a
/// disabled menu item cannot be executed from one surface after being blocked in the other.
enum RowEligibility {
    static func canActivate(isEnabled: Bool) -> Bool {
        isEnabled
    }
}

/// Coverage of one cross-application conflict scan. A scan that could not read every app is
/// not evidence of "no conflicts".
enum ConflictScanState: Equatable, Sendable {
    case idle
    case scanning
    case complete
    case partial(failed: Int)
    case failed

    static func finished(successes: Int, failures: Int) -> ConflictScanState {
        if successes == 0, failures > 0 { return .failed }
        if failures > 0 { return .partial(failed: failures) }
        return .complete
    }
}

/// Why the search palette currently has (or lacks) results.
enum SearchLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case permissionDenied
    case failed
}
