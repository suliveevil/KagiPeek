import XCTest
@testable import KagiPeekCore

/// The recovery branches of the drag guide. These are the states that cannot be reached by
/// hand in a test run — closing System Settings, navigating away, cancelling the password
/// prompt — so the table is the only place they are pinned down.
final class PermissionGuideStateTests: XCTestCase {
    // MARK: - Happy path

    func testStartsDraggingAndStaysWhileThePaneMatches() {
        XCTAssertEqual(PermissionGuideState.next(.dragging, on: .settingsAppeared), .dragging)
        XCTAssertEqual(PermissionGuideState.next(.dragging, on: .paneMatched), .dragging)
    }

    func testPromptAppearingMeansWaiting() {
        XCTAssertEqual(PermissionGuideState.next(.dragging, on: .sheetShown), .waiting)
        XCTAssertEqual(PermissionGuideState.next(.waiting, on: .sheetShown), .waiting)
    }

    // MARK: - Cancellation

    func testDismissedPromptCancelsOnlyAfterAWait() {
        XCTAssertEqual(PermissionGuideState.next(.waiting, on: .sheetDismissed), .cancelled)
    }

    func testDismissedPromptWhileStillDraggingIsNotACancellation() {
        // Some Settings windows raise a sheet of their own (a detached pane, a colour
        // picker). Reporting "cancelled" for one of those would be a lie about the user's
        // password prompt, so only a dismissal that interrupted a wait counts.
        XCTAssertEqual(PermissionGuideState.next(.dragging, on: .sheetDismissed), .dragging)
    }

    func testCancelledStaysCancelledUntilTheUserDragsAgain() {
        // macOS gives no signal for "the icon moved" before the prompt appears, so there is
        // nothing to transition on: the message has to survive the next ticks.
        XCTAssertEqual(PermissionGuideState.next(.cancelled, on: .paneMatched), .cancelled)
        XCTAssertEqual(PermissionGuideState.next(.cancelled, on: .settingsAppeared), .cancelled)
    }

    // MARK: - Recovery

    func testLostSettingsAlwaysMeansClosed() {
        XCTAssertEqual(PermissionGuideState.next(.dragging, on: .settingsLost), .settingsClosed)
        XCTAssertEqual(PermissionGuideState.next(.waiting, on: .settingsLost), .settingsClosed)
        XCTAssertEqual(PermissionGuideState.next(.cancelled, on: .settingsLost), .settingsClosed)
    }

    func testSettingsComingBackResumesDragging() {
        XCTAssertEqual(PermissionGuideState.next(.settingsClosed, on: .settingsAppeared), .dragging)
    }

    func testLeavingThePageIsRecoveredByComingBack() {
        XCTAssertEqual(PermissionGuideState.next(.dragging, on: .paneLeft), .leftPane)
        XCTAssertEqual(PermissionGuideState.next(.leftPane, on: .paneMatched), .dragging)
    }

    // MARK: - Grant wins

    func testGrantWinsOverEveryRecoveryMessage() {
        for phase in [PermissionGuidePhase.dragging, .waiting, .settingsClosed, .leftPane, .cancelled] {
            XCTAssertEqual(PermissionGuideState.next(phase, on: .granted), .granted, "\(phase)")
        }
    }

    func testGrantIsTerminal() {
        XCTAssertEqual(PermissionGuideState.next(.granted, on: .settingsLost), .granted)
        XCTAssertEqual(PermissionGuideState.next(.granted, on: .paneLeft), .granted)
        XCTAssertEqual(PermissionGuideState.next(.granted, on: .sheetDismissed), .granted)
    }

    // MARK: - What the panel shows

    func testOnlyTheDeadEndsCarryAButton() {
        XCTAssertEqual(PermissionGuideState.action(for: .settingsClosed), .openSettings)
        XCTAssertEqual(PermissionGuideState.action(for: .leftPane), .goBack)
        XCTAssertNil(PermissionGuideState.action(for: .dragging))
        XCTAssertNil(PermissionGuideState.action(for: .waiting))
        XCTAssertNil(PermissionGuideState.action(for: .cancelled))
        XCTAssertNil(PermissionGuideState.action(for: .granted))
    }

    func testTheDragSourceIsHiddenWhenThereIsNoListToDropInto() {
        XCTAssertTrue(PermissionGuideState.showsDragSource(.dragging))
        XCTAssertTrue(PermissionGuideState.showsDragSource(.waiting))
        XCTAssertTrue(PermissionGuideState.showsDragSource(.cancelled))
        XCTAssertFalse(PermissionGuideState.showsDragSource(.settingsClosed))
        XCTAssertFalse(PermissionGuideState.showsDragSource(.leftPane))
        XCTAssertFalse(PermissionGuideState.showsDragSource(.granted))
    }

    func testHeadlineUsesThePermissionNameWhileThingsAreFine() {
        XCTAssertEqual(
            PermissionGuideState.headlineKey(for: .dragging, permissionTitle: .permissionAccessibility),
            .permissionAccessibility
        )
        XCTAssertEqual(
            PermissionGuideState.headlineKey(for: .settingsClosed, permissionTitle: .permissionAccessibility),
            .permissionGuideSettingsClosed
        )
    }

    func testEveryPhaseHasItsOwnDetailLine() {
        let details: [L10nKey] = [
            .dragging, .waiting, .granted, .settingsClosed, .leftPane, .cancelled
        ].map { PermissionGuideState.detailKey(for: $0) }
        XCTAssertEqual(Set(details.map(\.rawValue)).count, details.count)
    }
}
