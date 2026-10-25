import XCTest
@testable import KagiPeekCore

/// 菜单栏里命令和数据混在一起，而且数据是**嵌套**的：Safari 的历史记录藏在「某一天」子菜单里，
/// 书签藏在文件夹子菜单里。判定规则钉在这里。
final class MenuContentPolicyTests: XCTestCase {
    /// 普通命令菜单：全读，没快捷键的命令（如 "Zoom"）也保留。
    func testCommandMenuKeepsEverything() {
        let decision = MenuContentPolicy.decideOpenMenu(childCount: 34)
        XCTAssertFalse(decision.looksLikeContent)
        XCTAssertEqual(decision.childrenToVisit, 34)
        XCTAssertTrue(decision.keepsShortcutlessChildren)
    }

    /// 子项少到没有区分必要：不采样，按命令菜单处理。
    func testSmallMenuIsNeverTreatedAsData() {
        XCTAssertFalse(MenuContentPolicy.needsSample(childCount: 11))
        let decision = MenuContentPolicy.decideSubmenu(childCount: 11, sampledShortcut: nil)
        XCTAssertFalse(decision.looksLikeContent)
        XCTAssertEqual(decision.childrenToVisit, 11)
        XCTAssertTrue(decision.keepsShortcutlessChildren)
    }

    /// 数据子菜单（一天的浏览记录、一个书签文件夹）：样本里没有快捷键 → 整段跳过。
    func testDataSubmenuIsSkippedEntirely() {
        let day = MenuContentPolicy.decideSubmenu(childCount: 198, sampledShortcut: false)
        XCTAssertTrue(day.looksLikeContent)
        XCTAssertEqual(day.childrenToVisit, 0)
        XCTAssertTrue(day.skipsNodeEntirely)

        let folder = MenuContentPolicy.decideSubmenu(childCount: 138, sampledShortcut: false)
        XCTAssertEqual(folder.childrenToVisit, 0)
    }

    /// 子菜单里有快捷键 → 仍是命令菜单，哪怕子项很多。
    func testLargeMenuWithShortcutsStaysACommandMenu() {
        let decision = MenuContentPolicy.decideSubmenu(childCount: 62, sampledShortcut: true)
        XCTAssertFalse(decision.looksLikeContent)
        XCTAssertEqual(decision.childrenToVisit, 62)
    }

    /// 超过硬上限的平铺菜单：只读命令前缀，且只保留有快捷键的条目。
    func testOversizedMenuFallsBackToTheCommandPrefix() {
        let decision = MenuContentPolicy.decideSubmenu(childCount: 2_344, sampledShortcut: true)
        XCTAssertTrue(decision.looksLikeContent)
        XCTAssertEqual(decision.childrenToVisit, MenuContentPolicy.commandPrefix)
        XCTAssertFalse(decision.keepsShortcutlessChildren)
        XCTAssertFalse(decision.skipsNodeEntirely)
    }

    func testThresholdsAreOrdered() {
        XCTAssertLessThan(MenuContentPolicy.commandPrefix, MenuContentPolicy.maxCommandChildren)
        XCTAssertLessThan(MenuContentPolicy.sampleLimit, MenuContentPolicy.sampleThreshold)
        XCTAssertLessThan(MenuContentPolicy.sampleThreshold, MenuContentPolicy.maxCommandChildren)
    }
}

/// 浏览器把书签和历史记录放在顶层菜单里，且**开头就是真命令**（⌘D 添加书签、⌘Y 显示历史），
/// 所以"采样看有没有快捷键"抓不到后面那几十条链接。这类菜单按名字认。
final class DataMenuTitleTests: XCTestCase {
    func testRecognisesTheBookmarkAndHistoryMenusInBothLanguages() {
        for title in ["Bookmarks", "bookmarks", "History", "书签", "历史记录", "阅读列表", "Reading List"] {
            XCTAssertTrue(MenuContentPolicy.isDataMenu(title: title), title)
        }
    }

    func testDoesNotMatchCommandMenus() {
        for title in ["Edit", "编辑", "View", "显示", "Window", "窗口", "Safari", "文件", "File", "Develop", "帮助"] {
            XCTAssertFalse(MenuContentPolicy.isDataMenu(title: title), title)
        }
    }

    /// 各种实际拼写：大小写、末尾省略号、首尾空格。
    func testNormalisesCommonSpellings() {
        XCTAssertTrue(MenuContentPolicy.isDataMenu(title: " bookmarks "))
        XCTAssertTrue(MenuContentPolicy.isDataMenu(title: "History…"))
        XCTAssertTrue(MenuContentPolicy.isDataMenu(title: "书签…"))
    }

    /// 命中名字的菜单：保留带快捷键的命令，丢掉整份列表；超大的只读命令前缀。
    func testNamedDataMenuKeepsOnlyCommands() {
        let safariBookmarks = MenuContentPolicy.decideDataMenuByTitle(childCount: 62)
        XCTAssertTrue(safariBookmarks.looksLikeContent)
        XCTAssertEqual(safariBookmarks.childrenToVisit, 62)
        XCTAssertFalse(safariBookmarks.keepsShortcutlessChildren)

        let chromeBookmarks = MenuContentPolicy.decideDataMenuByTitle(childCount: 2_344)
        XCTAssertEqual(chromeBookmarks.childrenToVisit, MenuContentPolicy.commandPrefix)
        XCTAssertFalse(chromeBookmarks.keepsShortcutlessChildren)
    }
}


/// 顶层菜单只用「名字」和「体量」判定，**不采样**：`开发`（27 项）前几项没有快捷键，
/// 采样会把它误判成数据，连带丢掉 18 条没有快捷键的真命令。
final class TopLevelMenuTests: XCTestCase {
    func testTopLevelCommandMenuIsNeverJudgedBySample() {
        let develop = MenuContentPolicy.decideOpenMenu(childCount: 27)
        XCTAssertFalse(develop.looksLikeContent)
        XCTAssertEqual(develop.childrenToVisit, 27)
        XCTAssertTrue(develop.keepsShortcutlessChildren)
    }

    func testOversizedTopLevelMenuReadsTheCommandPrefix() {
        let menu = MenuContentPolicy.decideOpenMenu(childCount: 2_344)
        XCTAssertTrue(menu.looksLikeContent)
        XCTAssertEqual(menu.childrenToVisit, MenuContentPolicy.commandPrefix)
        XCTAssertFalse(menu.keepsShortcutlessChildren)
    }
}
