import XCTest
@testable import KagiPeekCore

/// Characterizes the Karabiner-style "hyper tap → Escape" gesture that used to live inline
/// in `ShortcutEngine.handleModifiers` as `hyperArmedAt` / `hyperUsedKey` bookkeeping.
final class HyperEscapeTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let hyper: ModifierSet = [.control, .option, .shift, .command]

    private func process(_ modifiers: ModifierSet, at time: Date, _ gesture: inout HyperEscape) -> HyperEscape.Outcome {
        gesture.process(modifiers: modifiers, now: time)
    }

    /// A lone hyper press arms the gesture and narrows the panel to it.
    func testHyperPressArms() {
        var gesture = HyperEscape()
        XCTAssertEqual(process(hyper, at: t0, &gesture), .arm)
        XCTAssertEqual(gesture.armedAt, t0)
    }

    /// A clean release within the window is Escape: dismiss the panel.
    func testCleanReleaseDismisses() {
        var gesture = HyperEscape()
        _ = process(hyper, at: t0, &gesture)
        XCTAssertEqual(process([], at: t0.addingTimeInterval(0.5), &gesture), .releaseDismiss)
    }

    /// Holding longer than the window is not an Escape.
    func testLateReleaseClearsWithoutDismissing() {
        var gesture = HyperEscape()
        _ = process(hyper, at: t0, &gesture)
        XCTAssertEqual(process([], at: t0.addingTimeInterval(2.0), &gesture), .clear)
    }

    /// A key used while the hyper is down means the user was typing with it: no Escape.
    func testUsedHyperDoesNotDismiss() {
        var gesture = HyperEscape()
        _ = process(hyper, at: t0, &gesture)
        gesture.noteKeyUsed()
        XCTAssertEqual(process([], at: t0.addingTimeInterval(0.5), &gesture), .clear)
    }

    /// A non-hyper modifier set while armed clears the arm and falls through to narrowing.
    func testOtherModifiersClearTheArm() {
        var gesture = HyperEscape()
        _ = process(hyper, at: t0, &gesture)
        XCTAssertEqual(process([.command], at: t0.addingTimeInterval(0.5), &gesture), .clear)
        XCTAssertNil(gesture.armedAt)
    }

    /// Without an arm, an ordinary flags change does nothing.
    func testNoArmMeansNothing() {
        var gesture = HyperEscape()
        XCTAssertEqual(process([.command], at: t0, &gesture), .none)
    }

    /// Repeating the hyper press keeps the same arm (the start time survives).
    func testRepeatedHyperPressKeepsTheArm() {
        var gesture = HyperEscape()
        _ = process(hyper, at: t0, &gesture)
        XCTAssertEqual(process(hyper, at: t0.addingTimeInterval(0.2), &gesture), .arm)
        XCTAssertEqual(gesture.armedAt, t0)
    }
}
