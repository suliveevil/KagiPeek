import XCTest
@testable import KagiPeekCore

// 面板现在有两个分区：前台 App 的命令在前，系统热键在后，两个分区不交错。
// 分区内部沿用原来的和弦排序，所以这些测试只需要钉住「边界」和「不交错」。

final class PanelSectionsTests: XCTestCase {
    private func item(_ title: String, chord: KeyChord, source: BindingSource = .menu, bundle: String? = "com.example.App") -> BindingItem {
        BindingItem(chord: chord, title: title, group: ["File"], source: source, appBundleID: bundle)
    }

    private func hit(_ title: String, chord: KeyChord, bundle: String? = "com.example.App") -> PrefixHit {
        let item = item(title, chord: chord, bundle: bundle)
        return PrefixHit(item: item, nextKey: chord.steps.first?.key, remainingSteps: 0, relation: .exact)
    }

    func testAppSectionComesEntirelyBeforeSystemSection() {
        let app = [hit("Copy", chord: .combo([.command], KeyToken("c")))]
        let system = PanelSections.hits(for: [
            item("Screenshot", chord: .combo([.command, .shift], KeyToken("3")), source: .system, bundle: nil)
        ])
        let entries = PanelSections.combine(app: app, system: system)
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(entries[0].isSystem)
        XCTAssertTrue(entries[1].isSystem)
        XCTAssertEqual(PanelSections.boundary(in: entries), 1)
    }

    func testOrderInsideEachSectionIsUntouched() {
        // combine 只做拼接：分区内的先后由 PanelOrdering 决定，这里不应该被重排。
        let app = [
            hit("Second", chord: .combo([.command], KeyToken("v"))),
            hit("First", chord: .combo([.command], KeyToken("c")))
        ]
        let system = PanelSections.hits(for: [
            item("B", chord: .combo([.command, .shift], KeyToken("b")), source: .system, bundle: nil),
            item("A", chord: .combo([.command, .shift], KeyToken("a")), source: .system, bundle: nil)
        ])
        let entries = PanelSections.combine(app: app, system: system)
        XCTAssertEqual(entries.map(\.hit.item.title), ["Second", "First", "B", "A"])
    }

    func testWithoutSystemRowsThereIsNoBoundary() {
        let entries = PanelSections.combine(
            app: [hit("Copy", chord: .combo([.command], KeyToken("c")))],
            system: []
        )
        XCTAssertNil(PanelSections.boundary(in: entries))
        XCTAssertEqual(entries.count, 1)
    }

    /// 系统热键是单键和弦，没有「下一键」可言；包装成行时不能造出一个假的 chevron。
    func testSystemHitsAreCompleteRows() {
        let hits = PanelSections.hits(for: [
            item("Screenshot", chord: .combo([.command, .shift], KeyToken("3")), source: .system, bundle: nil)
        ])
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits[0].nextKey)
        XCTAssertEqual(hits[0].remainingSteps, 0)
        XCTAssertTrue(hits[0].item.chord.isFinalStroke(after: .empty))
    }
}
