import XCTest
@testable import KanameCore

/// 菜单路径分层加权：越靠近命令本身的层级，权重越高（Menu-Bar-Search 的祖先逐层减半）。
final class MenuPathWeightTests: XCTestCase {
    private func item(_ title: String, group: [String]) -> BindingItem {
        BindingItem(chord: .combo([.command], KeyToken("a")), title: title, group: group, source: .menu)
    }

    /// "View" 是几十个命令的祖先，同名标题才是用户想找的那个。
    func testTitleMatchBeatsTopLevelMenuMatch() {
        let items = [
            item("Show Sidebar", group: ["View"]),
            item("View Source", group: ["Window"])
        ]
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("view").first?.title, "View Source")
    }

    /// 同一个词出现在不同深度：近祖先（直接父菜单）压过远祖先（顶层菜单）。
    func testNearerLevelOutranksDeeperAncestor() {
        let items = [
            // View › Appearance › Sidebar —— "view" 是远祖先，权重减半
            item("Sidebar", group: ["View", "Appearance"]),
            // Format › View › Font —— "view" 是近祖先，权重不减
            item("Font", group: ["Format", "View"])
        ]
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("view").first?.title, "Font")
    }

    /// 深层路径里，顶层菜单名永远压不过命令自己的标题（回归：旧实现把整条路径拼成
    /// 一个 haystack，顶层菜单的精确匹配与标题精确同分）。
    func testDeepAncestorCannotOutrankOwnTitle() {
        let items = [
            item("Zoom", group: ["View", "Appearance", "Text Size"]),
            item("View", group: ["Window"])
        ]
        // "view" 精确命中 "View" 的标题（2000+90），而对 "Zoom" 只是 level 2 的祖先
        // （2000/4）。标题必须赢。
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("view").first?.title, "View")
    }

    /// 单层路径行为不变：按菜单名搜仍然能命中其下命令。
    func testSingleLevelPathStillMatches() {
        let items = [item("Close", group: ["File"])]
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("file").first?.title, "Close")
    }

    /// 菜单名精确命中也压不过标题的前缀命中：叶子永远最高，最近的祖先也只有一半权重。
    func testExactMenuNameLosesToTitlePrefix() {
        let items = [
            item("Show Sidebar", group: ["View"]),   // "view" 精确命中菜单名：1000
            item("View Source", group: ["Window"])   // "view" 前缀命中标题：1590
        ]
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("view").first?.title, "View Source")
    }

}
