import Foundation

/// What to do with an event tap the system has just disabled.
nonisolated enum TapRecovery: Equatable {
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
/// Measured on macOS 27, 2026-11-02, in five episodes, three ending in a power-button reset:
///
/// - one re-enable per disable, forever, froze the machine for minutes;
/// - a backoff of six steps froze it for 83 seconds (measured: attempt 1→7, 16:51:51→16:53:14);
/// - a 0.0/0.3/0.6/1.2/2.5 s backoff froze it for ~40 seconds (measured: attempt 1→5,
///   18:54:24→18:55:04, power-button reset before the seventh).
///
/// The log of that last episode is what settles the policy: the tap thread kept answering
/// (every attempt was logged, scans ran in 1–8 ms, the system load stayed at 3–4), so the
/// callback was never blocked — the events themselves were going into a tap that could not
/// deliver them. Re-enabling such a tap cannot work, and every extra attempt buys another
/// stall. One re-enable is the whole budget: enough for a genuine one-off hiccup, and the
/// second disable inside the recovery window means the tap cannot serve, so it is removed
/// from the input stream instead of put back in front of it.
nonisolated struct TapHealth {
    /// Pause before the one re-enable this type allows.
    ///
    /// Zero on purpose: a single hiccup while the machine is busy is normal, and turning it
    /// into "shortcuts stopped working" would be a worse bug than the one being fixed. The
    /// second disable is the answer, and it is teardown.
    static let backoff: [TimeInterval] = [0]

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
