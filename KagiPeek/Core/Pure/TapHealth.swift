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
/// the first version of this type reset its counter on *any* event getting through, and
/// during a stall events do trickle through — eleven disables in two minutes, every one
/// logged as "attempt 1, re-enabling in 0.0s", each ending in a force reboot. One mouse
/// click is not proof that a tap serves the input stream. Only sustained service is:
/// an event counts as healthy only this long after the last disable.
struct TapHealth {
    /// Pause before each successive re-enable.
    ///
    /// The first is zero on purpose: one hiccup while the machine is busy is normal, and
    /// turning it into "shortcuts stopped working" would be a worse bug than the one being
    /// fixed. From the second on the pause doubles, because a second disable means the
    /// callback still cannot run and putting the tap back only restores the freeze.
    static let backoff: [TimeInterval] = [0, 0.3, 0.6, 1.2, 2.5, 5]

    /// How long the tap must serve events — after the last disable, with none of its own —
    /// before one event is accepted as proof of health. Shorter than this, events are the
    /// trickle of a stalling stream, not evidence the callback runs.
    static let recoveryWindow: TimeInterval = 60

    /// How many disables in a row, with no sustained service in between, before the tap is
    /// considered unrevivable.
    static var giveUpAfter: Int { backoff.count + 1 }

    private(set) var consecutiveDisables = 0
    private var lastDisableAt: Date?

    /// An event passed through the tap. It only counts as proof of health once the tap has
    /// been serving for `recoveryWindow` since the last disable; before that, events are
    /// what a dying tap still lets through, and counting them restarts the episode — which
    /// is exactly how the first version of this type froze a machine for a full minute.
    mutating func recordEvent(now: Date = Date()) {
        if let lastDisableAt, now.timeIntervalSince(lastDisableAt) < Self.recoveryWindow {
            return
        }
        consecutiveDisables = 0
    }

    /// Called when the system reports that the tap was disabled.
    ///
    /// - Parameter trusted: whether the process still holds Accessibility. A tap that lost
    ///   the permission that created it can never answer `tapEnable`, so retrying is pure
    ///   cost to the input stream.
    mutating func recordDisable(trusted: Bool, now: Date = Date()) -> TapRecovery {
        guard trusted else { return .tearDown }

        lastDisableAt = now
        consecutiveDisables += 1
        let index = consecutiveDisables - 1
        guard index < Self.backoff.count else { return .tearDown }
        return .reEnable(after: Self.backoff[index])
    }

    /// Forget everything: a freshly created tap has no history.
    mutating func reset() {
        consecutiveDisables = 0
        lastDisableAt = nil
    }
}
