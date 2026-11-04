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

    /// A real key press between the two taps means the user typed a chord, not a gesture.
    func testTypedKeyCancelsTheCandidate() {
        var gesture = ModifierDoubleTap()
        _ = gesture.process(pressed: true, now: t0, window: 0.3)
        gesture.cancel()
        XCTAssertFalse(gesture.process(pressed: false, now: t0.addingTimeInterval(0.1), window: 0.3))
    }

    /// The second tap must release inside the window too, not merely start inside it.
    func testSlowSecondReleaseDoesNotComplete() {
        var gesture = ModifierDoubleTap()
        _ = gesture.process(pressed: true, now: t0, window: 0.3)
        _ = gesture.process(pressed: false, now: t0.addingTimeInterval(0.1), window: 0.3)
        _ = gesture.process(pressed: true, now: t0.addingTimeInterval(0.2), window: 0.3)
        XCTAssertFalse(gesture.process(pressed: false, now: t0.addingTimeInterval(0.6), window: 0.3))
    }

    func testReleaseBeyondWindowDoesNotComplete() {
        var gesture = ModifierDoubleTap()
        _ = gesture.process(pressed: true, now: t0, window: 0.3)
        XCTAssertFalse(gesture.process(pressed: false, now: t0.addingTimeInterval(0.5), window: 0.3))
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
