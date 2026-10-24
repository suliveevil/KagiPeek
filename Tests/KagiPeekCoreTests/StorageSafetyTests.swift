import XCTest
@testable import KagiPeekCore

/// Persistence policy that can be decided without touching the real Application Support
/// store: a newer build's file must never be rewritten by an older build.
final class StorageSafetyTests: XCTestCase {
    func testCurrentSchemaCanBeAutomaticallyRewritten() {
        XCTAssertTrue(
            SettingsMigrator.canAutomaticallyRewrite(
                schemaVersion: SettingsMigrator.currentVersion
            )
        )
    }

    func testOlderSchemaCanBeAutomaticallyRewritten() {
        XCTAssertTrue(
            SettingsMigrator.canAutomaticallyRewrite(
                schemaVersion: SettingsMigrator.currentVersion - 1
            )
        )
    }

    func testFutureSchemaCannotBeAutomaticallyRewritten() {
        XCTAssertFalse(
            SettingsMigrator.canAutomaticallyRewrite(
                schemaVersion: SettingsMigrator.currentVersion + 1
            )
        )
    }
}
