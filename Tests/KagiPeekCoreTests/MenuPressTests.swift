import XCTest
@testable import KagiPeekCore

// 本文件钉住「没有快捷键也能触发」这一轮改动：菜单里没有快捷键的命令必须能进列表、
// 能被点击触发（按 AX 元素，由引擎接线，此处钉纯逻辑契约）、并且不污染任何以快捷键
// 为键的机制（排序、冲突、收藏、命中）。

// MARK: - 空和弦本身的行为

/// 空和弦不是「坏数据」，是一种合法形态：这个命令存在，只是没有键可按。
///
/// 所有匹配函数都必须对它给出确定答案，否则它会在某一层被悄悄过滤掉 —— 这正是它
/// 一开始进不了面板的原因（`hits` 曾经要求 nextKey 非空）。
final class ShortcutlessChordTests: XCTestCase {
    func testEmptyChordIsACandidateAtTheRoot() {
        XCTAssertEqual(KeyChord.empty.relation(to: .empty), .candidate)
    }

    /// 修饰键前缀下不该出现：它不携带任何修饰键，没有可收窄的方向。
    func testEmptyChordIsUnrelatedUnderAModifierPrefix() {
        XCTAssertEqual(KeyChord.empty.relation(to: .modifiers([.command])), .unrelated)
        XCTAssertEqual(KeyChord.empty.relation(to: .modifiers([.command, .shift])), .unrelated)
    }

    /// 一步都不剩 ⇒ 是最后一击 ⇒ 永不向下钻取（chevron 与点击共用这个判据）。
    func testEmptyChordIsAlwaysAFinalStroke() {
        XCTAssertTrue(KeyChord.empty.isFinalStroke(after: .empty))
        XCTAssertEqual(KeyChord.empty.remainingSteps(after: .empty), 0)
    }

    func testEmptyChordHasNoKeyToPress() {
        XCTAssertNil(KeyChord.empty.nextKey(after: .empty))
        XCTAssertNil(KeyChord.empty.step(after: .empty))
    }

    func testEmptyChordRendersAsNothing() {
        XCTAssertTrue(KeyFormatter.segments(for: .empty, style: .symbols).isEmpty)
        XCTAssertEqual(KeyFormatter.render(.empty, style: .symbols), "")
        // 占位符非空：快捷键列空白会被当成渲染故障。
        XCTAssertFalse(KeyFormatter.noShortcutPlaceholder.isEmpty)
    }
}

// MARK: - 面板命中

/// 无快捷键的行必须能进面板（根层级），且必须能被 ⌘ 等修饰键收窄排除。
final class ShortcutlessHitsTests: XCTestCase {
    private func item(_ chord: KeyChord, title: String, axPath: String? = nil) -> BindingItem {
        BindingItem(
            chord: chord,
            title: title,
            group: ["Edit"],
            source: .menu,
            appBundleID: "com.apple.TextEdit",
            axPath: axPath
        )
    }

    private var items: [BindingItem] {
        [
            item(.combo([.command], KeyToken("c")), title: "Copy", axPath: "1,0,2"),
            item(.combo([.command, .shift], KeyToken("a")), title: "Align", axPath: "3,0,1"),
            item(.empty, title: "Zoom", axPath: "4,0,7")
        ]
    }

    func testShortcutlessRowIsAHitAtTheRoot() {
        let hits = PrefixResolver.hits(for: .empty, in: items)
        XCTAssertEqual(hits.count, 3)
        let zoom = hits.first { $0.item.title == "Zoom" }
        XCTAssertNotNil(zoom)
        // 这一行没有键可按 —— 它是可点的，不是可打的。
        XCTAssertNil(zoom?.nextKey)
        XCTAssertEqual(zoom?.relation, .candidate)
    }

    /// 收窄是核心行为：按住 ⌘ 之后，没有快捷键的行必须消失，而不是留下来充数。
    func testShortcutlessRowDisappearsWhenNarrowed() {
        let hits = PrefixResolver.hits(for: .modifiers([.command]), in: items)
        XCTAssertEqual(hits.count, 2)
        XCTAssertFalse(hits.contains { $0.item.chord.isEmpty })
    }

    /// 「显示禁用项」关闭时，两类行一起被过滤 —— 不存在只过滤一半的捷径。
    func testDisabledFilterCoversBothKinds() {
        let disabled = BindingItem(
            chord: .empty,
            title: "Locked",
            group: ["Edit"],
            isEnabled: false,
            source: .menu,
            appBundleID: "com.apple.TextEdit",
            axPath: "9,0,9"
        )
        XCTAssertTrue(PrefixResolver.hits(for: .empty, in: [disabled], includeDisabled: false).isEmpty)
        XCTAssertEqual(PrefixResolver.hits(for: .empty, in: [disabled], includeDisabled: true).count, 1)
    }
}

// MARK: - 排序

/// 无快捷键的行排在所有快捷键之后：面板首先是一张快捷键参考卡。
final class ShortcutlessOrderingTests: XCTestCase {
    private func item(_ chord: KeyChord, title: String) -> BindingItem {
        BindingItem(chord: chord, title: title, group: ["Edit"], source: .menu)
    }

    private var items: [BindingItem] {
        [
            item(.empty, title: "Zoom"),
            item(.combo([.command], KeyToken("c")), title: "Copy"),
            item(.combo([], KeyToken("a")), title: "Select All")
        ]
    }

    func testShortcutlessRowsSortLast() {
        let sorted = PanelOrdering.sorted(items)
        XCTAssertEqual(sorted.map(\.title), ["Select All", "Copy", "Zoom"])
    }

    /// 高亮 ⌘ 时 ⌘ 块仍然领先，空和弦仍然垫底 —— 两个规则互不干扰。
    func testEmphasizingDoesNotDisturbTheOrder() {
        let sorted = PanelOrdering.sorted(items, emphasizing: [.command])
        XCTAssertEqual(sorted.map(\.title), ["Copy", "Select All", "Zoom"])
    }

    /// compare 对空值是单向前押的：空在后，且不因交换参数而翻转（排序稳定性前提）。
    func testCompareIsOneDirectionalAboutEmpty() {
        let empty = KeyChord.empty
        let chord = KeyChord.combo([.command], KeyToken("c"))
        XCTAssertFalse(PanelOrdering.compare(empty, chord))
        XCTAssertTrue(PanelOrdering.compare(chord, empty))
        XCTAssertFalse(PanelOrdering.compare(empty, empty))
    }

    /// 两个空和弦之间按标题断平，保持全序（`sorted(by:)` 要求）。
    func testTwoShortcutlessRowsBreakTheTieByTitle() {
        let a = item(.empty, title: "Alpha")
        let b = item(.empty, title: "Beta")
        let sorted = PanelOrdering.sorted([b, a])
        XCTAssertEqual(sorted.map(\.title), ["Alpha", "Beta"])
    }
}

// MARK: - 身份与统计

/// 没有和弦可作键，id 与 usageKey 必须另有依托，否则行会被合并、收藏会串味。
final class ShortcutlessIdentityTests: XCTestCase {
    private func item(_ title: String, axPath: String?) -> BindingItem {
        BindingItem(
            chord: .empty,
            title: title,
            group: ["View"],
            source: .menu,
            appBundleID: "com.apple.Safari",
            axPath: axPath
        )
    }

    /// 同名同路径的两个动态菜单项，靠 AX 索引路径区分 —— 合并会让点击打到另一个命令上。
    func testSameTitleDifferentPathMeansDifferentRow() {
        let first = item("Recent", axPath: "2,0,3")
        let second = item("Recent", axPath: "2,0,9")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.usageKey, second.usageKey)
    }

    /// 同一位置重新扫描必须得到同一个 id，否则每次扫描都像换了一批行。
    func testSamePathMeansSameIDAcrossScans() {
        XCTAssertEqual(item("Recent", axPath: "2,0,3").id, item("Recent", axPath: "2,0,3").id)
    }

    /// 没有 AX 路径时（内置目录等）退回到路径+标题，仍然唯一于标题。
    func testFallbackIdentityUsesPathAndTitle() {
        let first = item("Zoom", axPath: nil)
        let second = BindingItem(
            chord: .empty, title: "Zoom", group: ["Window"], source: .menu,
            appBundleID: "com.apple.Safari", axPath: nil
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.usageKey, second.usageKey)
    }

    /// 有快捷键的行，usageKey 格式必须原样保持 —— 使用统计是跨会话持久化的。
    func testChordedUsageKeyFormatIsUnchanged() {
        let item = BindingItem(
            chord: .combo([.command], KeyToken("c")),
            title: "Copy",
            group: ["Edit"],
            source: .menu,
            appBundleID: "com.apple.Safari"
        )
        XCTAssertEqual(item.usageKey, "com.apple.Safari|8:c")
    }
}

// MARK: - 不污染既有机制

/// 空和弦不得渗进任何以「快捷键」为键的机制。
final class ShortcutlessIsolationTests: XCTestCase {
    private func item(_ chord: KeyChord, title: String) -> BindingItem {
        BindingItem(chord: chord, title: title, group: ["Edit"], source: .menu, appBundleID: "com.apple.Safari")
    }

    /// 两个都没有快捷键，不是「冲突」——冲突徽标只能表示快捷键被重复绑定。
    func testShortcutlessRowsNeverConflict() {
        let items = [item(.empty, title: "Zoom"), item(.empty, title: "Zoom")]
        XCTAssertTrue(ConflictDetector.conflicts(in: items).isEmpty)
    }

    /// 修饰键 chips 的筛选规则同样不误伤：空和弦不「使用」任何修饰键。
    func testModifierFilterExcludesShortcutlessRows() {
        XCTAssertFalse(PanelOrdering.uses(.empty, allOf: [.command]))
        XCTAssertFalse(PanelOrdering.uses(.empty, allOf: [.shift]))
    }

    /// 搜索语料对空和弦仍然可按标题命中 —— 触发是首要目的，搜索是到达它的路。
    func testSearchFindsShortcutlessRowsByTitle() {
        let corpus = SearchCorpus(items: [item(.empty, title: "Zoom")], style: .symbols)
        XCTAssertEqual(corpus.search("zoom", limit: 10).map(\.title), ["Zoom"])
        XCTAssertEqual(corpus.search("zm", limit: 10).map(\.title), ["Zoom"])
    }
}
