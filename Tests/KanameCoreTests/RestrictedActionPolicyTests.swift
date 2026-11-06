import XCTest
@testable import KanameCore

final class RestrictedActionPolicyTests: XCTestCase {
    private let power = KeyToken("power")

    private func chord(
        _ modifiers: ModifierSet,
        _ key: KeyToken,
        alternates: [KeyToken] = []
    ) -> KeyChord {
        KeyChord.combo(modifiers, key, alternates: alternates)
    }

    private func item(
        _ chord: KeyChord,
        source: BindingSource,
        title: String = "Action",
        configTool: ConfigTool? = nil
    ) -> BindingItem {
        BindingItem(
            chord: chord,
            title: title,
            group: source == .configFile ? [configTool?.displayName ?? "Tool"] : ["Apple"],
            source: source,
            configTool: configTool
        )
    }

    // MARK: - The six actions

    func testAllRestrictedActionsMatchTheirChords() {
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: chord([.option, .command], power)),
            .restricted(.sleep)
        )
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: chord([.control, .command], power)),
            .restricted(.restart)
        )
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: chord([.control, .option, .command], power)),
            .restricted(.shutdown)
        )
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: chord([.control, .command], "q")),
            .restricted(.lockScreen)
        )
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: chord([.shift, .command], "q")),
            .restricted(.logOut)
        )
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: chord([.option, .shift, .command], "q")),
            .restricted(.forceLogOut)
        )
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: chord([.option, .command], "esc")),
            .restricted(.forceQuit)
        )
    }

    /// 同一个 chord 在两个来源里都是同一条数据；判定不能依赖本地化标题。
    func testSameChordIsRestrictedInMenuAndSystemSections() {
        let sleep = chord([.option, .command], power)
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: item(sleep, source: .menu, title: "Sleep")),
            .restricted(.sleep)
        )
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: item(sleep, source: .system, title: "睡眠")),
            .restricted(.sleep)
        )
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: item(sleep, source: .builtIn, title: "Sleep")),
            .restricted(.sleep)
        )
    }

    /// ⌘Q 退出的是当前 App，不是整台 Mac —— 它必须保持可执行。
    func testCommandQIsNotRestricted() {
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(for: chord([.command], "q")),
            .allowed
        )
    }

    func testModifiersMustMatchExactly() {
        // 多一个 Shift 就是另一个快捷键，不能因为前缀相同就命中。
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(
                for: chord([.option, .shift, .command], power)
            ),
            .allowed
        )
    }

    func testMultiStepChordStartingWithRestrictedPrefixIsAllowed() {
        let multiStep = KeyChord([
            .combo([.option, .command], power),
            .combo([], "a")
        ])
        XCTAssertEqual(RestrictedActionPolicy.restriction(for: multiStep), .allowed)
    }

    /// Token 的 alternate 拼写也是同一个物理键。
    func testAlternateTokenSpellingMatchesTheSameAction() {
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(
                for: chord([.option, .command], KeyToken("power-alt"), alternates: [power])
            ),
            .restricted(.sleep)
        )
    }

    /// 配置行另有「只展示不执行」的来源规则，不再叠加系统动作分类。
    func testConfigFileRowIsNotClassifiedAsRestricted() {
        XCTAssertEqual(
            RestrictedActionPolicy.restriction(
                for: item(
                    chord([.option, .command], power),
                    source: .configFile,
                    title: "Karabiner sleep",
                    configTool: .karabiner
                )
            ),
            .allowed
        )
    }

    // MARK: - Power key token

    func testPowerVirtualKeyMapsToPowerToken() {
        XCTAssertEqual(KeyMapper.token(forKeyCode: UInt16(0x7F)), power)
        XCTAssertEqual(KeyMapper.keyCode(for: power), UInt16(0x7F))
    }

    // MARK: - Row action plan

    // 点击与执行走同一条拒绝路径：复制由 RowRunner 统一做，提示也统一。
    func testRestrictedClickIsRefusedNotCopiedSilently() {
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .click,
                restriction: .restricted(.sleep),
                source: .menu,
                hasChord: true
            ),
            .noticeRestricted
        )
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .click,
                restriction: .restricted(.sleep),
                source: .menu,
                hasChord: false
            ),
            .noticeRestricted
        )
    }

    /// 但显式复制动作不受影响：Cmd+C 与右键「复制快捷键」仍然只是复制。
    func testExplicitCopyOfRestrictedRowStaysACopy() {
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .copyShortcut,
                restriction: .restricted(.sleep),
                source: .menu,
                hasChord: true
            ),
            .copyShortcut
        )
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .copyMenuItem,
                restriction: .restricted(.sleep),
                source: .menu,
                hasChord: true
            ),
            .copyMenuItem
        )
    }

    func testRestrictedExecuteIsRefused() {
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .execute,
                restriction: .restricted(.shutdown),
                source: .system,
                hasChord: true
            ),
            .noticeRestricted
        )
    }

    func testRestrictedCopyShortcutWithoutChordHasNothingToCopy() {
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .copyShortcut,
                restriction: .restricted(.forceQuit),
                source: .menu,
                hasChord: false
            ),
            .noticeNothingToCopy
        )
    }

    /// 用户对配置行的口径：「点击 = 复制快捷键（无 chord 提示无法复制）」。
    func testConfigClickCopiesShortcutOrSaysNothingToCopy() {
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .click,
                restriction: .allowed,
                source: .configFile,
                hasChord: true
            ),
            .copyShortcut
        )
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .click,
                restriction: .allowed,
                source: .configFile,
                hasChord: false
            ),
            .noticeNothingToCopy
        )
    }

    func testConfigExecuteIsRefusedAsUnsupportedSource() {
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .execute,
                restriction: .allowed,
                source: .configFile,
                hasChord: true
            ),
            .noticeUnsupportedSource
        )
    }

    func testConfigCopyStillWorks() {
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .copyShortcut,
                restriction: .allowed,
                source: .configFile,
                hasChord: true
            ),
            .copyShortcut
        )
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .copyMenuItem,
                restriction: .allowed,
                source: .configFile,
                hasChord: false
            ),
            .copyMenuItem
        )
    }

    func testOrdinaryRowsRunAndCopyNormally() {
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .execute,
                restriction: .allowed,
                source: .menu,
                hasChord: true
            ),
            .run
        )
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .click,
                restriction: .allowed,
                source: .menu,
                hasChord: true
            ),
            .run
        )
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .copyShortcut,
                restriction: .allowed,
                source: .menu,
                hasChord: true
            ),
            .copyShortcut
        )
        // 无快捷键的普通行复制菜单路径，和旧版 copyRow 的行为一致。
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .copyShortcut,
                restriction: .allowed,
                source: .menu,
                hasChord: false
            ),
            .copyMenuItem
        )
        XCTAssertEqual(
            PanelRowActionPlan.outcome(
                request: .copyMenuItem,
                restriction: .allowed,
                source: .menu,
                hasChord: true
            ),
            .copyMenuItem
        )
    }

    // MARK: - Row data and favourites

    func testPanelRowCarriesRestriction() {
        let built = PanelRowBuilder.build([
            PanelRowBuilder.Spec(
                id: "system|sleep",
                keySegments: [],
                title: "Sleep",
                groupTitle: "System",
                source: .system,
                restriction: .sleep,
                hasChord: true
            )
        ])
        XCTAssertEqual(built.groups.count, 1)
        XCTAssertTrue(built.groups[0].rows[0].isRestricted)
        XCTAssertEqual(built.groups[0].rows[0].restriction, .sleep)
        XCTAssertEqual(built.groups[0].rows[0].source, .system)
    }

    /// 同一个 chord 的 system 行和 config 行必须有两个收藏 key，否则收藏一条会连带另一条。
    func testSystemAndConfigFavoritesWithSameChordDoNotCollide() {
        let chord = self.chord([.option, .command], "k")
        let system = item(chord, source: .system, title: "Same chord")
        let config = item(
            chord,
            source: .configFile,
            title: "Same chord",
            configTool: .karabiner
        )
        XCTAssertNotEqual(system.usageKey, config.usageKey)
        XCTAssertTrue(system.usageKey.hasPrefix("system|"))
        XCTAssertTrue(config.usageKey.hasPrefix("karabiner|"))
    }
}
