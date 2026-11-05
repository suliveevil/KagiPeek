import XCTest
@testable import KagiPeekCore

final class SearchSessionResetTests: XCTestCase {
    func testReopeningStartsFromAnEmptyQueryAndFirstRow() {
        var snapshot = SearchSnapshot()
        snapshot.query = "undo"
        snapshot.results = [
            BindingItem(chord: KeyChord([]), title: "Undo", group: ["Edit"], source: .menu)
        ]
        snapshot.selection = 7
        snapshot.scrollRequest = 12
        snapshot.scopeAppID = "com.apple.Safari"
        snapshot.scopeName = "Safari"
        snapshot.loadState = .ready
        snapshot.usedBuiltInCatalog = true

        snapshot.beginNewSession()

        XCTAssertEqual(snapshot.query, "")
        XCTAssertTrue(snapshot.results.isEmpty)
        XCTAssertEqual(snapshot.selection, 0, "an empty query selects the first row, not the last one")
        XCTAssertGreaterThan(snapshot.scrollRequest, 12, "the list is scrolled back to the top")
        XCTAssertNil(snapshot.scopeAppID)
        XCTAssertTrue(snapshot.scopeName.isEmpty)
        XCTAssertEqual(snapshot.loadState, .idle)
        XCTAssertFalse(snapshot.usedBuiltInCatalog)
    }

    func testShiftHintLayerDoesNotSurviveIntoTheNextPanelSession() {
        var panel = PanelState()
        panel.shiftHintActive = true
        panel.prefixLabels = ["0", "1", "2"]
        panel.pageIndex = 3

        panel.beginNewSession()

        XCTAssertFalse(panel.shiftHintActive, "the 0–9 / a–z hint layer belongs to its own session")
        XCTAssertTrue(panel.prefixLabels.isEmpty)
        XCTAssertEqual(panel.pageIndex, 0)
    }
}
