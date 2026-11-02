import XCTest
@testable import KagiPeekCore

final class OutsideClickTests: XCTestCase {
    private let app = ScreenRect(x: 100, y: 100, width: 800, height: 600)
    private let panel = ScreenRect(x: 300, y: 200, width: 400, height: 300)

    /// 点在前台 App 窗口里、面板外 —— 那一次点击只该关面板，不该点中后面的 App。
    func testPressPastThePanelIsSwallowed() {
        XCTAssertTrue(OutsideClickPolicy.shouldSwallow(point: (700, 600), panel: panel, app: app))
    }

    /// 点在面板上是面板自己的事，不能吞。
    func testPressOnThePanelIsNotSwallowed() {
        XCTAssertFalse(OutsideClickPolicy.shouldSwallow(point: (450, 350), panel: panel, app: app))
    }

    /// 点在前台 App 之外 —— 菜单栏、Dock、桌面、别的 App —— 是用户在拿别的东西，吞掉会像卡屏。
    func testPressOutsideTheAppIsNotSwallowed() {
        XCTAssertFalse(OutsideClickPolicy.shouldSwallow(point: (50, 50), panel: panel, app: app))
        XCTAssertFalse(OutsideClickPolicy.shouldSwallow(point: (950, 800), panel: panel, app: app))
    }

    /// 面板盖住整个窗口时（coverWindow），窗口里的点击都落在面板上，没有可吞的。
    func testPanelCoveringTheWindowLeavesNothingToSwallow() {
        let covering = app
        XCTAssertFalse(OutsideClickPolicy.shouldSwallow(point: (500, 400), panel: covering, app: app))
    }

    func testRectContainsUsesHalfOpenEdges() {
        let rect = ScreenRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertTrue(rect.contains(x: 0, y: 0))
        XCTAssertFalse(rect.contains(x: 10, y: 10))
    }
}
