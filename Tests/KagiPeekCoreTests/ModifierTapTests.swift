import XCTest
@testable import KagiPeekCore

final class ModifierTapTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let window: TimeInterval = 0.35

    /// Emacs 式的点一下就粘住：按下、很快松开、中间没按别的键。
    func testQuickReleaseTicks() {
        var tracker = ModifierTapTracker()
        XCTAssertNil(tracker.flagsChanged([.option], previous: [], now: start, window: window))
        let tapped = tracker.flagsChanged([], previous: [.option], now: start.addingTimeInterval(0.1), window: window)
        XCTAssertEqual(tapped, [.option])
    }

    /// 按住不放是"看一眼"，不是"点一下"：超时松开什么也不粘。
    func testHoldingIsNotATap() {
        var tracker = ModifierTapTracker()
        tracker.flagsChanged([.command], previous: [], now: start, window: window)
        let tapped = tracker.flagsChanged([], previous: [.command], now: start.addingTimeInterval(0.9), window: window)
        XCTAssertNil(tapped)
    }

    /// 修饰键期间按了别的键 ⇒ 它是某个快捷键的一半，不是点按。
    func testModifierUsedWithAKeyIsNotATap() {
        var tracker = ModifierTapTracker()
        tracker.flagsChanged([.command], previous: [], now: start, window: window)
        tracker.noteKeyPress()
        let tapped = tracker.flagsChanged([], previous: [.command], now: start.addingTimeInterval(0.1), window: window)
        XCTAssertNil(tapped)
    }

    /// 面板打开时手还按着修饰键（按住唤出）：那是触发器，不能算点按。
    func testPressAlreadyDownWhenThePanelOpenedIsNotATap() {
        var tracker = ModifierTapTracker()
        tracker.flagsChanged([.command], previous: [.command], now: start, window: window)
        let tapped = tracker.flagsChanged([], previous: [.command], now: start.addingTimeInterval(0.05), window: window)
        XCTAssertNil(tapped)
    }

    /// 两个修饰键一起点（滚动着按下）仍然是一次点按，带着两个键。
    func testRolledPressCarriesBothModifiers() {
        var tracker = ModifierTapTracker()
        tracker.flagsChanged([.option], previous: [], now: start, window: window)
        tracker.flagsChanged([.option, .command], previous: [.option], now: start.addingTimeInterval(0.05), window: window)
        let tapped = tracker.flagsChanged([], previous: [.option, .command], now: start.addingTimeInterval(0.12), window: window)
        XCTAssertEqual(tapped, [.option, .command])
    }

    /// 一次点按只兑现一次：松开之后再松开，不该又粘一遍。
    func testTapIsDeliveredOnce() {
        var tracker = ModifierTapTracker()
        tracker.flagsChanged([.option], previous: [], now: start, window: window)
        XCTAssertEqual(
            tracker.flagsChanged([], previous: [.option], now: start.addingTimeInterval(0.1), window: window),
            [.option]
        )
        XCTAssertNil(tracker.flagsChanged([], previous: [], now: start.addingTimeInterval(0.2), window: window))
    }
}
