import XCTest
@testable import KanameCore

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

    // MARK: - Match-only path

    private var mixedItems: [BindingItem] {
        items + [
            BindingItem(
                chord: .combo([.command], KeyToken("v")),
                title: "粘贴并匹配样式",
                group: ["编辑"],
                source: .menu
            ),
            BindingItem(
                chord: .combo([.option, .command], KeyToken("t")),
                title: "Toggle Toolbar",
                group: ["View", "Window"],
                source: .menu
            ),
            BindingItem(
                chord: .combo([.control], KeyToken("space")),
                title: "输入法",
                group: ["系统"],
                source: .system
            )
        ]
    }

    /// The match-only predicate must select exactly the rows the scoring search selects,
    /// for single- and multi-term queries alike; the expected set comes from `search` with
    /// no limit. Multi-term forms mirror the panel filter's modifier + letter token queue.
    func testMatchOnlySetEqualsScoringSet() {
        let corpus = SearchCorpus(items: mixedItems, style: .symbols)
        for query in ["s", "save", "pi", "scsh", "⌘", "cmd", "文件", "wen", "ni", "zzz", "st", "⌘ s", "⌃ f", "⌥ t", "⌘ ⌥ s", "⌃ ⌥"] {
            let expected = Set(corpus.search(query, limit: corpus.documents.count).map(\.id))
            let actual = Set(corpus.matchingItems(for: query).map(\.id))
            XCTAssertEqual(actual, expected, "query: \(query)")
        }
    }

    /// The panel orders the surviving rows itself, so the match list keeps corpus order —
    /// the scoring path's rank order would be a new rule the panel never asks for.
    func testMatchOnlyOrderFollowsTheCorpusOrder() {
        let corpus = SearchCorpus(items: mixedItems, style: .symbols)
        let matched = corpus.matchingItems(for: "s")
        let expected = corpus.documents.map(\.item).filter { item in
            matched.contains { $0.id == item.id }
        }
        XCTAssertEqual(matched.map(\.id), expected.map(\.id))
    }

    /// A case where the two orders genuinely differ: the corpus lists `Banana` first, but
    /// `Apple` outranks it (prefix beat substring). Match-only must keep `Banana` first.
    func testMatchOnlyDoesNotReorderByScore() {
        let corpus = SearchCorpus(
            items: [
                BindingItem(chord: .combo([.command], KeyToken("b")), title: "Banana", group: [], source: .menu),
                BindingItem(chord: .combo([.command], KeyToken("a")), title: "Apple", group: [], source: .menu)
            ],
            style: .symbols
        )
        XCTAssertEqual(corpus.search("a", limit: corpus.documents.count).map(\.title), ["Apple", "Banana"])
        XCTAssertEqual(corpus.matchingItems(for: "a").map(\.title), ["Banana", "Apple"])
    }

    /// More than one term must keep corpus order too, not the scoring path's rank order.
    /// Both rows match "⌘ a", but Apple outranks Banana (exact key token / prefix), so a
    /// ranked result would be the reverse of the corpus sequence.
    func testMultiTermPreservesCorpusOrder() {
        let corpus = SearchCorpus(
            items: [
                BindingItem(chord: .combo([.command], KeyToken("b")), title: "Banana", group: [], source: .menu),
                BindingItem(chord: .combo([.command], KeyToken("a")), title: "Apple", group: [], source: .menu)
            ],
            style: .symbols
        )
        XCTAssertEqual(
            corpus.search("⌘ a", limit: corpus.documents.count).map(\.title),
            ["Apple", "Banana"]
        )
        let matched = corpus.matchingItems(for: "⌘ a")
        let expected = corpus.documents.map(\.item).filter { item in
            matched.contains { $0.id == item.id }
        }
        XCTAssertEqual(matched.map(\.id), expected.map(\.id))
        XCTAssertEqual(matched.map(\.title), ["Banana", "Apple"])
    }

    /// An empty query means "no filter", which is every row, still in corpus order.
    func testEmptyQueryReturnsEveryRowInOrder() {
        let corpus = SearchCorpus(items: mixedItems, style: .symbols)
        let all = corpus.documents.map(\.item.id)
        XCTAssertEqual(corpus.matchingItems(for: "").map(\.id), all)
        XCTAssertEqual(corpus.matchingItems(for: "   ").map(\.id), all)
    }

    /// More than one term matches the scoring path's set, keeps corpus order, and never
    /// ranks: the panel only needs the surviving rows, in its own sequence.
    func testMultiTermMatchesScoringSetAndKeepsCorpusOrder() {
        let corpus = SearchCorpus(items: mixedItems, style: .symbols)
        let query = "⌘ s"
        let expected = Set(corpus.search(query, limit: corpus.documents.count).map(\.id))
        let actual = corpus.matchingItems(for: query)
        XCTAssertEqual(Set(actual.map(\.id)), expected)
        let ordered = corpus.documents.map(\.item).filter { item in
            actual.contains { $0.id == item.id }
        }
        XCTAssertEqual(actual.map(\.id), ordered.map(\.id))
    }
}
