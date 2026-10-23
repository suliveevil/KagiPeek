import XCTest
@testable import KagiPeekCore

/// macOS 不给符号热键名称（233 条全空），名字只能我们来。这里钉住「认识的给名字、不认识的不乱猜」。
final class SystemHotkeyNamesTests: XCTestCase {
    func testKnownSystemShortcutsHaveNames() {
        let spot = KeyChord.combo([.command], KeyToken("space"))
        XCTAssertEqual(SystemHotkeyNames.name(for: spot, language: .english), "Spotlight")
        XCTAssertEqual(SystemHotkeyNames.name(for: spot, language: .chinese), "聚焦搜索")

        let shot = KeyChord.combo([.command, .shift], KeyToken("3"))
        XCTAssertEqual(SystemHotkeyNames.name(for: shot, language: .english), "Screenshot")

        let mission = KeyChord.combo([.control], KeyToken("up"))
        XCTAssertEqual(SystemHotkeyNames.name(for: mission, language: .chinese), "调度中心")
    }

    /// 用户改过的组合不再匹配表里的键，于是没有名字——比给一个错名字好。
    func testReassignedChordsStayUnnamed() {
        XCTAssertNil(SystemHotkeyNames.name(
            for: .combo([.command, .control, .option], KeyToken("9")),
            language: .english
        ))
        // 同一个键换掉修饰键也不再命中。
        XCTAssertNil(SystemHotkeyNames.name(for: .combo([.command], KeyToken("3")), language: .english))
    }

    /// 表里不能有重复的组合，否则哪条生效取决于字典顺序。
    func testEntriesAreUnique() {
        var seen = Set<String>()
        for entry in SystemHotkeyNames.entries {
            let key = "\(entry.modifiers.rawValue):\(KeyToken(entry.key).raw)"
            XCTAssertTrue(seen.insert(key).inserted, "duplicate: \(key)")
        }
    }

    /// 无名字的行靠这条契约显示「—」：读系统热键时给空标题，`BindingItem` 会把它变成占位符。
    /// 如果哪天把占位符改回「重复快捷键」，这条会先红。
    func testNamelessTitleBecomesAPlaceholder() {
        XCTAssertEqual(DescriptionCleaner.clean(""), DescriptionCleaner.placeholder)
        let item = BindingItem(
            chord: .combo([.control], KeyToken("f4")),
            title: "",
            group: [L10n.string(.groupSystemHotkeys, language: .english)],
            source: .system
        )
        XCTAssertEqual(item.title, DescriptionCleaner.placeholder)
    }

    /// 命名只对单步和弦有意义：多步和弦不该被表「认领」。第一步故意用表里有的 ⌘Space，
    /// 这样测的是「拒绝多步」这条规则，而不是「第一步恰好不认识」。
    func testMultiStepChordsAreNotNamed() {
        let sequence = KeyChord([
            .combo([.command], KeyToken("space")),
            .combo([.command], KeyToken("space"))
        ])
        XCTAssertNil(SystemHotkeyNames.name(for: sequence, language: .english))
    }
}
