import XCTest
@testable import KagiPeekCore

final class SearchCorpusMatchTests: XCTestCase {
    private let items = [
        BindingItem(chord: .combo([.command], KeyToken("p")), title: "Print", group: ["File"], source: .menu),
        BindingItem(chord: .combo([.command], KeyToken("s")), title: "Save", group: ["File"], source: .menu),
        BindingItem(chord: .combo([.command, .shift], KeyToken("3")), title: "Screenshot", group: ["System"], source: .builtIn)
    ]

    func testPrefixMatchFirst() {
        let results = SearchCorpus(items: items, style: .symbols).search("pri")
        XCTAssertEqual(results.first?.title, "Print")
    }

    func testSubsequenceMatch() {
        let results = SearchCorpus(items: items, style: .symbols).search("scsh")
        XCTAssertEqual(results.first?.title, "Screenshot")
    }

    func testShortcutTextMatch() {
        let results = SearchCorpus(items: items, style: .symbols).search("⇧⌘3")
        XCTAssertEqual(results.first?.title, "Screenshot")
    }

    func testNoMatch() {
        XCTAssertTrue(SearchCorpus(items: items, style: .symbols).search("zzzz").isEmpty)
    }
}
