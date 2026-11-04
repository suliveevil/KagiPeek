import CoreGraphics
import XCTest
@testable import KagiPeekCore

/// The panel must never draw a menu item under its footer or past the screen edge.
///
/// Every number here is pure arithmetic, so "the last row is hidden" is an assertion
/// rather than something only a screenshot could catch.
final class PanelFitTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// Header + rule + footer + the list's padding are the chrome; a row may never use it.
    func testChromeIsHeaderRuleFooterAndListPadding() {
        XCTAssertEqual(
            OverlayMetrics.chromeHeight,
            OverlayMetrics.headerHeight
                + OverlayMetrics.ruleHeight
                + OverlayMetrics.footerHeight
                + OverlayMetrics.contentTopPadding
                + OverlayMetrics.contentBottomPadding
        )
    }

    /// The user's 60 is an upper bound: a 720 pt window with two cards holds 36 rows, and
    /// asking for 60 used to put 24 of them under the footer.
    func testPageSizeIsCappedByGeometryNotByTheSetting() {
        XCTAssertEqual(
            OverlayMetrics.fittedPageSize(
                maxItemsPerPage: 60,
                columns: 2,
                panelHeight: 720,
                cardCount: 2,
                headingCount: 2
            ),
            36
        )
    }

    /// A small setting is still the answer when the window could hold more.
    func testSmallSettingWins() {
        XCTAssertEqual(
            OverlayMetrics.fittedPageSize(
                maxItemsPerPage: 10,
                columns: 2,
                panelHeight: 720,
                cardCount: 2,
                headingCount: 2
            ),
            10
        )
    }

    /// A panel shorter than its own chrome still guarantees one complete row.
    func testNoRoomStillShowsOneRow() {
        XCTAssertEqual(
            OverlayMetrics.rowsPerColumn(panelHeight: 100, cardCount: 1, headingCount: 0),
            1
        )
        XCTAssertEqual(
            OverlayMetrics.fittedPageSize(
                maxItemsPerPage: 24,
                columns: 2,
                panelHeight: 100,
                cardCount: 1,
                headingCount: 0
            ),
            2
        )
    }

    /// Exactly N rows must give N. A scaled display can compute 29.9999 for `available /
    /// rowHeight`; flooring that would silently drop the last row.
    func testExactHeightDoesNotLoseARowToRounding() {
        let cards = 2
        let headings = 2
        let fixed = OverlayMetrics.chromeHeight
            + CGFloat(headings) * OverlayMetrics.groupHeaderHeight
            + CGFloat(cards) * (OverlayMetrics.cardVerticalInset * 2)
            + OverlayMetrics.cardRuleHeight
            + CGFloat(cards - 1) * OverlayMetrics.cardGap
        XCTAssertEqual(
            OverlayMetrics.rowsPerColumn(
                panelHeight: fixed + 10 * OverlayMetrics.rowHeight,
                cardCount: cards,
                headingCount: headings
            ),
            10
        )
        // One hundredth of a point of slack still reads as the tenth row, not nine.
        XCTAssertEqual(
            OverlayMetrics.rowsPerColumn(
                panelHeight: fixed + 10 * OverlayMetrics.rowHeight + 0.01,
                cardCount: cards,
                headingCount: headings
            ),
            10
        )
        XCTAssertEqual(
            OverlayMetrics.rowsPerColumn(
                panelHeight: fixed + 9 * OverlayMetrics.rowHeight + 0.5,
                cardCount: cards,
                headingCount: headings
            ),
            9
        )
    }

    /// A frame hanging off the bottom of the screen is moved up as a whole, never stretched.
    func testFrameNearTheBottomEdgeIsShiftedUp() {
        let frame = CGRect(x: 100, y: -40, width: 600, height: 700)
        let result = OverlayPlacement.containedFrame(frame, in: screen)
        XCTAssertEqual(result.origin.y, screen.minY + OverlayPlacement.screenMargin)
        XCTAssertEqual(result.size, frame.size)
    }

    /// A frame that already fits is left alone.
    func testFittingFrameIsNotMoved() {
        let frame = CGRect(x: 200, y: 90, width: 600, height: 500)
        XCTAssertEqual(OverlayPlacement.containedFrame(frame, in: screen), frame)
    }

    /// A panel taller than the screen keeps its bottom edge visible, so at least the first
    /// rows (and the footer) are on screen and the panel is shifted rather than clipped.
    func testFrameTallerThanTheScreenAnchorsAtTheBottom() {
        let frame = CGRect(x: 0, y: -120, width: 600, height: 1000)
        let result = OverlayPlacement.containedFrame(frame, in: screen)
        XCTAssertEqual(result.origin.y, screen.minY + OverlayPlacement.screenMargin)
        XCTAssertEqual(result.size, frame.size)
    }

    /// The closed-loop pagination keeps its semantics; only the page count follows the new
    /// page size.
    func testPageCountUsesTheFittedPageSize() {
        let pageSize = 6
        let total = 20
        let pageCount = Int(ceil(Double(total) / Double(pageSize)))
        XCTAssertEqual(pageCount, 4)
        XCTAssertEqual(PaginationPlan.nextPage(from: pageCount - 1, pageCount: pageCount), 0)
        XCTAssertEqual(PaginationPlan.previousPage(from: 0, pageCount: pageCount), pageCount - 1)
    }
}
