import XCTest
@testable import KagiPeekCore

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

    func testChordStepsJoined() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        XCTAssertEqual(KeyFormatter.render(chord, style: .symbols), "⌘K ⌘C")
        XCTAssertEqual(KeyFormatter.breadcrumb(for: chord, style: .symbols), ["⌘K", "⌘C"])
    }
}
