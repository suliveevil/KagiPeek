import XCTest
@testable import KanameCore

final class KeyFormatterTests: XCTestCase {
    func testCanonicalModifierOrder() {
        let chord = KeyChord.combo([.command, .shift, .option, .control], KeyToken("k"))
        XCTAssertEqual(KeyFormatter.render(chord, style: .symbols), "⌃⌥⇧⌘K")
    }

    func testSpecialKeys() {
        XCTAssertEqual(KeyFormatter.render(.combo([.command], KeyToken("left")), style: .symbols), "⌘←")
        XCTAssertEqual(KeyFormatter.render(.combo([.command], KeyToken("delete")), style: .symbols), "⌘⌫")
        XCTAssertEqual(KeyFormatter.render(.combo([.command], KeyToken("f5")), style: .symbols), "⌘F5")
        XCTAssertEqual(KeyFormatter.render(.combo([.shift, .command], KeyToken("3")), style: .symbols), "⇧⌘3")
    }

    func testWordsStyle() {
        XCTAssertEqual(KeyFormatter.render(.combo([.command, .shift], KeyToken("z")), style: .words), "shift + command + Z")
    }

    func testGlobeRendersFirst() {
        XCTAssertEqual(KeyFormatter.render(.combo([.control, .function], KeyToken("f")), style: .symbols), "🌐⌃F")
        XCTAssertEqual(KeyFormatter.render(.combo([.function, .command], KeyToken("e")), style: .symbols), "🌐⌘E")
        XCTAssertEqual(KeyFormatter.render(.combo([.control, .function], KeyToken("f")), style: .words), "fn + control + F")
    }

    func testChordStepsJoined() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        XCTAssertEqual(KeyFormatter.render(chord, style: .symbols), "⌘K ⌘C")
        XCTAssertEqual(KeyFormatter.breadcrumb(for: chord, style: .symbols), ["⌘K", "⌘C"])
    }
}
