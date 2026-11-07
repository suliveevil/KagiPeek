import Foundation

/// The sentinel file's verdict at a launch or a termination.
///
/// The sentinel (`logs/session.active`) is written early in every launch and deleted on a
/// clean terminate. Finding it still there on the next launch means the previous process
/// never got to say goodbye — a crash (a `.partial` signal report exists) or an unexpected
/// exit (kill, force quit, power loss: no report exists, and the honest record is that we
/// know nothing beyond "it never terminated cleanly").
///
/// "Still there" is not enough on its own. A second launch of the same app — a double click
/// while the first is running, `open -a` on a copy, a diagnostics run against the installed
/// build — finds the *live* instance's sentinel and would conclude that this instance died.
/// That is why the file carries the writer's pid, and why both verdicts take it into account:
/// the sentinel is evidence about *that* process, so a live owner means "nothing to report,
/// and nothing to delete" rather than "crash".
nonisolated enum SentinelState: Equatable {
    /// Nothing on disk to act on, or nothing worth doing.
    case clean
    /// Command: write the sentinel for this session.
    case write
    /// Command: delete the sentinel on a clean exit (idempotent — deleting a missing file
    /// is a no-op, which is why this runs *before* any flush that might not finish).
    case remove
    /// Command: the file exists but belongs to another, running instance. Leaving it alone is
    /// the whole point: deleting it would blind that instance, and reporting it would be a
    /// crash report about a live process.
    case leaveAlone
    /// The previous session never terminated cleanly. `partial` says whether a crash
    /// report fragment from the signal handler was found next to it.
    case reportUnexpectedExit(partial: Bool)
    /// The sentinel names a process that is still running, so this launch is the duplicate.
    case ownedByLiveProcess(pid: Int32)

    /// Reads the writer's pid out of the sentinel's content (`pid=<n> started=<iso8601>`).
    ///
    /// Content without a pid — a sentinel written before the field existed, or a file someone
    /// edited — parses to `nil`, which every caller treats as "unknown owner", i.e. the
    /// behaviour from before the pid was recorded.
    static func ownerPID(in content: String) -> Int32? {
        // `isWhitespace`, not `== " "` / `== "\n"` / `== "\r"`: a CRLF pair is a single
        // `Character`, so it is equal to neither of the two scalars it is made of.
        for field in content.split(whereSeparator: { $0.isWhitespace }) {
            guard field.hasPrefix("pid=") else { continue }
            return Int32(field.dropFirst("pid=".count))
        }
        return nil
    }

    /// The verdict at launch, from what is on disk and what the pid says now.
    ///
    /// `ownerIsLive` is asked about the *other* process, so a sentinel naming our own pid is
    /// not "alive": a previous session cannot still be us, which makes that a recycled pid
    /// and a dead owner.
    static func launchDecision(
        sentinelExists: Bool,
        ownerPID: Int32?,
        ownerIsLive: Bool,
        currentPID: Int32,
        crashPartialExists: Bool
    ) -> SentinelState {
        guard sentinelExists else { return .clean }
        if let ownerPID, ownerPID != currentPID, ownerIsLive {
            return .ownedByLiveProcess(pid: ownerPID)
        }
        return .reportUnexpectedExit(partial: crashPartialExists)
    }

    /// The command at a clean terminate.
    ///
    /// Existence is not ownership. A process that never wrote the sentinel can still reach a
    /// clean exit — that is exactly what a duplicate launch does after the single-instance
    /// guard rejects it — and it must not take the file with it.
    static func terminateDecision(sentinelExists: Bool, ownedByThisProcess: Bool) -> SentinelState {
        guard sentinelExists else { return .clean }
        return ownedByThisProcess ? .remove : .leaveAlone
    }
}
