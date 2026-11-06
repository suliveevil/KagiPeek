import XCTest
@testable import KanameCore

/// 切 Space 后的重扫节流与「空结果不覆盖旧列表」的判定。
///
/// 一次切换可能连着来几条通知，同一个 App 在窗口内的请求被合并；而重扫撞上菜单栏
/// 还没挂回来的那一刻，空列表不能把用户眼前的目录清掉。
final class SpaceRescanGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testRepeatedRequestForTheSameAppInsideTheWindowIsMerged() {
        var gate = SpaceRescanGate(interval: 0.75)
        XCTAssertTrue(gate.shouldScan(pid: 42, at: start))
        XCTAssertFalse(gate.shouldScan(pid: 42, at: start.addingTimeInterval(0.3)))
        XCTAssertTrue(gate.shouldScan(pid: 42, at: start.addingTimeInterval(1.0)))
    }

    func testAnotherAppScansImmediately() {
        var gate = SpaceRescanGate(interval: 0.75)
        XCTAssertTrue(gate.shouldScan(pid: 42, at: start))
        XCTAssertTrue(gate.shouldScan(pid: 43, at: start.addingTimeInterval(0.1)))
    }

    func testDefaultIntervalIsUnderASecond() {
        let gate = SpaceRescanGate()
        XCTAssertEqual(gate.interval, 0.75)
    }

    // MARK: - 发布策略

    func testEmptyRescanWithoutAMenuBarKeepsThePreviousList() {
        XCTAssertTrue(
            CatalogPublishPolicy.keepsPrevious(previousCount: 20, newCount: 0, hasMenuBar: false)
        )
    }

    func testEmptyRescanWithAMenuBarPublishesTheEmptyList() {
        XCTAssertFalse(
            CatalogPublishPolicy.keepsPrevious(previousCount: 20, newCount: 0, hasMenuBar: true)
        )
    }

    func testEmptyRescanWithNoPreviousListHasNothingToKeep() {
        XCTAssertFalse(
            CatalogPublishPolicy.keepsPrevious(previousCount: 0, newCount: 0, hasMenuBar: false)
        )
    }
}
