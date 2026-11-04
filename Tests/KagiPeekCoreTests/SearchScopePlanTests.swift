import XCTest
@testable import KagiPeekCore

/// Pins the scope-reset rules `ShortcutEngine.selectSearchScope` used to inline: what a scope
/// switch clears, and which load state the palette starts in.
final class SearchScopePlanTests: XCTestCase {
    private func snapshot() -> SearchSnapshot {
        var search = SearchSnapshot()
        search.query = "find"
        search.scopeAppID = "old"
        search.scopeName = "Old"
        search.scopeItems = [BindingItem(chord: .empty, title: "X", group: [], source: .menu)]
        search.loadState = .ready
        search.usedBuiltInCatalog = true
        return search
    }

    func testSwitchingToFrontmostClearsTheScopeAndGoesIdle() {
        let next = SearchScopePlan.switched(snapshot(), appID: nil, name: "Ignored", isRunning: false)
        XCTAssertNil(next.scopeAppID)
        XCTAssertEqual(next.scopeName, "")
        XCTAssertTrue(next.scopeItems.isEmpty)
        XCTAssertEqual(next.loadState, .idle)
        XCTAssertFalse(next.usedBuiltInCatalog)
        // The query is the view's own state and survives a scope switch.
        XCTAssertEqual(next.query, "find")
    }

    func testSwitchingToARunningAppStartsLoadingWithItsName() {
        let next = SearchScopePlan.switched(snapshot(), appID: "app", name: "Notes", isRunning: true)
        XCTAssertEqual(next.scopeAppID, "app")
        XCTAssertEqual(next.scopeName, "Notes")
        XCTAssertTrue(next.scopeItems.isEmpty)
        XCTAssertEqual(next.loadState, .loading)
        XCTAssertFalse(next.usedBuiltInCatalog)
    }

    func testSwitchingToAnAppThatIsNotRunningStaysIdle() {
        let next = SearchScopePlan.switched(snapshot(), appID: "gone", name: "Gone", isRunning: false)
        XCTAssertEqual(next.scopeAppID, "gone")
        XCTAssertEqual(next.scopeName, "")
        XCTAssertEqual(next.loadState, .idle)
    }

    func testFinishedScanMapsOnlyDeniedPermissionToAPermissionState() {
        XCTAssertEqual(SearchScopePlan.loadState(for: .permissionDenied), .permissionDenied)
        XCTAssertEqual(SearchScopePlan.loadState(for: .ok), .ready)
        XCTAssertEqual(SearchScopePlan.loadState(for: .noMenus), .ready)
    }
}
