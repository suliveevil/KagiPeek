import XCTest
@testable import KagiPeekCore

final class PanelOrderingTests: XCTestCase {
    private func item(_ modifiers: ModifierSet, _ key: String, _ title: String) -> BindingItem {
        BindingItem(
            chord: .combo(modifiers, KeyToken(key)),
            title: title,
            group: ["Edit"],
            source: .menu
        )
    }

    /// The panel is a reference card ordered by the shortcut, not by the menu it came from.
    func testOrderIsTheShortcutItself() {
        let items = [
            item([.command], "v", "Paste"),
            item([.command], "c", "Copy"),
            item([.control], "a", "Beginning of Line"),
            item([], "f5", "Reload")
        ]
        let labels = PanelOrdering.sorted(items).map { KeyFormatter.render($0.chord, style: .symbols) }
        // 无修饰键的行先（F5 没有修饰键），然后 ⌘ 优先，⌃ 最后。
        XCTAssertEqual(labels, ["F5", "⌘C", "⌘V", "⌃A"])
    }

    /// 修饰键按重要性逐位比较（⌘ → ⌥ → ⌃ → ⇧），而不是先比个数：⌘C 必须最先出现，
    /// 且带 ⌘ 的行连成一片，⌃⌥C 紧挨 ⌃C。
    ///
    /// 先比个数会把所有「两个修饰键」的行排到所有「一个修饰键」的行之后，于是 ⌃⌥C 与 ⌃C
    /// 隔着几百行，而 ⌘C 反而在上面——这不是任何人会读的一种顺序。
    func testModifiersCompareBySignificance() {
        let items = [
            item([.command], "c", "Copy"),
            item([.control], "c", "Control C"),
            item([.option], "c", "Option C"),
            item([.control, .option], "c", "Control Option C"),
            item([.shift, .command], "z", "Redo")
        ]
        let labels = PanelOrdering.sorted(items).map { KeyFormatter.render($0.chord, style: .symbols) }
        XCTAssertEqual(labels, ["⌘C", "⇧⌘Z", "⌥C", "⌃⌥C", "⌃C"])

        // 单个修饰键之间的先后：⌘ → ⌥ → ⌃ → ⇧。
        let singles = [
            item([.shift], "x", "Shift"),
            item([.control], "x", "Control"),
            item([.option], "x", "Option"),
            item([.command], "x", "Command")
        ]
        XCTAssertEqual(
            PanelOrdering.sorted(singles).map(\.title),
            ["Command", "Option", "Control", "Shift"]
        )
    }

    /// 功能键按它写出来的那个词参与排序：f、f1、f2 … f12、g，而不是单独一块「功能键」。
    func testFunctionKeysSortBesideTheirLetter() {
        let items = [
            item([], "g", "G"),
            item([], "f2", "F2"),
            item([], "f1", "F1"),
            item([], "e", "E")
        ]
        XCTAssertEqual(PanelOrdering.sorted(items).map(\.title), ["E", "F1", "F2", "G"])
        XCTAssertTrue(KeyOrder.compare(KeyToken("f2"), KeyToken("f10")))
        XCTAssertTrue(KeyOrder.compare(KeyToken("f1"), KeyToken("3")))
        XCTAssertTrue(KeyOrder.compare(KeyToken("f1"), KeyToken("return")))
    }

    /// Holding a modifier reorders rather than narrowing: every row stays, the ones that use
    /// it move to the top.
    func testHeldModifierLiftsItsRowsWithoutDroppingTheRest() {
        let items = [
            item([.command], "c", "Copy"),
            item([.control], "a", "Beginning of Line"),
            item([.command], "v", "Paste")
        ]
        let labels = PanelOrdering.sorted(items, emphasizing: [.command])
            .map { KeyFormatter.render($0.chord, style: .symbols) }
        XCTAssertEqual(labels, ["⌘C", "⌘V", "⌃A"])
    }

    func testSingleStrokeChordsComeBeforeChords() {
        let single = item([.command], "k", "Link")
        let chord = BindingItem(
            chord: KeyChord([
                KeyStep.combo([.command], KeyToken("k")),
                KeyStep.combo([.command], KeyToken("c"))
            ]),
            title: "Copy Link",
            group: ["Edit"],
            source: .menu
        )
        let ordered = PanelOrdering.sorted([chord, single])
        XCTAssertEqual(ordered.first?.title, "Link")
    }

    /// The title-bar chips keep a shortcut when any stroke carries every ticked modifier,
    /// so ⌘K ⌘C counts as a ⌘ shortcut.
    func testFilterRequiresEveryTickedModifierOnOneStroke() {
        let plain = KeyChord.combo([.command], KeyToken("c"))
        let shifted = KeyChord.combo([.command, .shift], KeyToken("s"))
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command, .shift], KeyToken("c"))
        ])
        XCTAssertTrue(PanelOrdering.uses(plain, allOf: [.command]))
        XCTAssertTrue(PanelOrdering.uses(shifted, allOf: [.command, .shift]))
        XCTAssertFalse(PanelOrdering.uses(plain, allOf: [.command, .shift]))
        XCTAssertTrue(PanelOrdering.uses(chord, allOf: [.command, .shift]))
        // An empty filter is no filter at all.
        XCTAssertTrue(PanelOrdering.uses(plain, allOf: []))
    }
}
