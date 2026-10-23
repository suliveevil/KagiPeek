import XCTest
@testable import KagiPeekCore

// 「最近操作」只有 30 条，环形覆盖的语义必须钉死：崩溃报告里最旧的一条被挤掉，
// 留下的永远是最新的 30 条且保持时间顺序。

final class RingBufferTests: XCTestCase {
    func testKeepsInsertionOrderUnderCapacity() {
        let buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        XCTAssertEqual(buffer.snapshot(), [1, 2])
        XCTAssertEqual(buffer.count, 2)
        XCTAssertFalse(buffer.isFull)
    }

    func testWrapOverwritesOldest() {
        let buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        XCTAssertEqual(buffer.snapshot(), [3, 4, 5])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertTrue(buffer.isFull)
    }

    func testExactlyCapacityDoesNotDropAnything() {
        let buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...3 { buffer.append(value) }
        XCTAssertEqual(buffer.snapshot(), [1, 2, 3])
    }

    func testEmptySnapshotIsEmpty() {
        let buffer = RingBuffer<ActionRecord>(capacity: 5)
        XCTAssertTrue(buffer.snapshot().isEmpty)
        XCTAssertEqual(buffer.count, 0)
    }

    func testRemoveAllEmptiesTheBuffer() {
        let buffer = RingBuffer<Int>(capacity: 2)
        buffer.append(1)
        buffer.removeAll()
        XCTAssertTrue(buffer.snapshot().isEmpty)
    }
}
