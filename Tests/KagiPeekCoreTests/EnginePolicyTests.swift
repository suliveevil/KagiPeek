import XCTest
@testable import KagiPeekCore

final class EnginePolicyTests: XCTestCase {
    func testDisabledRowsAreNotActionable() {
        XCTAssertFalse(RowEligibility.canActivate(isEnabled: false))
        XCTAssertTrue(RowEligibility.canActivate(isEnabled: true))
    }

    func testConflictScanOutcomeKeepsPartialCoverageVisible() {
        XCTAssertEqual(ConflictScanState.finished(successes: 3, failures: 0), .complete)
        XCTAssertEqual(ConflictScanState.finished(successes: 3, failures: 1), .partial(failed: 1))
        XCTAssertEqual(ConflictScanState.finished(successes: 0, failures: 2), .failed)
    }
}
