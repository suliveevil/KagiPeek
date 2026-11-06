import XCTest
@testable import KanameCore

final class DisabledNoticeGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    /// The first click explains itself.
    func testFirstClickShows() {
        var gate = DisabledNoticeGate()
        XCTAssertTrue(gate.shouldShow(rowID: "r1", at: start))
    }

    /// Clicking the same row again inside three seconds stays silent.
    func testRepeatWithinIntervalIsQuiet() {
        var gate = DisabledNoticeGate()
        XCTAssertTrue(gate.shouldShow(rowID: "r1", at: start))
        XCTAssertFalse(gate.shouldShow(rowID: "r1", at: start.addingTimeInterval(2.9)))
    }

    /// After three seconds the same row may speak again.
    func testRepeatAfterIntervalShows() {
        var gate = DisabledNoticeGate()
        XCTAssertTrue(gate.shouldShow(rowID: "r1", at: start))
        XCTAssertTrue(gate.shouldShow(rowID: "r1", at: start.addingTimeInterval(3)))
    }

    /// A different row is a new question and gets its own answer immediately.
    func testAnotherRowShowsImmediately() {
        var gate = DisabledNoticeGate()
        XCTAssertTrue(gate.shouldShow(rowID: "r1", at: start))
        XCTAssertTrue(gate.shouldShow(rowID: "r2", at: start.addingTimeInterval(0.5)))
    }
}
