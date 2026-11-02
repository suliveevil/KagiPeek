import Foundation

/// What to do with an event tap the system has just disabled.
enum TapRecovery: Equatable {
    /// Turn it back on, optionally after a pause.
    case reEnable(after: TimeInterval)
    /// Leave it off.
    case tearDown
}

/// Nurses a disabled event tap back to life — or decides that it is not coming back.
///
/// The counter-intuitive part is that backing off is what makes the machine responsive.
/// A *disabled* tap is harmless: the event that tripped the timeout is delivered to the
/// front app immediately. A tap that was just re-enabled in front of a callback that still
/// cannot run is not: every key and every click waits out the tap's timeout before being
/// delivered, so the keyboard feels frozen while `ps` shows 0% CPU — blocking costs no CPU,
/// which is why this failure is invisible to every resource monitor.
///
/// Measured on macOS 27, after Accessibility was revoked with the tap still installed:
/// twelve disables across two episodes, every one re-enabled immediately, and both episodes
/// ended in a force reboot. The immediate re-enable is the loop. The delays below end it,
/// and tearing down after the last one ends it for good.
struct TapHealth {
    /// Pause before each successive re-enable.
    ///
    /// The first is zero on purpose: one hiccup while the machine is busy is normal, and
    /// turning it into "shortcuts stopped working" would be a worse bug than the one being
    /// fixed. From the second on the pause doubles, because a second disable means the
    /// callback still cannot run and putting the tap back only restores the freeze.
    static let backoff: [TimeInterval] = [0, 0.3, 0.6, 1.2, 2.5, 5]

    /// How many disables in a row, with nothing getting through in between, before the tap
    /// is considered unrevivable.
    static var giveUpAfter: Int { backoff.count }

    private(set) var consecutiveDisables = 0

    /// Any event that is not itself a disable notification proves the tap is answering, so
    /// the count starts over. That is a better signal than elapsed time: disables are only
    /// posted when an event arrives, so an idle keyboard produces neither, and a tap that
    /// hiccuped once and then served a thousand keystrokes has earned a fresh start.
    mutating func recordEvent() {
        consecutiveDisables = 0
    }

    /// Called when the system reports that the tap was disabled.
    ///
    /// - Parameter trusted: whether the process still holds Accessibility. A tap that lost
    ///   the permission that created it can never answer `tapEnable`, so retrying is pure
    ///   cost to the input stream.
    mutating func recordDisable(trusted: Bool) -> TapRecovery {
        guard trusted else { return .tearDown }

        consecutiveDisables += 1
        let index = consecutiveDisables - 1
        guard index < Self.backoff.count else { return .tearDown }
        return .reEnable(after: Self.backoff[index])
    }

    /// Forget everything: a freshly created tap has no history.
    mutating func reset() {
        consecutiveDisables = 0
    }
}
