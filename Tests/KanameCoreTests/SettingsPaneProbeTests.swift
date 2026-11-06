import XCTest
@testable import KanameCore

/// The one thing System Settings' preferences are still trusted for. The page identifier that
/// used to be read from the same domain was removed after it proved to report a stale page —
/// see `SettingsPaneProbe` — so what is left has to be right.
final class SettingsPaneProbeTests: XCTestCase {
    func testSidebarWidthComesFromTheFirstFrameRow() {
        let frame = "0.000000, 0.000000, 232.000000, 625.000000, NO, NO"
        XCTAssertEqual(SettingsPaneProbe.sidebarWidth(fromSplitFrame: frame), 232)
    }

    func testTheWidthIsTheThirdFieldRegardlessOfSpacing() {
        XCTAssertEqual(SettingsPaneProbe.sidebarWidth(fromSplitFrame: "0,0,215,625,NO,NO"), 215)
        XCTAssertEqual(
            SettingsPaneProbe.sidebarWidth(fromSplitFrame: "  0 , 0 , 180.5 , 600 , NO , NO "),
            180.5
        )
    }

    func testZeroOrMissingWidthIsNoOpinion() {
        XCTAssertNil(SettingsPaneProbe.sidebarWidth(fromSplitFrame: nil))
        XCTAssertNil(SettingsPaneProbe.sidebarWidth(fromSplitFrame: "0, 0, 0, 625, NO, NO"))
        XCTAssertNil(SettingsPaneProbe.sidebarWidth(fromSplitFrame: "not a frame"))
        XCTAssertNil(SettingsPaneProbe.sidebarWidth(fromSplitFrame: "0, 0"))
    }
}
