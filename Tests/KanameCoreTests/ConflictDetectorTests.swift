import XCTest
@testable import KanameCore

final class ConflictDetectorTests: XCTestCase {
    func testDetectsDistinctTitlesOnSameChord() {
        let a = BindingItem(chord: .combo([.command], KeyToken("n")), title: "New", group: ["File"], source: .menu)
        let b = BindingItem(chord: .combo([.command], KeyToken("n")), title: "New Window", group: ["File"], source: .menu)
        let conflicts = ConflictDetector.conflicts(in: [a, b])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].items.count, 2)
    }

    func testIgnoresExactDuplicates() {
        let a = BindingItem(chord: .combo([.command], KeyToken("n")), title: "New", group: ["File"], source: .menu)
        XCTAssertTrue(ConflictDetector.conflicts(in: [a, a]).isEmpty)
    }
}
