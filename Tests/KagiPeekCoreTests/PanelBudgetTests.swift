import XCTest
@testable import KagiPeekCore

final class PanelBudgetTests: XCTestCase {
    func testEmptyListDoesNotReserveAPage() {
        XCTAssertEqual(PanelBudget.budget(totalRows: 0, pageSize: 24, headings: 2), .init(rows: 0, headings: 0))
    }

    func testSmallListReservesOnlyItsRows() {
        XCTAssertEqual(PanelBudget.budget(totalRows: 3, pageSize: 24, headings: 2), .init(rows: 3, headings: 2))
    }

    func testFullListIsCappedAtPageSize() {
        XCTAssertEqual(PanelBudget.budget(totalRows: 80, pageSize: 24, headings: 2), .init(rows: 24, headings: 2))
    }
}
