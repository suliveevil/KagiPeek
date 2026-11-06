import XCTest
@testable import KanameCore

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

    // MARK: Tab

    /// 搜索框有焦点时，裸 Tab 归字段编辑器的焦点遍历，不切表面。
    /// 只在面板层（没有文本输入）用 Tab 切到搜索。
    func testBareTabPassesThroughWhileSearchHasFocus() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.tab, modifiers: [], isQueryEmpty: false),
            .passThrough
        )
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.tab, modifiers: [], isQueryEmpty: true),
            .passThrough
        )
    }

    /// ⇧Tab 仍是系统焦点键，不拦。
    func testShiftTabPassesThrough() {
        XCTAssertEqual(
            SearchKeyRouter.action(keyCode: KeyCode.tab, modifiers: [.shift], isQueryEmpty: false),
            .passThrough
        )
    }

    // MARK: 普通字符

    /// 翻页字符在搜索框里是输入内容：无论 开关有没有勾选，八次按键都透传。
    func testPagingCharactersPassThroughTheSearchField() {
        let keys: [(UInt16, ModifierSet)] = [
            (KeyCode.comma, []), (KeyCode.period, []),
            (KeyCode.leftBracket, []), (KeyCode.rightBracket, []),
            (KeyCode.minus, []), (KeyCode.equal, []),
            (KeyCode.semicolon, []), (KeyCode.quote, [])
        ]
        for (keyCode, modifiers) in keys {
            XCTAssertEqual(
                SearchKeyRouter.action(keyCode: keyCode, modifiers: modifiers, isQueryEmpty: true),
                .passThrough
            )
            XCTAssertEqual(
                SearchKeyRouter.action(keyCode: keyCode, modifiers: modifiers, isQueryEmpty: false),
                .passThrough
            )
        }
    }

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
