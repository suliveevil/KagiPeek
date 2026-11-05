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

    /// The bounded top-K must be the same list a full sort would have produced, not merely
    /// the same set: the first page is what the palette draws.
    func testLimitReturnsTheUnboundedOrderPrefix() {
        let items = (0..<12).map { item([.command], "s", "Save \($0)") }
        let corpus = SearchCorpus(items: items, style: .symbols)
        let all = corpus.search("save", limit: 100).map(\.id)
        XCTAssertEqual(corpus.search("save", limit: 4).map(\.id), Array(all.prefix(4)))
    }

    // MARK: - Limit bounds

    /// The empty-query branch used to run before `limit` was checked, so `prefix(-1)`
    /// trapped and killed the process. The assertion that matters is that this test
    /// reaches the line after the call: an illegal argument must yield no rows, not a
    /// `Fatal error: Can't take a prefix of negative length from a collection`.
    func testEmptyQueryWithNegativeLimitReturnsEmptyWithoutTrapping() {
        let corpus = SearchCorpus(items: [item([.command], "x", "Cut")], style: .symbols)
        XCTAssertEqual(corpus.search("", limit: -1), [])
        XCTAssertTrue(corpus.search("", limit: -1).isEmpty)
    }

    /// `limit == 0` asks for no rows, empty query or not.
    func testZeroLimitReturnsEmpty() {
        let corpus = SearchCorpus(items: [item([.command], "x", "Cut")], style: .symbols)
        XCTAssertEqual(corpus.search("", limit: 0), [])
        XCTAssertEqual(corpus.search("cut", limit: 0), [])
    }

    /// The ranked path has its own use of `limit`; a negative value must not reach it either.
    func testNonEmptyQueryWithNegativeLimitReturnsEmptyWithoutTrapping() {
        let corpus = SearchCorpus(items: [item([.command], "x", "Cut")], style: .symbols)
        XCTAssertEqual(corpus.search("cut", limit: -1), [])
        XCTAssertEqual(corpus.search("cmd x", limit: -5), [])
    }

    /// An empty query means "no filter": the first `limit` rows, in corpus order.
    func testEmptyQueryReturnsTheCorpusPrefix() {
        let items = (0..<6).map { item([.command], "s", "Save \($0)") }
        let corpus = SearchCorpus(items: items, style: .symbols)
        let all = corpus.documents.map(\.item)
        XCTAssertEqual(corpus.search(""), all)
        XCTAssertEqual(corpus.search("   "), all)
        XCTAssertEqual(corpus.search("", limit: 3).map(\.id), all.prefix(3).map(\.id))
    }

    /// Rows that tie on score and title are ordered by id, so the list cannot shuffle
    /// between keystrokes even though it is no longer a full `sort`.
    func testTiesAreDeterministic() {
        let items = [
            item([.command], "z", "Same"),
            item([.command], "a", "Same"),
            item([.command], "m", "Same")
        ]
        let corpus = SearchCorpus(items: items, style: .symbols)
        let first = corpus.search("same", limit: 3).map(\.id)
        XCTAssertEqual(first, corpus.search("same", limit: 3).map(\.id))
        XCTAssertEqual(first, first.sorted())
    }
}
