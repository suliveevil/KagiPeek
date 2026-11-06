import XCTest
@testable import KanameCore

final class KeySegmentTests: XCTestCase {
    /// The chord is split into glyphs so a held modifier can be lit instead of hidden. The
    /// split must therefore keep the shortcut's text intact — including the ⌘ that used to
    /// be stripped while it was held.
    func testModifierGlyphsKeepTheirIdentity() {
        let chord = KeyChord.combo([.command], KeyToken("c"))
        let segments = KeyFormatter.segments(for: chord, style: .symbols)
        XCTAssertEqual(segments.map(\.text), ["⌘", "C"])
        XCTAssertEqual(segments.first?.kind, .modifier(.command))
    }

    func testSegmentedChordRendersExactlyLikeThePlainString() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command, .shift], KeyToken("c"))
        ])
        XCTAssertEqual(
            KeyFormatter.segments(for: chord, style: .symbols).map(\.text).joined(),
            KeyFormatter.render(chord, style: .symbols)
        )
        XCTAssertEqual(
            KeyFormatter.segments(for: chord, style: .words).map(\.text).joined(),
            KeyFormatter.render(chord, style: .words)
        )
    }

    func testMultiStrokeChordsCarryASeparator() {
        let chord = KeyChord([
            KeyStep.combo([.command], KeyToken("k")),
            KeyStep.combo([.command], KeyToken("c"))
        ])
        let kinds = KeyFormatter.segments(for: chord, style: .symbols).map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .separator }.count, 1)
    }
}
