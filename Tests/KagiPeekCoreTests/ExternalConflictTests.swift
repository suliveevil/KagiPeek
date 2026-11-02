import XCTest
@testable import KagiPeekCore

final class ExternalConflictTests: XCTestCase {
    func testSystemHotkeyConflictsWithAppBinding() {
        let app = BindingItem(chord: .combo([.command], KeyToken("space")), title: "Custom", group: ["Edit"], source: .menu)
        let system = BindingItem(chord: .combo([.command], KeyToken("space")), title: "Spotlight", group: ["System hotkeys"], source: .system)
        let conflicts = ConflictDetector.conflicts(in: [app], external: [system])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].items.count, 2)
        XCTAssertTrue(conflicts[0].items.contains { $0.source == .system })
    }

    func testNoExternalMeansNoConflict() {
        let app = BindingItem(chord: .combo([.command], KeyToken("space")), title: "Custom", group: ["Edit"], source: .menu)
        XCTAssertTrue(ConflictDetector.conflicts(in: [app]).isEmpty)
    }
}
