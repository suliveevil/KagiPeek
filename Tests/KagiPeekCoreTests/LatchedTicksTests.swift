import XCTest
@testable import KagiPeekCore

final class LatchedTicksTests: XCTestCase {
    /// 撤销的是最后点的那个，不是 ⌃⌥⇧⌘ 顺序里的最后一个。
    func testPopRemovesTheMostRecentTick() {
        var state = (latched: ModifierSet(), order: [ModifierSet]())
        state = LatchedTicks.toggling([.command], latched: state.latched, order: state.order)
        state = LatchedTicks.toggling([.option], latched: state.latched, order: state.order)
        XCTAssertEqual(state.order, [.command, .option])
        let popped = LatchedTicks.popping(latched: state.latched, order: state.order)
        XCTAssertEqual(popped?.latched, [.command])
        XCTAssertEqual(popped?.order, [.command])
    }

    /// 再点一次同一个修饰键是取消，且不留顺序残渣。
    func testTickingTwiceUnticks() {
        let first = LatchedTicks.toggling([.option], latched: [], order: [])
        let second = LatchedTicks.toggling([.option], latched: first.latched, order: first.order)
        XCTAssertTrue(second.latched.isEmpty)
        XCTAssertTrue(second.order.isEmpty)
        XCTAssertNil(LatchedTicks.popping(latched: second.latched, order: second.order))
    }

    /// 没有 tick 时撤销返回 nil，让 ⌫ 落到"返回上一级"那层含义上。
    func testPoppingNothingReturnsNil() {
        XCTAssertNil(LatchedTicks.popping(latched: [], order: []))
    }
}
