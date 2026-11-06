import XCTest
@testable import KanameCore

/// The press that opens the panel is a trigger, never a filter.
final class TriggerNarrowGateTests: XCTestCase {
    /// Hold-to-open: the modifier is still down when the panel appears, so nothing narrows.
    func testTriggerHoldDoesNotNarrow() {
        XCTAssertEqual(
            TriggerNarrowGate.decision(waitingForRelease: true, triggerKeyDown: true),
            .wait
        )
    }

    /// The release edge clears the flag and returns without narrowing.
    func testTriggerReleaseDoesNotNarrow() {
        XCTAssertEqual(
            TriggerNarrowGate.decision(waitingForRelease: true, triggerKeyDown: false),
            .clearPending
        )
    }

    /// After the release, the next press is an ordinary modifier and narrows.
    func testPressAfterReleaseNarrows() {
        XCTAssertEqual(
            TriggerNarrowGate.decision(waitingForRelease: false, triggerKeyDown: true),
            .narrow
        )
        XCTAssertEqual(
            TriggerNarrowGate.decision(waitingForRelease: false, triggerKeyDown: false),
            .narrow
        )
    }

    /// A hotkey opens with no pending release, so later modifiers narrow normally.
    func testHotkeyTriggerDoesNotBlockLaterNarrowing() {
        XCTAssertEqual(
            TriggerNarrowGate.decision(waitingForRelease: false, triggerKeyDown: true),
            .narrow
        )
    }

    /// The double tap's second press may still be down when the panel opens: it waits, and
    /// the later separate press narrows.
    func testDoubleTapSecondPressWaits() {
        XCTAssertEqual(
            TriggerNarrowGate.decision(waitingForRelease: true, triggerKeyDown: true),
            .wait
        )
        XCTAssertEqual(
            TriggerNarrowGate.decision(waitingForRelease: false, triggerKeyDown: true),
            .narrow
        )
    }

    /// Shift never takes part in the gate: it is an ordinary modifier event, and while the
    /// trigger is held it is swallowed like any other; once the trigger is up it narrows
    /// the same way any other modifier does.
    func testShiftIsNotATrigger() {
        XCTAssertEqual(
            TriggerNarrowGate.decision(waitingForRelease: false, triggerKeyDown: false),
            .narrow
        )
        XCTAssertEqual(
            TriggerNarrowGate.decision(waitingForRelease: true, triggerKeyDown: true),
            .wait
        )
    }
}
