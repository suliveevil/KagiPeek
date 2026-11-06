import XCTest
@testable import KanameCore

/// Fixtures are measured, not guessed: each raw value below was read from the running
/// Safari's menu bar through `AXMenuItemCmdModifiers` on 2026-11-04 (macOS 26), together
/// with what Safari renders for the same item.
final class MenuShortcutModifierTests: XCTestCase {
    func testCommandIsImpliedWithoutTheNoCommandBit() {
        let decoded = MenuShortcutModifiers.decode(rawValue: 0) // 新建窗口, ⌘N
        XCTAssertEqual(decoded.modifiers, [.command])
        XCTAssertFalse(decoded.suppressesCommand)
        XCTAssertTrue(decoded.isComplete)
    }

    func testShiftAndCommand() {
        let decoded = MenuShortcutModifiers.decode(rawValue: 1) // 退出登录, ⇧⌘Q
        XCTAssertEqual(decoded.modifiers.ordered, [.shift, .command])
        XCTAssertEqual(KeyFormatter.render(.combo(decoded.modifiers, "q"), style: .symbols), "⇧⌘Q")
    }

    func testOptionAndCommand() {
        let decoded = MenuShortcutModifiers.decode(rawValue: 2) // 强制退出…, ⌥⌘⎋
        XCTAssertEqual(decoded.modifiers.ordered, [.option, .command])
        XCTAssertEqual(KeyFormatter.render(.combo(decoded.modifiers, "esc"), style: .symbols), "⌥⌘⎋")
    }

    func testControlAndCommand() {
        let decoded = MenuShortcutModifiers.decode(rawValue: 4) // 锁屏, ⌃⌘Q
        XCTAssertEqual(decoded.modifiers.ordered, [.control, .command])
        XCTAssertEqual(KeyFormatter.render(.combo(decoded.modifiers, "q"), style: .symbols), "⌃⌘Q")
    }

    func testNoCommandWithoutModifiersIsABareShortcut() {
        let decoded = MenuShortcutModifiers.decode(rawValue: 8)
        XCTAssertTrue(decoded.modifiers.isEmpty)
        XCTAssertTrue(decoded.suppressesCommand)
        XCTAssertTrue(decoded.isComplete)
    }

    func testControlWithoutCommand() {
        let decoded = MenuShortcutModifiers.decode(rawValue: 12) // 显示下一个标签页, ⌃⇥
        XCTAssertEqual(decoded.modifiers.ordered, [.control])
        XCTAssertTrue(decoded.suppressesCommand)
    }

    /// The bug: 24 is Fn + No Command. Dropping bit 4 used to leave an empty modifier set,
    /// which replayed a bare `E` instead of Safari's `🌐E`.
    func testFunctionAlone() {
        let emoji = MenuShortcutModifiers.decode(rawValue: 24) // 表情与符号, 🌐E
        XCTAssertEqual(emoji.modifiers.ordered, [.function])
        XCTAssertTrue(emoji.suppressesCommand)
        XCTAssertTrue(emoji.isComplete)
        XCTAssertEqual(KeyFormatter.render(.combo(emoji.modifiers, "e"), style: .symbols), "🌐E")

        let fullScreen = MenuShortcutModifiers.decode(rawValue: 24) // 进入全屏幕, 🌐F
        XCTAssertEqual(KeyFormatter.render(.combo(fullScreen.modifiers, "f"), style: .symbols), "🌐F")
    }

    func testFunctionWithControl() {
        let decoded = MenuShortcutModifiers.decode(rawValue: 28) // 填充, 🌐⌃F
        XCTAssertEqual(decoded.modifiers.ordered, [.function, .control])
        XCTAssertTrue(decoded.suppressesCommand)
        XCTAssertEqual(KeyFormatter.render(.combo(decoded.modifiers, "f"), style: .symbols), "🌐⌃F")
    }

    func testUnknownBitsAreReportedNotDropped() {
        let decoded = MenuShortcutModifiers.decode(rawValue: (1 << 5) | (1 << 0))
        XCTAssertEqual(decoded.modifiers.ordered, [.shift, .command])
        XCTAssertEqual(decoded.unknownBits, 1 << 5)
        XCTAssertFalse(decoded.isComplete)
    }
}
