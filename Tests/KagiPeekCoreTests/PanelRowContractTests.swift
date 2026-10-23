import XCTest
@testable import KagiPeekCore

// 本文件钉住 v2.2 的「行契约」：面板收窄到一行时，这一行既被选中、又是可执行的叶子行。
// 三块纯逻辑（选择解析 / 下钻判定 / 行键路由）在这里被分别钉住，最后用一组组合用例把
// 它们串起来 —— 单独看每一块都成立，拼起来却漏判一步，正是「Return 无反应」的成因。

// MARK: - 选择解析

/// 面板收窄到一行时 Return/点击必须能执行，收窄前又绝不能替用户选中某一行。
///
/// 这两条是同一个函数的两端：行数为 1 时落到 0（可立即执行），行数大于 1 且上一次选择
/// 已失效时落到 -1（宁可什么都不做，也不要误执行排序第一的那个快捷键）。判据放在纯
/// 逻辑里，是因为视图层拿到的是 Int 而不是 Binding，出问题时看不出错在哪一端。
final class PanelSelectionContractTests: XCTestCase {
    func testNoRowsMeansNoSelection() {
        XCTAssertEqual(PanelSelection.resolved(previous: -1, rowCount: 0), -1)
        XCTAssertEqual(PanelSelection.resolved(previous: 4, rowCount: 0), -1)
    }

    /// 收窄到唯一匹配时自动选中：这是「Return 无反应」修复的核心。
    func testSingleRowIsAlwaysSelected() {
        XCTAssertEqual(PanelSelection.resolved(previous: -1, rowCount: 1), 0)
        XCTAssertEqual(PanelSelection.resolved(previous: 0, rowCount: 1), 0)
    }

    /// 上一次的选择越界时也要回落到唯一的那一行（否则筛选之后 Return 依然无反应）。
    func testStaleSelectionFallsBackOnSingleRow() {
        XCTAssertEqual(PanelSelection.resolved(previous: 5, rowCount: 1), 0)
        XCTAssertEqual(PanelSelection.resolved(previous: 99, rowCount: 1), 0)
    }

    func testSelectionSurvivesWhenItIsStillInRange() {
        XCTAssertEqual(PanelSelection.resolved(previous: 0, rowCount: 3), 0)
        XCTAssertEqual(PanelSelection.resolved(previous: 2, rowCount: 3), 2)
    }

    /// 多行且没有有效选择时不自动选首行 —— 否则一次误触就执行了排序第一的快捷键。
    func testMultipleRowsDoNotAutoSelectTheFirst() {
        XCTAssertEqual(PanelSelection.resolved(previous: -1, rowCount: 3), -1)
        XCTAssertEqual(PanelSelection.resolved(previous: -1, rowCount: 24), -1)
    }

    /// 越界的上一次选择（列表变短）落到 -1，而不是夹到末行：夹到末行会执行一个用户
    /// 从没看过的快捷键。边界值 `previous == rowCount` 是这一类里最容易写错的。
    func testOutOfRangeSelectionIsDropped() {
        XCTAssertEqual(PanelSelection.resolved(previous: 3, rowCount: 3), -1)
        XCTAssertEqual(PanelSelection.resolved(previous: 10, rowCount: 3), -1)
        XCTAssertEqual(PanelSelection.resolved(previous: -2, rowCount: 3), -1)
    }
}

// MARK: - 行三列布局

/// 一行里的三列（标题 / 菜单路径 / 快捷键）按行宽分配，宽度是纯算术，所以放在 Core。
///
/// 钉住的不是某个具体像素，而是三条不变量：菜单路径列在窄面板上整列消失（否则标题会
/// 被挤没）、快捷键列有上下限（长快捷键不至于吃掉标题，短快捷键也不至于塌成一个点）、
/// 标题列永远不小于可读下限 —— 宁可让三列溢出，也不能让命令名读不出来。
final class RowLayoutContractTests: XCTestCase {
    private func assertClose(
        _ actual: Double,
        _ expected: Double,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, accuracy: 0.001, message, file: file, line: line)
    }

    func testColumnWidthSubtractsTheGapsBetweenColumns() {
        assertClose(RowLayout.rowWidth(contentWidth: 660, columns: 2, spacing: 18), 321)
        assertClose(RowLayout.rowWidth(contentWidth: 660, columns: 1, spacing: 18), 660)
        assertClose(RowLayout.rowWidth(contentWidth: 660, columns: 3, spacing: 18), 208)
        assertClose(RowLayout.rowWidth(contentWidth: 660, columns: 3, spacing: 0), 220)
    }

    /// 列数退化成 0 或负数时按一列算：不能除零，也不能给出负宽度去喂给 `metrics`。
    func testDegenerateGeometryStaysSane() {
        assertClose(RowLayout.rowWidth(contentWidth: 660, columns: 0, spacing: 18), 660)
        assertClose(RowLayout.rowWidth(contentWidth: 660, columns: -1, spacing: 18), 660)
        assertClose(RowLayout.rowWidth(contentWidth: 10, columns: 3, spacing: 18), 0)
    }

    /// gutter 是「冲突标记 + 收藏星」的固定槽位，没有冲突的那一行也必须留出来 ——
    /// 这正是以前 chord 会左右跳动的原因。
    func testGutterIsReservedOnEveryRow() {
        XCTAssertEqual(RowLayout.gutterWidth, 44)
        for width in [0.0, 200.0, 300.0, 380.0, 720.0] {
            for position in [KeyPosition.left, .right] {
                XCTAssertEqual(RowLayout.metrics(rowWidth: width, keyPosition: position).gutterWidth, 44)
            }
        }
    }

    /// 菜单路径列按行宽分档，380 与 379 是档位的两个边界。
    func testNoteWidthTiers() {
        // ≥ 380：0.34 × (rowWidth − 16)
        assertClose(RowLayout.metrics(rowWidth: 380, keyPosition: .right).noteWidth, 123.76)
        // 300…379：0.28 × (rowWidth − 16)
        assertClose(RowLayout.metrics(rowWidth: 379, keyPosition: .right).noteWidth, 101.64)
        assertClose(RowLayout.metrics(rowWidth: 300, keyPosition: .right).noteWidth, 79.52)
    }

    /// 菜单路径列有上限，行再宽也不会把标题挤掉。
    func testNoteWidthIsCapped() {
        assertClose(RowLayout.metrics(rowWidth: 520, keyPosition: .right).noteWidth, 168)
        assertClose(RowLayout.metrics(rowWidth: 1600, keyPosition: .right).noteWidth, 168)
    }

    /// 窄面板隐藏的是整列，不只是宽度算成 0：gutter 与 chord 照旧预留。
    func testNoteIsHiddenOnNarrowPanel() {
        for width in [0.0, 120.0, 299.0] {
            let narrow = RowLayout.metrics(rowWidth: width, keyPosition: .right)
            XCTAssertFalse(narrow.showsNote, "rowWidth \(width)")
            XCTAssertEqual(narrow.noteWidth, 0)
            XCTAssertEqual(narrow.gutterWidth, 44)
            XCTAssertGreaterThan(narrow.keyWidth, 0)
        }
    }

    func testKeyWidthIsClampedForBothPositions() {
        // 上限：右侧 120，左侧 96。
        assertClose(RowLayout.metrics(rowWidth: 500, keyPosition: .right).keyWidth, 120)
        assertClose(RowLayout.metrics(rowWidth: 500, keyPosition: .left).keyWidth, 96)
        assertClose(RowLayout.metrics(rowWidth: 1600, keyPosition: .right).keyWidth, 120)
        assertClose(RowLayout.metrics(rowWidth: 1600, keyPosition: .left).keyWidth, 96)
        // 下限：短快捷键不至于塌成一个点。
        assertClose(RowLayout.metrics(rowWidth: 180, keyPosition: .right).keyWidth, 52)
        assertClose(RowLayout.metrics(rowWidth: 200, keyPosition: .left).keyWidth, 48)
    }

    /// 快捷键列在左右两种布局下都要从标题里扣掉：长标题必须被截断，而不是把 chord
    /// 挤出这一行。左右之差正好是两种排布下 chord 列的宽度之差（120 − 96）。
    func testTitleWidthReservesTheChordInBothPositions() {
        let right = RowLayout.metrics(rowWidth: 720, keyPosition: .right)
        assertClose(right.rowContentWidth, 704)
        assertClose(right.titleWidth, 348) // 704 − 120 − 168 − 44 − 24
        let left = RowLayout.metrics(rowWidth: 720, keyPosition: .left)
        assertClose(left.titleWidth, 372) // 704 − 96 − 168 − 44 − 24
        assertClose(right.titleWidth + right.keyWidth, left.titleWidth + left.keyWidth)
    }

    /// 标题是「所有预留槽位之外剩下的」：gap 的数量等于列边界的数量 —— 菜单路径列
    /// 显示时是四列三个缝，隐藏时是三列两个缝。钉住这条组合规则，比钉住某个常数更
    /// 能拦住「又挪了 8pt」这类改动。
    func testTitleIsWhatIsLeftAfterEveryReservedSlot() {
        for width in [0.0, 120.0, 200.0, 299.0, 300.0, 379.0, 380.0, 500.0, 720.0, 1000.0] {
            for position in [KeyPosition.left, .right] {
                let metrics = RowLayout.metrics(rowWidth: width, keyPosition: position)
                let gaps = RowLayout.columnGap * Double(metrics.showsNote ? 3 : 2)
                let reserved = metrics.keyWidth + metrics.noteWidth + metrics.gutterWidth + gaps
                assertClose(metrics.titleWidth, max(60, metrics.rowContentWidth - reserved), "rowWidth \(width)")
                assertClose(metrics.rowContentWidth, max(0, width - RowLayout.horizontalPadding * 2))
            }
        }
    }

    /// 行再窄标题也不塌到 0：宁可让三列溢出，也不能让命令名读不出来。
    func testTitleWidthKeepsAReadableFloor() {
        XCTAssertEqual(RowLayout.metrics(rowWidth: 120, keyPosition: .right).titleWidth, 60)
        XCTAssertEqual(RowLayout.metrics(rowWidth: 120, keyPosition: .left).titleWidth, 60)
        XCTAssertEqual(RowLayout.metrics(rowWidth: 0, keyPosition: .right).titleWidth, 60)
    }

    /// 记录 `max(60, …)` 这个下限**在哪一档真的生效**，以及生效时行会溢出多少。
    ///
    /// 下限不是理论问题：单列 300pt（面板的最小宽度）+ 右侧快捷键列时，预留之和已经
    /// 比行宽多出约 3pt，行内容会溢出并被裁掉；两列布局下窗口宽到 ~626pt 也会踩到
    /// （rowWidth = (626 − 18) / 2 ≈ 304）。钉在这里是为了让这个口子保持"显式决策"：
    /// 若改成降级式（放不下就把菜单路径列让掉重算），本用例要跟着翻。
    func testTitleFloorEngagesAtTheNarrowestSupportedRow() {
        let tightest = RowLayout.metrics(rowWidth: 300, keyPosition: .right)
        XCTAssertEqual(tightest.titleWidth, 60)
        let gaps = RowLayout.columnGap * Double(tightest.showsNote ? 3 : 2)
        let reserved = tightest.keyWidth + tightest.noteWidth + tightest.gutterWidth + gaps
        assertClose(tightest.titleWidth + reserved - tightest.rowContentWidth, 3.04)

        // 左侧快捷键列更窄，同一宽度下不触发。
        let left = RowLayout.metrics(rowWidth: 300, keyPosition: .left)
        assertClose(left.titleWidth, 74)
        assertClose(left.titleWidth + left.keyWidth + left.noteWidth + left.gutterWidth + gaps, left.rowContentWidth)

        // 宽到 308 就脱离下限了（304 仍触发，308 起不再）。
        XCTAssertGreaterThan(RowLayout.metrics(rowWidth: 308, keyPosition: .right).titleWidth, 60)
        XCTAssertEqual(RowLayout.metrics(rowWidth: 304, keyPosition: .right).titleWidth, 60)
    }
}

// MARK: - 下钻判定

/// 「这一步是最后一步吗」决定叶子行是被执行还是被当成前缀继续压栈。
///
/// 曾经用 `remainingSteps > 0` 判定下钻，于是点击 ⌘C 只把 ⌘C 压成了前缀 —— 面板明明
/// 只剩一行，Return 和点击却什么都不做。判定必须是「还剩一步以上才下钻」。
///
/// 引擎画 chevron（`PanelRow.isGroup`）和处理点击（`ShortcutEngine.activate`）用的是同一
/// 个入口 `KeyChord.isFinalStroke`，所以回归网钉在它上面：chevron 与点击给出不同答案，
/// 正是这个 bug 的形状。
final class ChordDescentContractTests: XCTestCase {
    private let leaf = KeyChord.combo([.command], KeyToken("c"))
    private let twoStep = KeyChord([
        .combo([.command], KeyToken("k")),
        .combo([.command], KeyToken("c"))
    ])
    private var firstStep: KeyChord { KeyChord.combo([.command], KeyToken("k")) }

    /// 是最后一击 → 点击即执行整条 chord，不画 chevron。
    private func assertRunnable(_ chord: KeyChord, prefix: KeyChord, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(chord.isFinalStroke(after: prefix), file: file, line: line)
    }

    /// 还有下一层 → 点击是下钻，要画 chevron。
    private func assertDescendable(_ chord: KeyChord, prefix: KeyChord, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(chord.isFinalStroke(after: prefix), file: file, line: line)
    }

    /// 空前缀下还没有输入任何一步，剩余步数就是全部步数。
    func testRemainingStepsFromAnEmptyPrefixIsTheWholeChord() {
        XCTAssertEqual(leaf.remainingSteps(after: .empty), 1)
        XCTAssertEqual(twoStep.remainingSteps(after: .empty), 2)
    }

    /// 单步快捷键在空前缀下只剩一步 —— 它就是最后一步，按下即执行。
    func testLeafChordDoesNotDescend() {
        XCTAssertEqual(leaf.remainingSteps(after: .empty), 1)
        assertRunnable(leaf, prefix: .empty)
    }

    func testTwoStepChordDescendsFromTheRoot() {
        assertDescendable(twoStep, prefix: .empty)
    }

    /// 已经输入了第一击时，最后一击是「执行」而不是「再下钻一层」。
    func testLastStepOfAChordDoesNotDescend() {
        XCTAssertEqual(twoStep.remainingSteps(after: firstStep), 1)
        assertRunnable(twoStep, prefix: firstStep)
    }

    /// 只按住 ⌘ 时 ⌘K ⌘C 还剩一步（⌘K 那一击），同样不该下钻。
    func testModifierOnlyPrefixCountsAsOneStep() {
        XCTAssertEqual(twoStep.remainingSteps(after: .modifiers([.command])), 1)
        assertRunnable(twoStep, prefix: .modifiers([.command]))
    }

    /// 三步 chord 在第一击后仍要下钻，免得回归网只钉住了两步的情形。
    func testThreeStepChordDescendsAfterItsFirstStep() {
        let three = KeyChord([
            .combo([.command], KeyToken("k")),
            .combo([.command], KeyToken("e")),
            .combo([.command], KeyToken("s"))
        ])
        let second = KeyChord([
            .combo([.command], KeyToken("k")),
            .combo([.command], KeyToken("e"))
        ])
        XCTAssertEqual(three.remainingSteps(after: firstStep), 2)
        assertDescendable(three, prefix: firstStep)
        assertRunnable(three, prefix: second)
    }
}

// MARK: - 行键路由（按住的修饰键）

/// 用户按住 ⌘ 收窄列表时，系统报上来的事件自带 ⌘。若不把按住的修饰键剥掉，⌘↩ 会被
/// 判成「复制」，收窄态下 Return 就变成了复制而不是执行 —— 正是本轮的诉求。
final class RowKeyHeldModifierContractTests: XCTestCase {
    private let run = HotkeySpec.runRowDefault // ↩
    private let copy = HotkeySpec.copyRowDefault // ⌘↩

    private func action(_ modifiers: ModifierSet, _ held: ModifierSet) -> RowAction? {
        RowKeyRouter.action(for: KeyCode.returnKey, modifiers: modifiers, held: held, run: run, copy: copy)
    }

    func testBareReturnExecutes() {
        XCTAssertEqual(action([], []), .execute)
    }

    func testCommandReturnCopiesWhenCommandIsNotHeld() {
        XCTAssertEqual(action([.command], []), .copy)
    }

    /// 核心诉求：⌘ 按住时 ⌘↩ 必须等价于 ↩ —— 执行，而不是复制。
    func testHeldCommandTurnsCommandReturnIntoExecute() {
        XCTAssertEqual(action([.command], [.command]), .execute)
    }

    /// 按住的修饰键与复制键的修饰键无关时，复制键照旧是复制。
    func testUnrelatedHeldModifierDoesNotBlockCopy() {
        XCTAssertEqual(action([.command, .option], [.option]), .copy)
    }

    /// 按住 ⌃ / ⇧ 时按下 ↩ 依然是执行：剥掉按住的键后它就是裸 ↩。
    func testHeldModifierIsStrippedBeforeMatching() {
        XCTAssertEqual(action([.control], [.control]), .execute)
        XCTAssertEqual(action([.shift], [.shift]), .execute)
    }

    /// 按住 ⌘ 而复制键被改绑成 ⇧↩ 时，⇧↩ 仍是复制。
    func testReboundCopyKeyStillCopiesWhileCommandIsHeld() {
        let shifted = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.shift])
        XCTAssertEqual(
            RowKeyRouter.action(for: KeyCode.returnKey, modifiers: [.shift], held: [.command], run: run, copy: shifted),
            .copy
        )
    }

    /// 复制键改绑成 ⇧↩、且 ⇧ 正是按住的那个键时，剥掉之后等价于裸 ↩ —— run 优先，
    /// 结果是执行而不是复制。run 与 copy 的优先级不随按住的键改变。
    func testRunStillWinsAfterStrippingTheHeldModifier() {
        let shifted = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.shift])
        XCTAssertEqual(
            RowKeyRouter.action(for: KeyCode.returnKey, modifiers: [.shift], held: [.shift], run: run, copy: shifted),
            .execute
        )
    }

    /// 按住的修饰键剥掉之后仍没有任何绑定匹配时，按键必须放行（交给输入框）。
    func testHeldModifierDoesNotInventARowKey() {
        XCTAssertNil(action([.control, .option], [.control]))
        XCTAssertNil(RowKeyRouter.action(for: 0, modifiers: [.command], held: [.command], run: run, copy: copy))
    }

    /// 小键盘 Enter 与主键 Return 是同一个键：按住 ⌘ 时在小键盘上按 Enter 也要执行。
    func testHeldModifierWorksWithTheKeypadEnterAlias() {
        XCTAssertEqual(
            RowKeyRouter.action(for: KeyCode.keypadEnter, modifiers: [.command], held: [.command], run: run, copy: copy),
            .execute
        )
    }
}

// MARK: - 修饰键集合

final class ModifierSetSubtractionTests: XCTestCase {
    private func mods(_ members: ModifierSet...) -> ModifierSet {
        members.reduce(ModifierSet(rawValue: 0)) { $0.union($1) }
    }

    func testSubtractingOneModifier() {
        XCTAssertEqual(mods(.command, .shift).subtracting(mods(.command)), mods(.shift))
    }

    func testSubtractingASet() {
        XCTAssertEqual(mods(.command, .shift, .option).subtracting([.command, .shift]), mods(.option))
    }

    func testSubtractingAnAbsentModifierChangesNothing() {
        XCTAssertEqual(mods(.command).subtracting(mods(.option)), mods(.command))
        XCTAssertEqual(mods(.command).subtracting([]), mods(.command))
    }

    func testSubtractingEverythingIsEmpty() {
        XCTAssertTrue(mods(.command, .shift).subtracting([.command, .shift]).isEmpty)
        XCTAssertTrue(ModifierSet.all.subtracting(.all).isEmpty)
    }

    /// 剥掉之后剩下的修饰键仍然是 ⌃⌥⇧⌘ 的规范顺序，因为结果会直接渲染给用户。
    func testSubtractionKeepsCanonicalOrder() {
        XCTAssertEqual(ModifierSet.all.subtracting([.option, .command]).ordered, [.control, .shift])
    }

    /// `subtracting` 是值语义：返回新集合，不动接收者。行键路由要拿剥掉之后的结果和
    /// 原始 modifiers 各匹配一次，如果这一步把原值改没了，第二次匹配就永远失败。
    func testSubtractionDoesNotMutateTheReceiver() {
        var held: ModifierSet = [.command, .option]
        let stripped = held.subtracting([.command])
        XCTAssertEqual(stripped, mods(.option))
        XCTAssertEqual(held, mods(.command, .option))
        XCTAssertTrue(held.contains(.command))
    }
}

// MARK: - 收窄到最后一行

/// 把上面三块拼起来：面板收窄到唯一一行时，这一行既被选中、又是叶子行，所以 Return
/// 和点击都会执行，而不是「再压一层前缀」或「什么都没选中」。
final class NarrowedPanelContractTests: XCTestCase {
    /// 按住 ⌘ 之后只剩 ⌘C 一行：自动选中它，且它不再下钻。
    func testSingleRemainingLeafRowIsSelectedAndRunnable() {
        let items = [
            BindingItem(chord: .combo([.command], KeyToken("c")), title: "Copy", group: ["Edit"], source: .menu)
        ]
        let hits = PrefixResolver.hits(for: .modifiers([.command]), in: items)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(PanelSelection.resolved(previous: -1, rowCount: hits.count), 0)
        // 引擎画 chevron 与处理点击用的都是这个入口。
        XCTAssertTrue(items[0].chord.isFinalStroke(after: .modifiers([.command])))
    }

    /// 收窄到 chord 的最后一击时同样：面板只剩一行、该行被选中、按下即执行整条 chord。
    func testLastStrokeOfAChordIsSelectedAndRunnable() {
        let chord = KeyChord([
            .combo([.command], KeyToken("k")),
            .combo([.command], KeyToken("c"))
        ])
        let items = [BindingItem(chord: chord, title: "Chord", group: ["Edit"], source: .menu)]
        let prefix = KeyChord.combo([.command], KeyToken("k"))
        let hits = PrefixResolver.hits(for: prefix, in: items)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(PanelSelection.resolved(previous: -1, rowCount: hits.count), 0)
        XCTAssertTrue(chord.isFinalStroke(after: prefix))
    }

    /// 还有下一层时（⌘K 之后既有 ⌘C 也有 ⌘S），面板有两行，此时不替用户选中任何一行。
    func testTwoRemainingStrokesLeaveTheSelectionEmpty() {
        let items = [
            BindingItem(chord: KeyChord([
                .combo([.command], KeyToken("k")),
                .combo([.command], KeyToken("c"))
            ]), title: "C", group: ["Edit"], source: .menu),
            BindingItem(chord: KeyChord([
                .combo([.command], KeyToken("k")),
                .combo([.command], KeyToken("s"))
            ]), title: "S", group: ["Edit"], source: .menu)
        ]
        let prefix = KeyChord.combo([.command], KeyToken("k"))
        let hits = PrefixResolver.hits(for: prefix, in: items)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(PanelSelection.resolved(previous: -1, rowCount: hits.count), -1)
    }
}
