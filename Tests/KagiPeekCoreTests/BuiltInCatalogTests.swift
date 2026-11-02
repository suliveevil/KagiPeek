import XCTest
@testable import KagiPeekCore

final class BuiltInCatalogTests: XCTestCase {
    func testCatalogSize() {
        XCTAssertEqual(BuiltInCatalog.entries.count, 100)
    }

    func testEveryEntryBuilds() {
        for language in [AppLanguage.english, .chinese] {
            let items = BuiltInCatalog.items(language: language)
            XCTAssertEqual(items.count, BuiltInCatalog.entries.count)
            for item in items {
                XCTAssertFalse(item.title.isEmpty)
                XCTAssertEqual(item.chord.steps.count, 1)
                XCTAssertNotNil(item.chord.steps.first?.key)
            }
        }
    }

    func testNoDuplicateChordWithinSameScope() {
        var seen: [String: String] = [:]
        for entry in BuiltInCatalog.entries {
            let key = "\(entry.bundleID ?? "*")|\(entry.descriptor)"
            XCTAssertNil(seen[key], "duplicate built-in shortcut: \(key) (\(entry.titleEN) vs \(seen[key] ?? ""))")
            seen[key] = entry.titleEN
        }
    }

    func testEnglishTitlesDifferFromChinese() {
        let pairs = BuiltInCatalog.entries.filter { $0.titleEN == $0.titleZH }
        XCTAssertTrue(pairs.isEmpty, "missing English titles: \(pairs.map(\.titleZH))")
    }
}
