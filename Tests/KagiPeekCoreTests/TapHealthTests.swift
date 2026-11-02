import XCTest
@testable import KagiPeekCore

/// The expensive failure this type exists to prevent is not "shortcuts stop working" — it is
/// the whole keyboard stopping, which happens when a tap is put back in front of a callback
/// that cannot run. So the tests are about two things: the first disable is always forgiven,
/// a tap that keeps failing is eventually left off, and — the bug measured in the field on
/// 2026-11-02 — events trickling through a stalling tap must not restart the episode.
final class TapHealthTests: XCTestCase {

    func testTheFirstDisableIsReEnabledAtOnce() {
        var health = TapHealth()
        XCTAssertEqual(health.recordDisable(trusted: true), .reEnable(after: 0))
    }

    func testEachFurtherDisableWaitsLonger() {
        var health = TapHealth()
        var delays: [TimeInterval] = []
        for _ in 0..<TapHealth.backoff.count {
            guard case let .reEnable(delay) = health.recordDisable(trusted: true) else {
                return XCTFail("gave up during the backoff window")
            }
            delays.append(delay)
        }
        XCTAssertEqual(delays, TapHealth.backoff)
        // Monotonic: a shorter pause than the one before would re-enter the freeze.
        for (earlier, later) in zip(delays, delays.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }
    }

    // MARK: - The field bug: a trickle of events is not health

    /// The measured episode: eleven disables in two minutes, every one logged
    /// "attempt 1, re-enabling in 0.0s", because a mouse click between timeouts reset the
    /// counter. Within the recovery window an event must not restart the sequence.
    func testSporadicEventsDuringAStallDoNotRestartTheEpisode() {
        var health = TapHealth()
        var t = Date(timeIntervalSince1970: 0)

        _ = health.recordDisable(trusted: true, now: t)
        t += 5
        health.recordEvent(now: t)              // a click got through
        _ = health.recordDisable(trusted: true, now: t)
        XCTAssertEqual(health.consecutiveDisables, 2, "a trickle must not reset the count")

        t += 10
        health.recordEvent(now: t)              // another one
        let recovery = health.recordDisable(trusted: true, now: t)
        XCTAssertEqual(recovery, .reEnable(after: 0.6), "the backoff must keep climbing")
    }

    /// Sustained service, on the other hand, is health: after the recovery window of quiet
    /// operation, the tap has earned a fresh start.
    func testServiceBeyondTheRecoveryWindowResetsTheSequence() {
        var health = TapHealth()
        var t = Date(timeIntervalSince1970: 0)

        _ = health.recordDisable(trusted: true, now: t)
        t += TapHealth.recoveryWindow + 1
        health.recordEvent(now: t)
        XCTAssertEqual(health.consecutiveDisables, 0)

        t += 1
        XCTAssertEqual(health.recordDisable(trusted: true, now: t), .reEnable(after: 0))
    }

    /// Just inside the window is not health yet — the boundary is the whole point.
    func testServiceJustInsideTheWindowStillCountsAsAStall() {
        var health = TapHealth()
        var t = Date(timeIntervalSince1970: 0)

        _ = health.recordDisable(trusted: true, now: t)
        t += TapHealth.recoveryWindow - 1
        health.recordEvent(now: t)
        XCTAssertEqual(
            health.recordDisable(trusted: true, now: t),
            .reEnable(after: TapHealth.backoff[1])
        )
    }

    func testATapThatKeepsFailingIsLeftOff() {
        var health = TapHealth()
        for _ in 0..<TapHealth.backoff.count {
            guard case .reEnable = health.recordDisable(trusted: true) else {
                return XCTFail("gave up too early")
            }
        }
        XCTAssertEqual(health.recordDisable(trusted: true), .tearDown)
    }

    func testWithoutThePermissionThereIsNothingToRetry() {
        var health = TapHealth()
        // Not even the first one: `tapEnable` on a tap whose permission is gone does not
        // fail loudly, it fails silently and keeps the input stream waiting.
        XCTAssertEqual(health.recordDisable(trusted: false), .tearDown)
        XCTAssertEqual(health.consecutiveDisables, 0)
    }

    func testResetForgetsTheHistory() {
        var health = TapHealth()
        var t = Date(timeIntervalSince1970: 0)
        _ = health.recordDisable(trusted: true, now: t)
        _ = health.recordDisable(trusted: true, now: t)
        health.reset()
        XCTAssertEqual(health.recordDisable(trusted: true, now: t), .reEnable(after: 0))
    }

    func testTheBackoffEndsWellBeforeTheTapBecomesACostlyFurniture() {
        // Every re-enable is a window in which the input stream waits. Six attempts over
        // roughly ten seconds is a few seconds of degraded input; an unbounded loop is a
        // frozen machine.
        let total = TapHealth.backoff.reduce(0, +)
        XCTAssertLessThan(total, 15)
    }
}
