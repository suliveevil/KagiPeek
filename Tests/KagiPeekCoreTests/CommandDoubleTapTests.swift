import XCTest
@testable import KagiPeekCore

/// Characterizes the "press ⌘ twice to pin" gesture that used to live inline in
/// `ShortcutEngine.handleModifiers` as `lastCommandDownAt` bookkeeping.
final class CommandDoubleTapTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// One quick press-and-release is only the first half of the gesture.
    func testSingleTapWithinWindowDoesNotComplete() {
        var gesture = CommandDoubleTap()
        XCTAssertFalse(gesture.process(modifiers: [.command], previous: [], now: t0, window: 0.3))
        XCTAssertFalse(gesture.process(modifiers: [], previous: [.command], now: t0.addingTimeInterval(0.1), window: 0.3))
    }

    /// Two complete taps inside the window are the gesture that toggles pinning.
    func testDoubleTapWithinWindowCompletes() {
        var gesture = CommandDoubleTap()
        XCTAssertFalse(gesture.process(modifiers: [.command], previous: [], now: t0, window: 0.3))
        XCTAssertFalse(gesture.process(modifiers: [], previous: [.command], now: t0.addingTimeInterval(0.1), window: 0.3))
        XCTAssertFalse(gesture.process(modifiers: [.command], previous: [], now: t0.addingTimeInterval(0.2), window: 0.3))
        XCTAssertTrue(gesture.process(modifiers: [], previous: [.command], now: t0.addingTimeInterval(0.25), window: 0.3))
    }

    func testReleaseBeyondWindowDoesNotComplete() {
        var gesture = CommandDoubleTap()
        _ = gesture.process(modifiers: [.command], previous: [], now: t0, window: 0.3)
        XCTAssertFalse(gesture.process(modifiers: [], previous: [.command], now: t0.addingTimeInterval(0.5), window: 0.3))
    }

    /// A second modifier between press and release breaks the gesture.
    func testOtherModifierBreaksTheGesture() {
        var gesture = CommandDoubleTap()
        _ = gesture.process(modifiers: [.command], previous: [], now: t0, window: 0.3)
        _ = gesture.process(modifiers: [.command, .option], previous: [.command], now: t0.addingTimeInterval(0.05), window: 0.3)
        XCTAssertFalse(gesture.process(modifiers: [], previous: [.command, .option], now: t0.addingTimeInterval(0.1), window: 0.3))
    }

    /// A stale candidate press must not fire on an unrelated later release.
    func testStaleCandidateDoesNotFireLater() {
        var gesture = CommandDoubleTap()
        _ = gesture.process(modifiers: [.command], previous: [], now: t0, window: 0.3)
        // ⌘ is released beyond the window; the candidate is dropped.
        _ = gesture.process(modifiers: [], previous: [.command], now: t0.addingTimeInterval(1.0), window: 0.3)
        // A fresh pair is only one tap; a second pair is needed to complete the gesture.
        _ = gesture.process(modifiers: [.command], previous: [], now: t0.addingTimeInterval(2.0), window: 0.3)
        XCTAssertFalse(gesture.process(modifiers: [], previous: [.command], now: t0.addingTimeInterval(2.1), window: 0.3))
        _ = gesture.process(modifiers: [.command], previous: [], now: t0.addingTimeInterval(2.2), window: 0.3)
        XCTAssertTrue(gesture.process(modifiers: [], previous: [.command], now: t0.addingTimeInterval(2.3), window: 0.3))
    }

    /// Modifier-only streams (⌘⌥, ⇧…) are not candidate presses.
    func testModifierChordsAreNotCandidatePresses() {
        var gesture = CommandDoubleTap()
        XCTAssertFalse(gesture.process(modifiers: [.command, .option], previous: [], now: t0, window: 0.3))
        XCTAssertFalse(gesture.process(modifiers: [], previous: [.command, .option], now: t0.addingTimeInterval(0.1), window: 0.3))
    }
}
