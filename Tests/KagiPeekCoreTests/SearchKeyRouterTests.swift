import XCTest
@testable import KagiPeekCore

// 钉住搜索框按键路由：物理方向键、Emacs 键、带修饰符的方向键、Esc、斜杠与普通字符各自
// 落到哪个动作。这部分逻辑原本埋在 UI 的本地事件监视器里、没有任何测试。
final class SearchKeyRouterTests: XCTestCase {

    // MARK: 物理方向键（无修饰符）

    func testBareVerticalArrowsMoveSelection() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.down, modifiers: [], isQueryEmpty: true),
            .moveSelection(delta: 1)
        )
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.up, modifiers: [], isQueryEmpty: true),
            .moveSelection(delta: -1)
        )
    }

    func testBareHorizontalArrowsPassThroughForCaret() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.left, modifiers: [], isQueryEmpty: true),
            .passThrough
        )
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.right, modifiers: [], isQueryEmpty: true),
            .passThrough
        )
    }

    // MARK: Emacs 键（纯 control）

    func testEmacsVerticalKeysMoveSelection() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.ctrlN, modifiers: [.control], isQueryEmpty: true),
            .moveSelection(delta: 1)
        )
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.ctrlP, modifiers: [.control], isQueryEmpty: true),
            .moveSelection(delta: -1)
        )
    }

    func testEmacsHorizontalKeysPassThrough() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.ctrlB, modifiers: [.control], isQueryEmpty: true),
            .passThrough
        )
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.ctrlF, modifiers: [.control], isQueryEmpty: true),
            .passThrough
        )
    }

    // MARK: 带其他修饰符的方向键

    func testVerticalArrowsWithOtherModifiersStillMoveSelection() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.down, modifiers: [.command], isQueryEmpty: true),
            .moveSelection(delta: 1)
        )
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.up, modifiers: [.shift], isQueryEmpty: true),
            .moveSelection(delta: -1)
        )
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.down, modifiers: [.option, .command], isQueryEmpty: true),
            .moveSelection(delta: 1)
        )
    }

    func testHorizontalArrowsWithOtherModifiersPassThrough() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.left, modifiers: [.command], isQueryEmpty: true),
            .passThrough
        )
    }

    /// 回归保护：⌃⌘P / ⌃⌥P 不能被当成纯 ⌃P 导航而吞掉。
    func testControlCombinedWithOtherModifierPassesThrough() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.ctrlP, modifiers: [.control, .command], isQueryEmpty: true),
            .passThrough
        )
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.ctrlP, modifiers: [.control, .option], isQueryEmpty: true),
            .passThrough
        )
    }

    // MARK: Esc

    func testEscapeCloses() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.escape, modifiers: [], isQueryEmpty: true),
            .close
        )
        // Esc 不检查修饰符，与原实现一致。
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.escape, modifiers: [.command], isQueryEmpty: true),
            .close
        )
    }

    // MARK: 斜杠

    func testBareSlashOnEmptyQueryReturnsToPanel() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.slash, modifiers: [], isQueryEmpty: true),
            .returnToPanel
        )
    }

    func testSlashWithTextOrModifiersPassesThrough() {
        // 有输入时斜杠是普通字符。
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.slash, modifiers: [], isQueryEmpty: false),
            .passThrough
        )
        // ⌘/ 是系统帮助快捷键，绝不拦截。
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.slash, modifiers: [.command], isQueryEmpty: true),
            .passThrough
        )
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.slash, modifiers: [.control], isQueryEmpty: true),
            .passThrough
        )
    }

    // MARK: 普通字符

    func testTypingPassesThrough() {
        // A 键的 keyCode 是 0。
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: 0, modifiers: [], isQueryEmpty: true),
            .passThrough
        )
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: 0, modifiers: [], isQueryEmpty: false),
            .passThrough
        )
    }
}
