import XCTest
@testable import KagiPeekCore

/// 面板一页的行要**竖着**填进列里，而且每列先填满再换列。
///
/// 两件事一起才是用户要的样子：按列读（不是横向铺开），以及**装满一列的高度**再换下一列
/// （不是把一页均摊）。均摊的后果是卡片比窗口矮一截：50 行分三列会摊成 17·17·16，而窗口
/// 明明能显示约 27 行。
///
/// 面板的方向键走的就是这一页的行顺序，所以列内顺序必须与键盘顺序一致。
final class PanelColumnFillTests: XCTestCase {
    /// 容量够时只填前面几列，最后一列可以空着 —— 这就是「先填满前两列」。
    func testFillsColumnsToCapacityBeforeMovingRight() {
        let rows = Array(0..<50)
        let split = PanelColumnFill.split(rows, into: 3, capacity: 31)
        XCTAssertEqual(split.map(\.count), [31, 19, 0])
        XCTAssertEqual(split.flatMap { $0 }, rows)
    }

    /// 24 行 + 13 行/列：两列装完，第三列空着，卡片高度是 13 行而不是 8 行。
    func testTallWindowUsesTheColumnsItNeedsAndLeavesTheRestEmpty() {
        let split = PanelColumnFill.split(Array(0..<24), into: 3, capacity: 13)
        XCTAssertEqual(split.map(\.count), [13, 11, 0])
    }

    /// 一页正好装满时，三列都用上。
    func testFullPageSpreadsAcrossEveryColumn() {
        let split = PanelColumnFill.split(Array(0..<9), into: 3, capacity: 3)
        XCTAssertEqual(split.map(\.count), [3, 3, 3])
    }

    /// 容量装不下整页时退回均摊：宁可摊薄，也不能丢行或让行溢出卡片。
    func testCapacityThatCannotHoldThePageFallsBackToAnEvenSplit() {
        let rows = Array(0..<10)
        let split = PanelColumnFill.split(rows, into: 3, capacity: 2) // 3 × 2 < 10
        XCTAssertEqual(split.map(\.count), [4, 3, 3])
        XCTAssertEqual(split.flatMap { $0 }, rows)
    }

    /// 摊平必须原样还原：不丢、不重、不换位置。
    func testFlatteningAlwaysRestoresThePageOrder() {
        for count in 0...53 {
            for columns in 1...4 {
                for capacity in [0, 1, 2, 3, 5, 13, 31, 60] {
                    let split = PanelColumnFill.split(Array(0..<count), into: columns, capacity: capacity)
                    XCTAssertEqual(split.flatMap { $0 }, Array(0..<count),
                                   "count \(count) columns \(columns) capacity \(capacity)")
                    XCTAssertEqual(split.count, max(1, columns),
                                   "count \(count) columns \(columns) capacity \(capacity)")
                }
            }
        }
    }

    func testDegenerateInputs() {
        // 列数小于 1 按单列算。
        XCTAssertEqual(PanelColumnFill.split(Array(0..<5), into: 0, capacity: 2), [Array(0..<5)])
        XCTAssertEqual(PanelColumnFill.split(Array(0..<5), into: -2, capacity: 2), [Array(0..<5)])
        // 容量小于 1 按 1 算。
        XCTAssertEqual(PanelColumnFill.split(Array(0..<3), into: 3, capacity: 0), [[0], [1], [2]])
        XCTAssertEqual(PanelColumnFill.split(Array(0..<3), into: 1, capacity: 0), [Array(0..<3)])
        // 空页。
        XCTAssertEqual(PanelColumnFill.split([Int](), into: 3, capacity: 13), [[], [], []])
    }
}
