import XCTest
@testable import KagiPeekCore

/// Characterizes the "press the trigger key twice to pin" gesture.
final class ModifierDoubleTapTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// One quick press-and-release is only the first half of the gesture.
    func testSingleTapWithinWindowDoesNotComplete() {
        var gesture = ModifierDoubleTap()
        XCTAssertFalse(gesture.process(pressed: true, now: t0, window: 0.3))
        XCTAssertFalse(gesture.process(pressed: false, now: t0.addingTimeInterval(0.1), window: 0.3))
    }

    /// Two complete taps inside the window are the gesture that toggles pinning.
    func testDoubleTapWithinWindowCompletes() {
        var gesture = ModifierDoubleTap()
        XCTAssertFalse(gesture.process(pressed: true, now: t0, window: 0.3))
        XCTAssertFalse(gesture.process(pressed: false, now: t0.addingTimeInterval(0.1), window: 0.3))
        XCTAssertFalse(gesture.process(pressed: true, now: t0.addingTimeInterval(0.2), window: 0.3))
        XCTAssertTrue(gesture.process(pressed: false, now: t0.addingTimeInterval(0.25), window: 0.3))
    }

    /// A gap just inside the window completes. The boundary itself is not asserted:
    /// `Date` arithmetic makes an exact 0.3 s gap ambiguous in floating point.
    func testGapJustInsideTheWindowCompletes() {
        var gesture = ModifierDoubleTap()
        _ = gesture.process(pressed: true, now: t0, window: 0.3)
        _ = gesture.process(pressed: false, now: t0.addingTimeInterval(0.1), window: 0.3)
        _ = gesture.process(pressed: true, now: t0.addingTimeInterval(0.39), window: 0.3)
        XCTAssertTrue(gesture.process(pressed: false, now: t0.addingTimeInterval(0.44), window: 0.3))
    }

    /// A real key press between the two taps means the user typed a chord, not a gesture.
    func testTypedKeyCancelsTheCandidate() {
        var gesture = ModifierDoubleTap()
        _ = gesture.process(pressed: true, now: t0, window: 0.3)
        gesture.cancel()
        // The chord's release must not be recorded as a first tap.
        XCTAssertFalse(gesture.process(pressed: false, now: t0.addingTimeInterval(0.1), window: 0.3))
        // A later clean pair still needs two taps.
        XCTAssertFalse(gesture.process(pressed: true, now: t0.addingTimeInterval(0.2), window: 0.3))
        XCTAssertFalse(gesture.process(pressed: false, now: t0.addingTimeInterval(0.25), window: 0.3))
    }

    /// A second tap may stay down longer than the window: only the gap between the taps is
    /// timed, so a slow finger is not a missed gesture.
    func testSecondTapMayBeHeldLongerThanTheWindow() {
        var gesture = ModifierDoubleTap()
        _ = gesture.process(pressed: true, now: t0, window: 0.3)
        _ = gesture.process(pressed: false, now: t0.addingTimeInterval(0.1), window: 0.3)
        _ = gesture.process(pressed: true, now: t0.addingTimeInterval(0.2), window: 0.3)
        XCTAssertTrue(gesture.process(pressed: false, now: t0.addingTimeInterval(0.6), window: 0.3))
    }

    /// A first tap held past the window still counts as a tap; the window measures the gap
    /// to the next one, not the time a finger spends on the key.
    func testSlowFirstPressStillCountsAsTheFirstTap() {
        var gesture = ModifierDoubleTap()
        XCTAssertFalse(gesture.process(pressed: true, now: t0, window: 0.3))
        XCTAssertFalse(gesture.process(pressed: false, now: t0.addingTimeInterval(0.5), window: 0.3))
        XCTAssertFalse(gesture.process(pressed: true, now: t0.addingTimeInterval(0.7), window: 0.3))
        XCTAssertTrue(gesture.process(pressed: false, now: t0.addingTimeInterval(0.75), window: 0.3))
    }

    /// A second press after the window is a fresh first tap, not the second half of the old
    /// candidate.
    func testGapBeyondWindowStartsANewFirstTap() {
        var gesture = ModifierDoubleTap()
        _ = gesture.process(pressed: true, now: t0, window: 0.3)
        _ = gesture.process(pressed: false, now: t0.addingTimeInterval(0.1), window: 0.3)
        _ = gesture.process(pressed: true, now: t0.addingTimeInterval(0.5), window: 0.3)
        XCTAssertFalse(gesture.process(pressed: false, now: t0.addingTimeInterval(0.55), window: 0.3))
    }

    /// A stale candidate press must not fire on an unrelated later release.
    func testStaleCandidateDoesNotFireLater() {
        var gesture = ModifierDoubleTap()
        _ = gesture.process(pressed: true, now: t0, window: 0.3)
        // The key is released beyond the window; the candidate is dropped.
        _ = gesture.process(pressed: false, now: t0.addingTimeInterval(1.0), window: 0.3)
        // A fresh pair is only one tap; a second pair is needed to complete the gesture.
        _ = gesture.process(pressed: true, now: t0.addingTimeInterval(2.0), window: 0.3)
        XCTAssertFalse(gesture.process(pressed: false, now: t0.addingTimeInterval(2.1), window: 0.3))
        _ = gesture.process(pressed: true, now: t0.addingTimeInterval(2.2), window: 0.3)
        XCTAssertTrue(gesture.process(pressed: false, now: t0.addingTimeInterval(2.3), window: 0.3))
    }

    /// Releasing a key that was never pressed is not an edge and must not complete anything.
    func testReleaseWithoutPressIsIgnored() {
        var gesture = ModifierDoubleTap()
        XCTAssertFalse(gesture.process(pressed: false, now: t0, window: 0.3))
    }
}
