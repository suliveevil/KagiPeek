import XCTest
@testable import KagiPeekCore

/// The derived double-tap window, and the schema change that removed the stored one.
final class DoubleTapTimingTests: XCTestCase {
    /// A system value inside the range is used as-is.
    func testSystemValueInsideTheRangePassesThrough() {
        XCTAssertEqual(DoubleTapTiming.window(systemDoubleClickInterval: 0.4), 0.4)
    }

    /// A very fast system setting cannot make the gesture stricter than the floor.
    func testFastSystemValueClampsUp() {
        XCTAssertEqual(DoubleTapTiming.window(systemDoubleClickInterval: 0.1), 0.25)
    }

    /// A very slow system setting cannot leave the gesture open long enough to merge
    /// unrelated presses.
    func testSlowSystemValueClampsDown() {
        XCTAssertEqual(DoubleTapTiming.window(systemDoubleClickInterval: 1.2), 0.6)
    }

    /// A non-finite value is not a reason to open the gesture indefinitely.
    func testNonFiniteValueFallsBackToTheLowerBound() {
        XCTAssertEqual(DoubleTapTiming.window(systemDoubleClickInterval: .infinity), 0.25)
        XCTAssertEqual(DoubleTapTiming.window(systemDoubleClickInterval: .nan), 0.25)
    }

    /// A v6 file still decodes even though it carries the removed key; the next save drops
    /// it and writes schema 7.
    func testVersionSixPayloadWithTheOldWindowStillDecodesAndDropsTheKey() throws {
        let json = Data(#"{"schemaVersion":6,"settings":{"doubleTapWindow":0.6}}"#.utf8)
        let payload = try JSONDecoder().decode(SettingsPayload.self, from: json)
        XCTAssertEqual(payload.schemaVersion, 6)

        let migrated = SettingsMigrator.migrate(payload)
        let upgraded = SettingsPayload(
            schemaVersion: AppSettingsSnapshot.currentSchemaVersion,
            settings: migrated
        )
        let encoded = try JSONEncoder().encode(upgraded)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, 9)
        let settings = object?["settings"] as? [String: Any]
        XCTAssertNil(settings?["doubleTapWindow"])
    }
}
