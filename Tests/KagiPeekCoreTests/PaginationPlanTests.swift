import XCTest
@testable import KagiPeekCore

/// Pins the loop rules: the ends of the list connect, and a one-page list does not move.
final class PaginationPlanTests: XCTestCase {
    func testNextPageWrapsFromLastToFirst() {
        XCTAssertEqual(PaginationPlan.nextPage(from: 2, pageCount: 3), 0)
        XCTAssertEqual(PaginationPlan.nextPage(from: 0, pageCount: 3), 1)
        XCTAssertEqual(PaginationPlan.nextPage(from: 1, pageCount: 3), 2)
    }

    func testPreviousPageWrapsFromFirstToLast() {
        XCTAssertEqual(PaginationPlan.previousPage(from: 0, pageCount: 3), 2)
        XCTAssertEqual(PaginationPlan.previousPage(from: 2, pageCount: 3), 1)
        XCTAssertEqual(PaginationPlan.previousPage(from: 1, pageCount: 3), 0)
    }

    func testSinglePageDoesNotMoveInEitherDirection() {
        XCTAssertEqual(PaginationPlan.nextPage(from: 0, pageCount: 1), 0)
        XCTAssertEqual(PaginationPlan.previousPage(from: 0, pageCount: 1), 0)
        XCTAssertFalse(PaginationPlan.moved(from: 0, to: PaginationPlan.nextPage(from: 0, pageCount: 1), pageCount: 1))
        XCTAssertFalse(PaginationPlan.moved(from: 0, to: PaginationPlan.previousPage(from: 0, pageCount: 1), pageCount: 1))
    }

    func testMovedReportsAnActualPageChange() {
        XCTAssertTrue(PaginationPlan.moved(from: 0, to: PaginationPlan.nextPage(from: 0, pageCount: 3), pageCount: 3))
        XCTAssertTrue(PaginationPlan.moved(from: 2, to: PaginationPlan.nextPage(from: 2, pageCount: 3), pageCount: 3))
        XCTAssertTrue(PaginationPlan.moved(from: 0, to: PaginationPlan.previousPage(from: 0, pageCount: 3), pageCount: 3))
        XCTAssertFalse(PaginationPlan.moved(from: 1, to: 1, pageCount: 3))
    }

    func testPageIndexStaysInsideAfterTheCountChanges() {
        // The count shrank under the user: the index has to be clamped before it can move.
        XCTAssertEqual(PaginationPlan.clamped(5, pageCount: 2), 1)
        XCTAssertEqual(PaginationPlan.nextPage(from: 5, pageCount: 2), 0)
        XCTAssertEqual(PaginationPlan.previousPage(from: 5, pageCount: 2), 0)
        XCTAssertEqual(PaginationPlan.clamped(9, pageCount: 1), 0)
        XCTAssertEqual(PaginationPlan.clamped(-3, pageCount: 4), 0)
    }

    func testEmptyListBehavesLikeOnePage() {
        XCTAssertEqual(PaginationPlan.nextPage(from: 0, pageCount: 0), 0)
        XCTAssertEqual(PaginationPlan.previousPage(from: 0, pageCount: 0), 0)
        XCTAssertFalse(PaginationPlan.moved(from: 0, to: 0, pageCount: 0))
    }
}
