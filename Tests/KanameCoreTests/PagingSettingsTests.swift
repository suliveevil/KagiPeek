import XCTest
@testable import KanameCore

final class PagingSettingsTests: XCTestCase {
    func testDefaultAndSchemaVersion() {
        XCTAssertEqual(AppSettingsSnapshot().pagingPairs, [.semicolonQuote])
        XCTAssertEqual(AppSettingsSnapshot.currentSchemaVersion, 10)
    }

    /// A v7 file has no `pagingPairs`; decoding applies the default without a migration step.
    func testVersionSevenPayloadWithoutTheFieldUsesTheDefault() throws {
        let json = #"{"schemaVersion":7,"settings":{"holdDelay":0.4}}"#.data(using: .utf8)!
        let payload = try JSONDecoder().decode(SettingsPayload.self, from: json)
        XCTAssertEqual(payload.settings.pagingPairs, [.semicolonQuote])
        XCTAssertEqual(payload.settings.holdDelay, 0.4)

        let migrated = SettingsMigrator.migrate(payload)
        XCTAssertEqual(migrated.pagingPairs, [.semicolonQuote])
    }

    func testEmptyArrayMeansOnlyTheArrowsPage() throws {
        let json = #"{"pagingPairs":[]}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettingsSnapshot.self, from: json)
        XCTAssertTrue(settings.pagingPairs.isEmpty)
    }

    /// An unknown member is dropped; the known members in the same array survive. The old
    /// `minusPlus` spelling is now unknown, so a file written before the rename loses it
    /// rather than reviving the `+` key.
    func testUnknownMemberIsDroppedNotTheWholeSet() throws {
        let json = #"{"pagingPairs":["commaPeriod","minusPlus","semicolonQuote"]}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettingsSnapshot.self, from: json)
        XCTAssertEqual(settings.pagingPairs, [.commaPeriod, .semicolonQuote])
    }

    /// A field of the wrong type falls back for this field only, not for the whole file.
    func testWrongTypeFallsBackOnlyForThisField() throws {
        let json = #"{"holdDelay":0.4,"pagingPairs":"commaPeriod"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettingsSnapshot.self, from: json)
        XCTAssertEqual(settings.holdDelay, 0.4)
        XCTAssertEqual(settings.pagingPairs, [.semicolonQuote])
    }

    /// Encoding uses the declared order, so a set's hash order never reaches the file.
    func testEncodingIsDeterministic() throws {
        var settings = AppSettingsSnapshot()
        settings.pagingPairs = [.semicolonQuote, .commaPeriod]
        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["pagingPairs"] as? [String], ["commaPeriod", "semicolonQuote"])
    }

    func testAllFourPairsRoundTrip() throws {
        var settings = AppSettingsSnapshot()
        settings.pagingPairs = Set(PagingPair.allCases)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
        XCTAssertEqual(decoded.pagingPairs, Set(PagingPair.allCases))
    }
}
