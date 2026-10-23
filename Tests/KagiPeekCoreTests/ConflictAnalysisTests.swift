import XCTest
@testable import KagiPeekCore

/// The part of conflict detection that says something the old flat list could not: how much
/// a clash bites, and who the keyboard stack says wins.
final class ConflictAnalysisTests: XCTestCase {

    // MARK: - Helpers

    private func menu(_ title: String, chord: KeyChord, bundleID: String = "com.example.app") -> BindingItem {
        BindingItem(chord: chord, title: title, group: ["File"], source: .menu, appBundleID: bundleID)
    }

    private func system(_ title: String, chord: KeyChord) -> BindingItem {
        BindingItem(chord: chord, title: title, group: ["System"], source: .system)
    }

    private func karabiner(_ title: String, chord: KeyChord) -> BindingItem {
        BindingItem(
            chord: chord,
            title: title,
            group: [ConfigTool.karabiner.displayName],
            source: .configFile,
            configTool: .karabiner
        )
    }

    private var cmdShift3: KeyChord { .combo([.command, .shift], KeyToken("3")) }

    // MARK: - Layers

    func testLayerOrderPutsTheDriverBelowEverything() {
        XCTAssertLessThan(ShortcutLayer.driver, ShortcutLayer.eventTap)
        XCTAssertLessThan(ShortcutLayer.eventTap, ShortcutLayer.system)
        XCTAssertLessThan(ShortcutLayer.system, ShortcutLayer.globalHotKey)
        XCTAssertLessThan(ShortcutLayer.globalHotKey, ShortcutLayer.menuItem)
    }

    func testClassifyReadsTheToolNotJustTheSource() {
        // All six tools share the `.configFile` source; the layer has to come from which
        // tool it is, or a Karabiner rule would be ranked alongside a menu item.
        XCTAssertEqual(ShortcutLayer.classify(karabiner("rule", chord: cmdShift3)), .driver)
        XCTAssertEqual(
            ShortcutLayer.classify(BindingItem(
                chord: cmdShift3, title: "hs", group: ["Hammerspoon"], source: .configFile, configTool: .hammerspoon
            )),
            .globalHotKey
        )
        XCTAssertEqual(ShortcutLayer.classify(system("Screenshot", chord: cmdShift3)), .system)
        XCTAssertEqual(ShortcutLayer.classify(menu("Save", chord: cmdShift3)), .menuItem)
    }

    func testOnlyMenuItemsAreNotAlwaysOn() {
        XCTAssertFalse(ShortcutLayer.menuItem.isAlwaysOn)
        XCTAssertTrue(ShortcutLayer.system.isAlwaysOn)
        XCTAssertTrue(ShortcutLayer.driver.isAlwaysOn)
    }

    // MARK: - Categories

    func testTwoMenuItemsAreAnOverlapNotAClash() {
        let conflicts = ConflictDetector.conflicts(in: [
            menu("New", chord: cmdShift3),
            menu("New Window", chord: cmdShift3)
        ])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].category, .menuOrder)
        XCTAssertFalse(conflicts[0].category.isRealConflict)
    }

    func testASystemHotkeyCoveringAMenuItemIsShadowed() {
        let conflicts = ConflictDetector.conflicts(in: [
            menu("Screenshot", chord: cmdShift3),
            system("Save picture of screen as file", chord: cmdShift3)
        ])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].category, .systemShadow)
        XCTAssertTrue(conflicts[0].category.isRealConflict)
    }

    func testTwoAlwaysOnSourcesAreASystemVersusTool() {
        let conflicts = ConflictDetector.conflicts(in: [
            karabiner("Remap", chord: cmdShift3),
            system("Screenshot", chord: cmdShift3)
        ])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].category, .systemVsTool)
    }

    func testAlwaysOnPairsSortAheadOfMenuOverlaps() {
        let overlap = ConflictDetector.conflicts(in: [
            menu("New", chord: .combo([.command], KeyToken("n"))),
            menu("New Window", chord: .combo([.command], KeyToken("n")))
        ])
        let definite = ConflictDetector.conflicts(in: [
            karabiner("Remap", chord: cmdShift3),
            system("Screenshot", chord: cmdShift3)
        ])
        let all = definite + overlap
        XCTAssertEqual(all.sorted { $0.category > $1.category }.first?.category, .systemVsTool)
    }

    /// 分类按「谁和谁撞」命名，所以每种组合都必须落到自己的名字上：
    /// 三种"常驻盖菜单"之外的情况，修的地方完全不同。
    func testToolCoveringAMenuItemIsItsOwnCategory() {
        let conflicts = ConflictDetector.conflicts(in: [
            menu("Screenshot", chord: cmdShift3),
            karabiner("Remap", chord: cmdShift3)
        ])
        XCTAssertEqual(conflicts.first?.category, .toolShadow)
        XCTAssertTrue(conflicts.first?.category.isRealConflict ?? false)
    }

    func testTwoToolsAreTheirOwnCategory() {
        let conflicts = ConflictDetector.conflicts(in: [
            karabiner("Remap", chord: cmdShift3),
            BindingItem(
                chord: cmdShift3, title: "hs", group: ["Hammerspoon"],
                source: .configFile, configTool: .hammerspoon
            )
        ])
        XCTAssertEqual(conflicts.first?.category, .toolVsTool)
        XCTAssertTrue(conflicts.first?.category.isAlwaysOnPair ?? false)
    }

    /// 同一个工具里两条规则撞键，说成「两个工具相撞」会把人引到错误的配置文件。
    func testTwoRulesOfTheSameToolAreOneToolNotTwo() {
        let conflicts = ConflictDetector.conflicts(in: [
            karabiner("Hyper + D", chord: cmdShift3),
            karabiner("Hyper + S", chord: cmdShift3)
        ])
        XCTAssertEqual(conflicts.first?.category, .toolSelfOverlap)
        XCTAssertTrue(conflicts.first?.category.isAlwaysOnPair ?? false)
    }

    func testTwoSystemHotkeysAreTheirOwnCategory() {        let conflicts = ConflictDetector.conflicts(in: [
            system("Screenshot", chord: cmdShift3),
            system("Save picture of screen as file", chord: cmdShift3)
        ])
        XCTAssertEqual(conflicts.first?.category, .systemVsSystem)
    }

    func testTypeFilterSelectsOneKindAndNothingElse() {
        let toolVsMenu = BindingConflict(id: "a", chordKey: "a", items: [
            menu("Screenshot", chord: cmdShift3),
            karabiner("Remap", chord: cmdShift3)
        ])
        let toolVsTool = BindingConflict(id: "b", chordKey: "b", items: [
            karabiner("Remap", chord: cmdShift3),
            BindingItem(
                chord: cmdShift3, title: "hs", group: ["Hammerspoon"],
                source: .configFile, configTool: .hammerspoon
            )
        ])
        XCTAssertFalse(ConflictFilter(category: .toolVsTool).matches(toolVsMenu))
        XCTAssertTrue(ConflictFilter(category: .toolVsTool).matches(toolVsTool))
        // 不选类型 = 全部类型。
        XCTAssertTrue(ConflictFilter(category: nil).matches(toolVsMenu))
    }

    // MARK: - Owner filter

    /// 「按 App / 全局筛选」和「按严重度筛选」是两个问题，必须能各答各的。
    func testOwnerFilterSeparatesAppsFromGlobalClashes() {
        let appClash = BindingConflict(id: "a", chordKey: "a", items: [
            BindingItem(
                chord: cmdShift3, title: "Screenshot", group: ["File"],
                source: .menu, appBundleID: "com.example.Editor"
            ),
            karabiner("Remap", chord: cmdShift3)
        ])
        let globalClash = BindingConflict(id: "b", chordKey: "b", items: [
            karabiner("Remap", chord: cmdShift3),
            BindingItem(
                chord: cmdShift3, title: "hs", group: ["Hammerspoon"],
                source: .configFile, configTool: .hammerspoon
            )
        ])

        XCTAssertTrue(ConflictOwnerFilter.all.matches(appClash))
        XCTAssertTrue(ConflictOwnerFilter.global.matches(globalClash))
        XCTAssertFalse(ConflictOwnerFilter.global.matches(appClash))
        XCTAssertTrue(ConflictOwnerFilter.app("com.example.Editor").matches(appClash))
        XCTAssertFalse(ConflictOwnerFilter.app("com.example.Editor").matches(globalClash))
        XCTAssertFalse(ConflictOwnerFilter.app("com.example.Other").matches(appClash))
    }

    func testGlobalOnlyMeansNoAppTakesPart() {
        let appClash = BindingConflict(id: "a", chordKey: "a", items: [
            BindingItem(
                chord: cmdShift3, title: "Screenshot", group: ["File"],
                source: .menu, appBundleID: "com.example.Editor"
            ),
            system("Screenshot", chord: cmdShift3)
        ])
        XCTAssertFalse(appClash.isGlobalOnly)
        XCTAssertEqual(appClash.appBundleIDs, ["com.example.Editor"])
    }

    /// 两个筛选可以叠加：只想看「被系统挡住」且「和这个 App 有关」的。
    func testTypeAndOwnerFiltersCompose() {
        let appShadow = BindingConflict(id: "a", chordKey: "a", items: [
            BindingItem(
                chord: cmdShift3, title: "Screenshot", group: ["File"],
                source: .menu, appBundleID: "com.example.Editor"
            ),
            system("Screenshot", chord: cmdShift3)
        ])
        XCTAssertTrue(ConflictFilter(category: .systemShadow).matches(appShadow))
        XCTAssertTrue(ConflictOwnerFilter.app("com.example.Editor").matches(appShadow))
        XCTAssertTrue(ConflictFilter(
            category: .systemShadow,
            owner: .app("com.example.Editor")
        ).matches(appShadow))
        XCTAssertFalse(ConflictFilter(category: .toolVsTool).matches(appShadow))
    }

    // MARK: - Verdicts

    func testTheLowestLayerWins() {
        let item = karabiner("Remap", chord: cmdShift3)
        let conflicts = ConflictDetector.conflicts(in: [
            item,
            system("Screenshot", chord: cmdShift3),
            menu("Screenshot", chord: cmdShift3)
        ])
        guard let verdict = conflicts.first?.verdict else { return XCTFail("no conflict") }
        guard case .winner(let itemID, let layer) = verdict else { return XCTFail("expected a winner") }
        XCTAssertEqual(itemID, item.id)
        XCTAssertEqual(layer, .driver)
    }

    func testMenuOnlyConflictsHaveNoStackToReasonAbout() {
        let conflicts = ConflictDetector.conflicts(in: [
            menu("New", chord: cmdShift3),
            menu("New Window", chord: cmdShift3)
        ])
        XCTAssertEqual(conflicts.first?.verdict, .menuOrder)
    }

    func testSameLayerTiesAreReportedRatherThanGuessed() {
        // Two system hotkeys: registration order decides, and nothing on disk records it.
        // Saying "tied" is the honest answer; picking one would be a coin flip dressed up.
        let conflicts = ConflictDetector.conflicts(in: [
            system("Screenshot", chord: cmdShift3),
            system("Other", chord: cmdShift3)
        ])
        guard case .tied(let ids, let layer)? = conflicts.first?.verdict else {
            return XCTFail("expected a tie")
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(layer, .system)
    }

    func testOwnerCountCountsOwnersNotItems() {
        let conflicts = ConflictDetector.conflicts(in: [
            menu("New", chord: cmdShift3),
            menu("New Window", chord: cmdShift3)
        ])
        // Two rows, one app: an overlap inside one app's menus, not two apps disagreeing.
        XCTAssertEqual(conflicts.first?.ownerCount, 1)
    }

    /// 同一个组合键在两个 App 里各撞一次时，两条记录必须能被区分开，
    /// 否则跨 App 列表会把它们当成同一行。
    func testScopedIDsKeepTheSameChordApartAcrossApps() {
        let inEditor = BindingConflict(id: "s:3/", chordKey: "s:3/", items: [
            BindingItem(
                chord: cmdShift3, title: "Screenshot", group: ["File"],
                source: .menu, appBundleID: "com.example.Editor"
            ),
            system("Screenshot", chord: cmdShift3)
        ])
        let inBrowser = BindingConflict(id: "s:3/", chordKey: "s:3/", items: [
            BindingItem(
                chord: cmdShift3, title: "Screenshot", group: ["File"],
                source: .menu, appBundleID: "com.example.Browser"
            ),
            system("Screenshot", chord: cmdShift3)
        ])
        let editor = inEditor.scoped(to: inEditor.appBundleIDs.sorted().first)
        let browser = inBrowser.scoped(to: inBrowser.appBundleIDs.sorted().first)
        XCTAssertNotEqual(editor.id, browser.id)
        XCTAssertEqual(editor.chordKey, browser.chordKey)
        XCTAssertEqual(editor.category, browser.category)
    }

    // MARK: - Type filter

    /// 按类型筛选要能精确到一种，而不是回到「严重度」那种粗分组。
    func testTypeFilterIsExact() {
        let overlap = BindingConflict(
            id: "a", chordKey: "a",
            items: [menu("New", chord: cmdShift3), menu("New Window", chord: cmdShift3)]
        )
        let crossTool = BindingConflict(
            id: "b", chordKey: "b",
            items: [karabiner("Remap", chord: cmdShift3), system("Screenshot", chord: cmdShift3)]
        )
        let shadowed = BindingConflict(
            id: "c", chordKey: "c",
            items: [menu("Shot", chord: cmdShift3), system("Screenshot", chord: cmdShift3)]
        )
        XCTAssertTrue(ConflictFilter(category: .menuOrder).matches(overlap))
        XCTAssertFalse(ConflictFilter(category: .systemVsTool).matches(overlap))
        XCTAssertTrue(ConflictFilter(category: .systemVsTool).matches(crossTool))
        XCTAssertFalse(ConflictFilter(category: .systemShadow).matches(crossTool))
        XCTAssertTrue(ConflictFilter(category: .systemShadow).matches(shadowed))
        XCTAssertTrue(ConflictFilter(category: nil).matches(shadowed))
    }

    // MARK: - Detection still behaves

    func testConfigBindingsJoinTheConflictSet() {
        let conflicts = ConflictDetector.conflicts(
            in: [menu("Screenshot", chord: cmdShift3)],
            external: [karabiner("Remap", chord: cmdShift3)]
        )
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].items.count, 2)
    }

    func testIdenticalEntriesRemainDuplicates() {
        let item = menu("New", chord: cmdShift3)
        XCTAssertTrue(ConflictDetector.conflicts(in: [item, item]).isEmpty)
    }
}
