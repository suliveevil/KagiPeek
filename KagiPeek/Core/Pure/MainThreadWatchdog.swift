import Foundation

/// The outside view of a failure the tap can never report about itself.
///
/// The tap callback lives on the main run loop, and a disable notification is itself
/// delivered *through* the callback. So when the main thread wedges while the tap is
/// enabled, every event waits in front of a callback that cannot run, the system's
/// timeout notifications queue behind the same wedge, and `TapHealth` never hears
/// anything — the input stream freezes with nothing in the log. Measured on macOS 27,
/// 2026-11-02: three disable notifications logged, then silence, then a power-button
/// reset.
///
/// The watchdog pings the main thread from its own queue. While the pings come back it
/// does nothing; when they stop, the tap is detached from the input stream from the
/// outside — a *disabled* tap is harmless, events go straight to the front app — and
/// reattached once the main thread answers again. The trade is deliberate: shortcuts go
/// dark for as long as the main thread is wedged, but the keyboard never does.
struct MainThreadWatchdog: Equatable {
    enum Action: Equatable {
        case none
        /// The main thread has stopped answering with the tap enabled: detach it.
        case detachTap
        /// The main thread answers again: put the tap back.
        case reattachTap
    }

    /// Consecutive unanswered pings before the tap is detached. One is a heavy main-thread
    /// moment — a big render, a slow disk — and momentarily losing shortcuts over it would
    /// be worse than the blip it prevents.
    static let ticksBeforeDetach = 2

    private(set) var unresponsiveTicks = 0
    private(set) var tapDetached = false

    /// One tick of the watchdog clock.
    ///
    /// - Parameter mainAcknowledged: whether the ping issued at the previous tick has been
    ///   answered by the main thread.
    mutating func tick(mainAcknowledged: Bool) -> Action {
        guard mainAcknowledged else {
            unresponsiveTicks += 1
            guard unresponsiveTicks >= Self.ticksBeforeDetach, !tapDetached else { return .none }
            tapDetached = true
            return .detachTap
        }

        unresponsiveTicks = 0
        guard tapDetached else { return .none }
        tapDetached = false
        return .reattachTap
    }

    /// A fresh tap has no history, and neither does the watchdog.
    mutating func reset() {
        unresponsiveTicks = 0
        tapDetached = false
    }
}
