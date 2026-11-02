import XCTest
@testable import KagiPeekCore

/// The buffer that keeps the engine's copy of the event stream bounded.
///
/// Every case here is about a keyboard that has stopped answering: the property worth
/// protecting is that a wedged main thread cannot turn into a replay, and that a drop leaves
/// the panel reset rather than believing a stale modifier is still held.
final class InputMailboxTests: XCTestCase {
    private func event(_ key: KeyToken? = KeyToken("a"), repeat isRepeat: Bool = false) -> KeyEvent {
        KeyEvent(
            kind: .keyDown,
            modifiers: [],
            key: key,
            keyCode: 0,
            isRepeat: isRepeat,
            happenedAt: Date()
        )
    }

    func testBelowCapacityEverythingIsKeptInOrder() {
        var box = InputMailbox()
        var scheduled = 0
        for i in 0..<5 {
            if box.post(event(KeyToken("k\(i)"))) { scheduled += 1 }
        }
        let (events, dropped) = box.drain()
        XCTAssertEqual(events.map(\.key), (0..<5).map { KeyToken("k\($0)") })
        XCTAssertEqual(dropped, 0)
        // One hop for the whole burst, not one per event: that is the fix.
        XCTAssertEqual(scheduled, 1)
    }

    func testTheFirstPostAsksForADrainAndLaterOnesDoNot() {
        var box = InputMailbox()
        XCTAssertTrue(box.post(event()))
        XCTAssertFalse(box.post(event()))
        XCTAssertFalse(box.post(event()))

        _ = box.drain()
        // Empty again, so the next event has to ask for its own drain.
        XCTAssertTrue(box.post(event()))
    }

    func testAFullBufferDropsInsteadOfGrowing() {
        var box = InputMailbox()
        for _ in 0..<InputMailbox.capacity {
            XCTAssertFalse(box.isFull)
            _ = box.post(event())
        }
        XCTAssertTrue(box.isFull)
        XCTAssertFalse(box.post(event()), "a full buffer must not ask for a drain")

        let (events, dropped) = box.drain()
        // capacity events plus the one reset the drop made necessary: bounded at capacity + 1.
        XCTAssertEqual(events.count, InputMailbox.capacity + 1)
        XCTAssertEqual(events.last?.kind, .interruption)
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(box.totalDropped, 1)
    }

    func testDroppingOwesExactlyOneResetAtTheEndOfTheNextBatch() {
        var box = InputMailbox()
        for _ in 0..<InputMailbox.capacity { _ = box.post(event()) }
        for _ in 0..<10 { _ = box.post(event()) }   // ten more, all dropped

        let (events, dropped) = box.drain()
        XCTAssertEqual(dropped, 10)
        XCTAssertEqual(events.count, InputMailbox.capacity + 1)
        XCTAssertEqual(events.last?.kind, .interruption, "the reset goes last, after the burst")
        XCTAssertFalse(box.owesReset, "the debt is paid once")

        // And it is not charged again on the next drain.
        let (next, nextDropped) = box.drain()
        XCTAssertTrue(next.isEmpty)
        XCTAssertEqual(nextDropped, 0)
    }

    func testNoResetIsInventedWhenNothingWasDropped() {
        var box = InputMailbox()
        _ = box.post(event())
        let (events, _) = box.drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.last?.kind, .keyDown)
    }

    func testCapacityIsFreedByADrainSoTheNextBurstFits() {
        var box = InputMailbox()
        for _ in 0..<InputMailbox.capacity { _ = box.post(event()) }
        _ = box.drain()
        XCTAssertFalse(box.isFull)
        for _ in 0..<InputMailbox.capacity {
            XCTAssertFalse(box.isFull, "the drain must actually release the room")
            _ = box.post(event())
        }
    }

    func testResetForgetsTheQueueAndTheDebt() {
        var box = InputMailbox()
        for _ in 0..<InputMailbox.capacity { _ = box.post(event()) }
        _ = box.post(event())   // owes a reset
        box.reset()

        XCTAssertFalse(box.owesReset)
        XCTAssertTrue(box.queue.isEmpty)
        let (events, dropped) = box.drain()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(dropped, 0)
    }
}
