import XCTest
@testable import KanameCore

/// 面板执行闸门：一次只能有一个「正在运行」的行，且只有它自己能释放这个槽位。
///
/// 缓存回退的行要在后台重新走一遍菜单路径才能按下去，走路径期间用户可能再点一次；
/// 闸门把第二次点击挡掉，`endRunning` 的 rowID 匹配则让面板已经换了一屏之后的迟到
/// 完成不误清新的状态。
final class PanelRunGateTests: XCTestCase {
    func testFirstActivationClaimsTheSlot() {
        var panel = PanelState()
        XCTAssertNil(panel.runningRowID)
        XCTAssertTrue(panel.beginRunning(rowID: "row-a"))
        XCTAssertEqual(panel.runningRowID, "row-a")
    }

    func testSecondActivationIsRefusedWhileARunIsInFlight() {
        var panel = PanelState()
        XCTAssertTrue(panel.beginRunning(rowID: "row-a"))
        XCTAssertFalse(panel.beginRunning(rowID: "row-a"))
        XCTAssertFalse(panel.beginRunning(rowID: "row-b"))
        XCTAssertEqual(panel.runningRowID, "row-a")
    }

    func testRunCanBeClaimedAgainAfterItEnds() {
        var panel = PanelState()
        XCTAssertTrue(panel.beginRunning(rowID: "row-a"))
        panel.endRunning(rowID: "row-a")
        XCTAssertNil(panel.runningRowID)
        XCTAssertTrue(panel.beginRunning(rowID: "row-b"))
    }

    func testStaleCompletionDoesNotClearAnotherRowsRun() {
        var panel = PanelState()
        XCTAssertTrue(panel.beginRunning(rowID: "row-a"))
        panel.endRunning(rowID: "row-b")
        XCTAssertEqual(panel.runningRowID, "row-a")
    }

    /// 关掉面板就是关掉这次运行：`dismissPanel` 复位成 `.hidden`，迟到的完成不能再按。
    func testHiddenPanelHasNoRunInFlight() {
        var panel = PanelState()
        XCTAssertTrue(panel.beginRunning(rowID: "row-a"))
        panel = .hidden
        XCTAssertNil(panel.runningRowID)
    }
}
