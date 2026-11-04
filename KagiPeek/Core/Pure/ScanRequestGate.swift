import Foundation

/// Hands out a token per scan request and answers whether it is still the newest one.
///
/// A scan can outlive the reason it was started: the user moves to another app, a refresh
/// supersedes the one in flight, the deadline fires. Before paying for the scan the loader
/// asks whether its token is still current, and asks again before publishing; the answer
/// comes from one lock, so two requests cannot both believe they are the newest.
nonisolated final class ScanRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0

    /// Claims the newest token. Every earlier token stops being current the moment this
    /// returns — that is the cancellation signal for scans already running.
    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latest += 1
        return latest
    }

    /// Whether `token` is the most recent request. Token 0 is never current: it was never
    /// issued, so it must not be mistaken for the first request.
    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != 0 && token == latest
    }
}

/// Whether a queued scan may still occupy one of the two scan slots.
///
/// Checks used to happen after `scanSlots.wait()`, so an obsolete request could hold a slot
/// for as long as the semaphore took and delay the request that actually mattered. The gate
/// is consulted before waiting and again after acquiring.
nonisolated enum ScanAdmission {
    /// Half of the loader's 1.5 s deadline. Waiting longer than this for a slot leaves too
    /// little of the caller's budget to finish the scan, so the fallback answer is better
    /// than a slot acquired too late. Choosing half keeps the wait inside the deadline even
    /// if acquisition and the scan itself each take another 0.5 s.
    static let slotWaitTimeout: TimeInterval = 0.5

    enum Decision: Equatable {
        case scan
        /// The request is superseded or past its deadline: answer from cache/built-ins
        /// without touching the semaphore.
        case answerNow
    }

    static func decide(isCurrent: Bool, now: Date, deadline: Date) -> Decision {
        guard isCurrent, now < deadline else { return .answerNow }
        return .scan
    }
}
