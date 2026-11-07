import XCTest
@testable import KanameCore

/// 按压失败要说清是哪一种失败：菜单栏读不到时的提示和普通失败不能共用一句话。
final class RunFailureNoticeTests: XCTestCase {
    func testAnUnreadableMenuBarGetsItsOwnSentence() {
        XCTAssertEqual(RunFailureNotice.key(scanState: .menuBarUnavailable), .panelRunMenuBarHidden)
    }

    func testEveryOtherFailureKeepsTheGenericSentence() {
        XCTAssertEqual(RunFailureNotice.key(scanState: .ok), .panelRunFailed)
        XCTAssertEqual(RunFailureNotice.key(scanState: .noMenus), .panelRunFailed)
        XCTAssertEqual(RunFailureNotice.key(scanState: .permissionDenied), .panelRunFailed)
    }
}
