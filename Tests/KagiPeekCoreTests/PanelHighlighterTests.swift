import XCTest
@testable import KagiPeekCore

final class PanelHighlighterTests: XCTestCase {
    private let items = [
        BindingItem(chord: .combo([.command], KeyToken("c")), title: "Copy", group: ["Edit"], source: .menu),
        BindingItem(chord: .combo([.command, .shift], KeyToken("s")), title: "Save As", group: ["File"], source: .menu),
        BindingItem(chord: .combo([.control], KeyToken("a")), title: "Line Start", group: ["Edit"], source: .builtIn),
        BindingItem(chord: KeyChord([.combo([.command], KeyToken("k")), .combo([.command], KeyToken("c"))]), title: "Chord", group: ["Edit"], source: .menu)
    ]

    func testHeldCommandHighlightsCommandRows() {
        let ids = PanelHighlighter.highlightedIDs(items: items, prefix: .empty, heldModifiers: [.command])
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.contains(items[0].id))
        XCTAssertTrue(ids.contains(items[1].id))
        XCTAssertTrue(ids.contains(items[3].id))
        XCTAssertFalse(ids.contains(items[2].id))
    }

    func testNoModifiersMeansNoHighlight() {
        XCTAssertTrue(PanelHighlighter.highlightedIDs(items: items, prefix: .empty, heldModifiers: []).isEmpty)
    }

    func testControlHighlightsOnlyControlRows() {
        let ids = PanelHighlighter.highlightedIDs(items: items, prefix: .empty, heldModifiers: [.control])
        XCTAssertEqual(ids, [items[2].id])
    }

    func testChordLevelHighlightsItsRows() {
        let prefix = KeyChord.combo([.command], KeyToken("k"))
        let ids = PanelHighlighter.highlightedIDs(items: items, prefix: prefix, heldModifiers: [.command])
        XCTAssertEqual(ids, [items[3].id])
    }
}
