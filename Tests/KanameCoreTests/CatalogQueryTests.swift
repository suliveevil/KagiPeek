import XCTest
@testable import KanameCore

final class CatalogQueryTests: XCTestCase {
    /// A fresh settings snapshot becomes the default query: no forced scan, and the two
    /// catalog flags carried over verbatim.
    func testDefaultsFromSettings() {
        let query = CatalogQuery(settings: AppSettingsSnapshot())
        XCTAssertEqual(query.language, .system)
        XCTAssertTrue(query.includeBuiltIn)
        XCTAssertFalse(query.showAppleMenu)
        XCTAssertFalse(query.force)
    }

    /// Non-default settings values flow into the query rather than being ignored.
    func testCarriesSettingsValues() {
        var settings = AppSettingsSnapshot()
        settings.language = .chinese
        settings.includeBuiltInCatalog = false
        settings.showAppleMenu = true
        let query = CatalogQuery(settings: settings)
        XCTAssertEqual(query.language, .chinese)
        XCTAssertFalse(query.includeBuiltIn)
        XCTAssertTrue(query.showAppleMenu)
        XCTAssertFalse(query.force)
    }

    /// A scoped caller changes only the fields that differ; the rest still reflects settings.
    func testOverrideKeepsOtherFields() {
        var settings = AppSettingsSnapshot()
        settings.language = .english
        settings.showAppleMenu = true
        var query = CatalogQuery(settings: settings)
        query.includeBuiltIn = false
        query.force = true
        XCTAssertEqual(query.language, .english)
        XCTAssertFalse(query.includeBuiltIn)
        XCTAssertTrue(query.showAppleMenu)
        XCTAssertTrue(query.force)
    }

    func testEquatable() {
        var settings = AppSettingsSnapshot()
        settings.language = .english
        settings.showAppleMenu = true
        let a = CatalogQuery(settings: settings)
        let b = CatalogQuery(settings: settings)
        XCTAssertEqual(a, b)

        var forced = a
        forced.force = true
        XCTAssertNotEqual(a, forced)

        var scoped = a
        scoped.includeBuiltIn = false
        XCTAssertNotEqual(a, scoped)
    }
}
