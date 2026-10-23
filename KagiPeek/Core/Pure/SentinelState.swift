import Foundation

/// The sentinel file's verdict at a launch or a termination.
///
/// The sentinel (`logs/session.active`) is written early in every launch and deleted on a
/// clean terminate. Finding it still there on the next launch means the previous process
/// never got to say goodbye — a crash (a `.partial` signal report exists) or an unexpected
/// exit (kill, force quit, power loss: no report exists, and the honest record is that we
/// know nothing beyond "it never terminated cleanly").
enum SentinelState: Equatable {
    /// Nothing to report; proceed normally.
    case clean
    /// Command: write the sentinel for this session.
    case write
    /// Command: delete the sentinel on a clean exit (idempotent — deleting a missing file
    /// is a no-op, which is why this runs *before* any flush that might not finish).
    case remove
    /// The previous session never terminated cleanly. `partial` says whether a crash
    /// report fragment from the signal handler was found next to it.
    case reportUnexpectedExit(partial: Bool)

    /// The verdict at launch, from what is on disk.
    static func launchDecision(sentinelExists: Bool, crashPartialExists: Bool) -> SentinelState {
        sentinelExists
            ? .reportUnexpectedExit(partial: crashPartialExists)
            : .clean
    }

    /// The command at a clean terminate.
    static func terminateDecision(sentinelExists: Bool) -> SentinelState {
        sentinelExists ? .remove : .clean
    }
}
