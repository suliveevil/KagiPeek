import XCTest
@testable import KagiPeekCore

/// The watchdog answers the one question no in-tap counter can: is the main thread — the
/// thread the tap callback lives on, and therefore the thread every disable notification
/// must arrive through — still answering at all. Measured 2026-11-02: three disables
/// logged, then silence, then a power-button reset; the counter had no way to know the
/// callback had stopped running.
final class MainThreadWatchdogTests: XCTestCase {

    func testHealthyPingsDoNothing() {
        var watchdog = MainThreadWatchdog()
        XCTAssertEqual(watchdog.tick(mainAcknowledged: true), .none)
        XCTAssertEqual(watchdog.tick(mainAcknowledged: true), .none)
        XCTAssertFalse(watchdog.tapDetached)
    }

    /// One missed ping is a heavy main-thread moment, not a wedge: two consecutive missed
    /// pings are the shortest run that is certainly a stall.
    func testOneMissedPingIsNotEnough() {
        var watchdog = MainThreadWatchdog()
        XCTAssertEqual(watchdog.tick(mainAcknowledged: true), .none)
        XCTAssertEqual(watchdog.tick(mainAcknowledged: false), .none)
        XCTAssertFalse(watchdog.tapDetached)
    }

    func testTwoMissedPingsDetachTheTap() {
        var watchdog = MainThreadWatchdog()
        _ = watchdog.tick(mainAcknowledged: false)
        XCTAssertEqual(watchdog.tick(mainAcknowledged: false), .detachTap)
        XCTAssertTrue(watchdog.tapDetached)
    }

    /// The measured failure: silence continues after the detach. It must not flap — one
    /// detach decision, held until the main thread answers.
    func testContinuedSilenceAfterTheDetachDoesNotDetachAgain() {
        var watchdog = MainThreadWatchdog()
        _ = watchdog.tick(mainAcknowledged: false)
        XCTAssertEqual(watchdog.tick(mainAcknowledged: false), .detachTap)
        XCTAssertEqual(watchdog.tick(mainAcknowledged: false), .none)
        XCTAssertEqual(watchdog.tick(mainAcknowledged: false), .none)
        XCTAssertTrue(watchdog.tapDetached)
    }

    /// Recovery is the point of the whole exercise: the input stream was freed by the
    /// detach, and the tap goes back the moment the main thread answers.
    func testAnAnsweredPingReattachesTheTap() {
        var watchdog = MainThreadWatchdog()
        _ = watchdog.tick(mainAcknowledged: false)
        _ = watchdog.tick(mainAcknowledged: false)
        XCTAssertTrue(watchdog.tapDetached)

        XCTAssertEqual(watchdog.tick(mainAcknowledged: true), .reattachTap)
        XCTAssertFalse(watchdog.tapDetached)
        XCTAssertEqual(watchdog.tick(mainAcknowledged: true), .none)
    }

    func testResetForgetsTheStall() {
        var watchdog = MainThreadWatchdog()
        _ = watchdog.tick(mainAcknowledged: false)
        _ = watchdog.tick(mainAcknowledged: false)
        XCTAssertTrue(watchdog.tapDetached)

        watchdog.reset()
        XCTAssertEqual(watchdog.tick(mainAcknowledged: false), .none, "one missed ping after a reset starts a new count")
        XCTAssertFalse(watchdog.tapDetached)
    }
}
