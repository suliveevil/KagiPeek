import XCTest
@testable import KanameCore

final class PermissionGuidePlacementTests: XCTestCase {
    // A common single-screen layout: 1920×1080 panel with a 25 pt menu bar / dock area.
    private let visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)
    private let panelSize = CGSize(width: 300, height: 170)

    // MARK: - CG → AppKit flip

    func testFlipMovesBottomLeftOriginUnderTopLeftOrigin() {
        // A window 100 pt from the CG top of a 1440-tall screen is 340 pt below the
        // AppKit top once flipped.
        let flipped = PermissionGuidePlacement.appKitFrame(
            ofCGFrame: CGRect(x: 50, y: 100, width: 800, height: 600),
            appKitTopY: 1440
        )
        XCTAssertEqual(flipped.origin.x, 50)
        XCTAssertEqual(flipped.origin.y, 1440 - 100 - 600)
        XCTAssertEqual(flipped.width, 800)
        XCTAssertEqual(flipped.height, 600)
    }

    func testFlipKeepsAWindowAtTheCGTopAtTheAppKitTop() {
        let flipped = PermissionGuidePlacement.appKitFrame(
            ofCGFrame: CGRect(x: 0, y: 0, width: 100, height: 50),
            appKitTopY: 900
        )
        XCTAssertEqual(flipped.maxY, 900)
    }

    // MARK: - Anchoring

    func testAnchorsBelowWithRightEdgesAligned() {
        let settings = CGRect(x: 100, y: 500, width: 800, height: 600)
        let origin = PermissionGuidePlacement.anchoredOrigin(
            panelSize: panelSize,
            settingsFrame: settings,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(origin.x, settings.maxX - panelSize.width)
        XCTAssertEqual(origin.y, 500 - 12 - 170)
    }

    func testStacksAboveWhenBelowHasNoRoom() {
        // The Settings window sits too low for the bar to fit underneath.
        let settings = CGRect(x: 100, y: 100, width: 800, height: 600)
        let origin = PermissionGuidePlacement.anchoredOrigin(
            panelSize: panelSize,
            settingsFrame: settings,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(origin.y, settings.maxY + 12)
        XCTAssertEqual(origin.x, settings.maxX - panelSize.width)
    }

    func testClampsRightOverflowIntoVisibleFrame() {
        // The Settings window reaches past the screen's right edge; the right-aligned
        // bar would lose its own right side off-screen.
        let settings = CGRect(x: 1700, y: 500, width: 800, height: 600)
        let origin = PermissionGuidePlacement.anchoredOrigin(
            panelSize: panelSize,
            settingsFrame: settings,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(origin.x, visibleFrame.maxX - panelSize.width)
    }

    func testClampsOriginIntoVisibleFrame() {
        // A mostly off-screen Settings window (second display at a negative origin) whose
        // right edge still can't fit the bar: the right-aligned origin lands left of the
        // screen and has to be clamped in.
        let settings = CGRect(x: -400, y: 500, width: 600, height: 600)
        let origin = PermissionGuidePlacement.anchoredOrigin(
            panelSize: panelSize,
            settingsFrame: settings,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(origin.x, visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(origin.y, visibleFrame.minY)
    }

    func testMarginIsRespectedBetweenWindowAndPanel() {
        let settings = CGRect(x: 100, y: 500, width: 800, height: 600)
        let below = PermissionGuidePlacement.anchoredOrigin(
            panelSize: panelSize, settingsFrame: settings, visibleFrame: visibleFrame, margin: 20
        )
        XCTAssertEqual(below.y, 500 - 20 - 170)
    }

    // MARK: - Content area

    func testContentAreaDropsTheSidebar() {
        let settings = CGRect(x: 100, y: 500, width: 800, height: 600)
        let content = PermissionGuidePlacement.contentArea(settingsFrame: settings, sidebarWidth: 232)
        XCTAssertEqual(content.minX, 332)
        XCTAssertEqual(content.width, 568)
        XCTAssertEqual(content.height, 600)
    }

    func testUnknownSidebarWidthFallsBackToTheWholeWindow() {
        let settings = CGRect(x: 100, y: 500, width: 800, height: 600)
        XCTAssertEqual(
            PermissionGuidePlacement.contentArea(settingsFrame: settings, sidebarWidth: 0),
            settings
        )
        // A stale frame wider than the window must not produce a negative content area.
        XCTAssertEqual(
            PermissionGuidePlacement.contentArea(settingsFrame: settings, sidebarWidth: 900),
            settings
        )
    }

    // MARK: - Inside the window

    func testCentresUnderTheListAndHugsItsBottomEdge() {
        let settings = CGRect(x: 100, y: 500, width: 800, height: 600)
        let content = PermissionGuidePlacement.contentArea(settingsFrame: settings, sidebarWidth: 232)
        let origin = PermissionGuidePlacement.insideBottomCenterOrigin(
            panelSize: panelSize,
            contentArea: content,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(origin?.x, content.midX - panelSize.width / 2)
        XCTAssertEqual(origin?.y, content.minY + PermissionGuidePlacement.margin)
    }

    func testTooSmallAWindowHasNoInsidePosition() {
        let settings = CGRect(x: 100, y: 500, width: 400, height: 120)
        let content = PermissionGuidePlacement.contentArea(settingsFrame: settings, sidebarWidth: 232)
        XCTAssertNil(
            PermissionGuidePlacement.insideBottomCenterOrigin(
                panelSize: panelSize, contentArea: content, visibleFrame: visibleFrame
            )
        )
    }

    func testInsidePositionIsClampedToTheVisibleFrame() {
        // A Settings window mostly off the left screen edge: the centred position would fall
        // outside the visible frame and has to be clamped in.
        let settings = CGRect(x: -700, y: 500, width: 800, height: 600)
        let content = PermissionGuidePlacement.contentArea(settingsFrame: settings, sidebarWidth: 232)
        let origin = PermissionGuidePlacement.insideBottomCenterOrigin(
            panelSize: panelSize, contentArea: content, visibleFrame: visibleFrame
        )
        XCTAssertEqual(origin?.x, visibleFrame.minX)
    }

    // MARK: - Settings gone

    func testScreenCentreIsTheMiddleOfTheVisibleFrame() {
        let origin = PermissionGuidePlacement.screenCenterOrigin(
            panelSize: panelSize, visibleFrame: visibleFrame
        )
        XCTAssertEqual(origin.x, visibleFrame.midX - panelSize.width / 2)
        XCTAssertEqual(origin.y, visibleFrame.midY - panelSize.height / 2)
    }
}
