import XCTest
@testable import KagiPeekCore

final class SearchCorpusTests: XCTestCase {
    private func item(_ modifiers: ModifierSet, _ key: String, _ title: String, group: [String] = ["Edit"]) -> BindingItem {
        BindingItem(chord: .combo(modifiers, KeyToken(key)), title: title, group: group, source: .menu)
    }

    func testModifierTokensInAnyOrder() {
        let items = [
            item([.command, .option], "x", "Special"),
            item([.command], "x", "Cut")
        ]
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("com op x").first?.title, "Special")
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("op cm x").first?.title, "Special")
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("x op cmd").first?.title, "Special")
    }

    func testPinyinInitialsAndSyllables() {
        let items = [item([.command], "x", "剪切", group: ["编辑"])]
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("jq").first?.title, "剪切")
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("jian qie").first?.title, "剪切")
    }

    func testLatinInitials() {
        let items = [item([.command], "f", "Find Similar", group: ["Edit"])]
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("fs").first?.title, "Find Similar")
    }

    func testMultipleTokensMustAllMatch() {
        let items = [item([.command], "x", "Cut")]
        XCTAssertTrue(SearchCorpus(items: items, style: .symbols).search("cmd zzz").isEmpty)
    }

    func testPlusSeparator() {
        let items = [item([.command, .shift], "3", "Screenshot", group: ["System"])]
        XCTAssertEqual(SearchCorpus(items: items, style: .symbols).search("cmd+shift+3").first?.title, "Screenshot")
    }
}
