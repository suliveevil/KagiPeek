import XCTest
@testable import KagiPeekCore

/// The expensive failure this type exists to prevent is not "shortcuts stop working" — it is
/// the whole keyboard stopping, which happens when a tap is put back in front of a callback
/// that cannot run. So the tests are about two things: the first disable is always forgiven,
/// and a tap that keeps failing is eventually left off.
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

    func testAnythingGettingThroughResetsTheSequence() {
        var health = TapHealth()
        _ = health.recordDisable(trusted: true)
        _ = health.recordDisable(trusted: true)
        XCTAssertEqual(health.consecutiveDisables, 2)

        health.recordEvent()
        XCTAssertEqual(health.consecutiveDisables, 0)
        XCTAssertEqual(health.recordDisable(trusted: true), .reEnable(after: 0))
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
        _ = health.recordDisable(trusted: true)
        _ = health.recordDisable(trusted: true)
        health.reset()
        XCTAssertEqual(health.recordDisable(trusted: true), .reEnable(after: 0))
    }

    func testTheBackoffEndsWellBeforeTheTapBecomesACostlyFurniture() {
        // Every re-enable is a window in which the input stream waits. Six attempts over
        // roughly ten seconds is a few seconds of degraded input; an unbounded loop is a
        // frozen machine.
        let total = TapHealth.backoff.reduce(0, +)
        XCTAssertLessThan(total, 15)
    }
}
