import XCTest
@testable import KanameCore

final class PrefixResolverTests: XCTestCase {
    func makeCatalog() -> [BindingItem] {
        [
            BindingItem(chord: .combo([.command], KeyToken("c")), title: "Copy", group: ["Edit"], source: .menu),
            BindingItem(chord: .combo([.command, .shift], KeyToken("c")), title: "Copy Style", group: ["Edit"], source: .menu),
            BindingItem(chord: .combo([.option], KeyToken("left")), title: "Word Left", group: ["Edit"], source: .menu)
        ]
    }

    func testHitsAtModifierLevel() {
        let hits = PrefixResolver.hits(for: .modifiers([.command]), in: makeCatalog())
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.nextKey == KeyToken("c") })
    }

    func testProbeReplacesModifierStep() {
        let probe = PrefixResolver.probe(after: .modifiers([.command]), modifiers: [.command], key: KeyToken("c"))
        XCTAssertEqual(probe.steps.count, 1)
        XCTAssertEqual(probe.relation(to: .modifiers([.command])), .candidate)
        XCTAssertNotNil(PrefixResolver.exactMatch(in: makeCatalog(), for: probe))
    }

    func testDescendantAndExact() {
        let items = [
            BindingItem(chord: KeyChord([.combo([.command], KeyToken("k")), .combo([.command], KeyToken("c"))]), title: "Chord", group: ["Edit"], source: .menu)
        ]
        let level1 = PrefixResolver.probe(after: .modifiers([.command]), modifiers: [.command], key: KeyToken("k"))
        XCTAssertNil(PrefixResolver.exactMatch(in: items, for: level1))
        XCTAssertEqual(PrefixResolver.descendantCount(in: items, for: level1), 1)
        let level2 = PrefixResolver.probe(after: level1, modifiers: [.command], key: KeyToken("c"))
        XCTAssertNotNil(PrefixResolver.exactMatch(in: items, for: level2))
    }

    func testDisabledFiltering() {
        let disabled = BindingItem(chord: .combo([.command], KeyToken("x")), title: "Disabled", group: ["Edit"], isEnabled: false, source: .menu)
        XCTAssertEqual(PrefixResolver.hits(for: .modifiers([.command]), in: [disabled], includeDisabled: false).count, 0)
        XCTAssertEqual(PrefixResolver.hits(for: .modifiers([.command]), in: [disabled], includeDisabled: true).count, 1)
    }
}
