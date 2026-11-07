import XCTest
@testable import KanameCore

/// The panel belongs to the app it was opened over. Losing that app closes it; a focus
/// hand-off that Kaname itself performs must not.
final class FocusDismissPolicyTests: XCTestCase {
    private func context(
        panelVisible: Bool = true,
        ownerPID: pid_t? = 100,
        currentPID: pid_t? = 100,
        currentIsSelf: Bool = false,
        isPreviewing: Bool = false
    ) -> FocusDismissPolicy.Context {
        FocusDismissPolicy.Context(
            panelVisible: panelVisible,
            ownerPID: ownerPID,
            currentPID: currentPID,
            currentIsSelf: currentIsSelf,
            isPreviewing: isPreviewing
        )
    }

    func testOwnerStillInFrontKeepsThePanel() {
        XCTAssertFalse(FocusDismissPolicy.shouldDismiss(context()))
    }

    /// A desktop switch or a full-screen app taking over: the rows on screen belong to a
    /// menu bar the user can no longer see.
    func testAnotherAppTakingFrontClosesThePanel() {
        XCTAssertTrue(FocusDismissPolicy.shouldDismiss(context(currentPID: 200)))
    }

    /// Returning from the search palette activates Kaname briefly before focus goes back
    /// to the app behind the panel. That late notification must not close a panel which was
    /// opened after it.
    func testSelfFrontmostIsATransitionNotASwitch() {
        XCTAssertFalse(
            FocusDismissPolicy.shouldDismiss(
                context(currentPID: pid_t(ProcessInfo.processInfo.processIdentifier), currentIsSelf: true)
            )
        )
    }

    /// macOS sometimes has no menu bar owner at all during a full-screen transition.
    func testUnknownCurrentAppDoesNotClose() {
        XCTAssertFalse(FocusDismissPolicy.shouldDismiss(context(currentPID: nil)))
    }

    /// A signal that cannot be attributed to a recorded panel session is ignored.
    func testMissingOwnerDoesNotClose() {
        XCTAssertFalse(FocusDismissPolicy.shouldDismiss(context(ownerPID: nil, currentPID: 200)))
    }

    func testZeroPIDsAreNotRealApps() {
        XCTAssertFalse(FocusDismissPolicy.shouldDismiss(context(ownerPID: 0, currentPID: 200)))
        XCTAssertFalse(FocusDismissPolicy.shouldDismiss(context(ownerPID: 100, currentPID: 0)))
    }

    func testHiddenPanelAndPreviewNeverClose() {
        XCTAssertFalse(FocusDismissPolicy.shouldDismiss(context(panelVisible: false, currentPID: 200)))
        XCTAssertFalse(FocusDismissPolicy.shouldDismiss(context(currentPID: 200, isPreviewing: true)))
    }
}

/// One switch can deliver three notifications. They must converge on one scan.
final class FocusRescanGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func plain() -> FocusRescanGate.Request {
        FocusRescanGate.Request(force: false, preserveOnEmpty: false)
    }
    private func forced() -> FocusRescanGate.Request {
        FocusRescanGate.Request(force: true, preserveOnEmpty: true)
    }

    func testSignalsFromOneEpisodeMergeIntoTheStrongestRequest() {
        var gate = FocusRescanGate()
        XCTAssertEqual(gate.absorb(plain(), pid: 100, at: start), plain())
        XCTAssertEqual(
            gate.absorb(forced(), pid: 100, at: start.addingTimeInterval(0.1)),
            forced()
        )
        XCTAssertEqual(gate.take(), forced())
    }

    /// Once the episode has been scanned, the late Space notification must not queue a
    /// second AX walk of the same menu bar.
    func testLateSignalFromAFinishedEpisodeIsIgnored() {
        var gate = FocusRescanGate()
        _ = gate.absorb(plain(), pid: 100, at: start)
        XCTAssertEqual(gate.take(), plain())
        XCTAssertNil(gate.absorb(forced(), pid: 100, at: start.addingTimeInterval(0.3)))
    }

    func testLaterSwitchStartsANewEpisode() {
        var gate = FocusRescanGate()
        _ = gate.absorb(plain(), pid: 100, at: start)
        _ = gate.take()
        XCTAssertEqual(
            gate.absorb(plain(), pid: 100, at: start.addingTimeInterval(1.0)),
            plain()
        )
    }

    /// A different app always gets its own scan, even inside the window.
    func testDifferentAppStartsANewEpisodeImmediately() {
        var gate = FocusRescanGate()
        _ = gate.absorb(plain(), pid: 100, at: start)
        XCTAssertEqual(gate.absorb(forced(), pid: 200, at: start.addingTimeInterval(0.05)), forced())
    }

    /// Merging a weaker request into a stronger one never downgrades it.
    func testMergeNeverWeakensTheRequest() {
        var gate = FocusRescanGate()
        _ = gate.absorb(forced(), pid: 100, at: start)
        XCTAssertEqual(gate.absorb(plain(), pid: 100, at: start.addingTimeInterval(0.1)), forced())
        XCTAssertEqual(gate.take(), forced())
    }

    func testTakeWithoutAPendingRequestIsNil() {
        var gate = FocusRescanGate()
        XCTAssertNil(gate.take())
        XCTAssertNil(gate.take())
    }
}
