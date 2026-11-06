import Foundation
import XCTest
@testable import KagiPeekCore

final class LegacyDataMigrationTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyDataMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temp { try? FileManager.default.removeItem(at: temp) }
    }

    private var legacy: URL { temp.appendingPathComponent("KagiPeek", isDirectory: true) }
    private var destination: URL { temp.appendingPathComponent("Kaname", isDirectory: true) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.data(using: .utf8)!.write(to: url)
    }

    private func makeLegacyTree() throws {
        try write(#"{"schema":9}"#, to: legacy.appendingPathComponent("settings.json"))
        try write(#"{"schema":9}"#, to: legacy.appendingPathComponent("usage.json"))
        try write("{}", to: legacy.appendingPathComponent("conflicts-cache.json"))
        try write("cache", to: legacy.appendingPathComponent("menu-cache/app.json"))
        try write("old log", to: legacy.appendingPathComponent("logs/kagipeek-2026-11-05.log"))
        try write("actions", to: legacy.appendingPathComponent("logs/last-actions.json"))
        try write("sentinel", to: legacy.appendingPathComponent("logs/session.active"))
        try write("{}", to: legacy.appendingPathComponent("crash/kagipeek-crash-1-SIGTRAP.json"))
        try write("partial", to: legacy.appendingPathComponent("crash/kagipeek-crash-1-signal.partial"))
        try write("secret", to: legacy.appendingPathComponent("signing/keychain-pass"))
        try write("p12", to: legacy.appendingPathComponent("signing/KagiPeek-Local.p12"))
        try write("backup", to: legacy.appendingPathComponent("backups/KagiPeek-2026-11-01-abc-local.app/Contents/Info.plist"))
    }

    func testCopiesCriticalFilesAndTransformsNames() throws {
        try makeLegacyTree()
        let outcome = LegacyDataMigration.migrateCritical(legacy: legacy, destination: destination)

        XCTAssertTrue(outcome.criticalComplete)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertTrue(outcome.backupsPending)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("settings.json")),
            #"{"schema":9}"#
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("menu-cache/app.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("logs/kaname-2026-11-05.log").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("logs/kagipeek-2026-11-05.log").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("logs/last-actions.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("logs/session.active").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("crash/kagipeek-crash-1-SIGTRAP.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("crash/kagipeek-crash-1-signal.partial").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("signing/keychain-pass").path
        ))

        let state = LegacyDataMigration.readState(destination: destination)
        XCTAssertEqual(state, .init(criticalComplete: true, backupsComplete: false))
    }

    func testSecondRunDoesNotOverwriteNewDataOrResurrectDeletedFiles() throws {
        try makeLegacyTree()
        _ = LegacyDataMigration.migrateCritical(legacy: legacy, destination: destination)

        try write(#"{"schema":9,"changed":true}"#,
                 to: destination.appendingPathComponent("settings.json"))
        try FileManager.default.removeItem(at: destination.appendingPathComponent("usage.json"))
        try write(#"{"schema":9,"old":true}"#, to: legacy.appendingPathComponent("settings.json"))

        let outcome = LegacyDataMigration.migrateCritical(legacy: legacy, destination: destination)
        XCTAssertTrue(outcome.criticalComplete)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("settings.json")),
            #"{"schema":9,"changed":true}"#
        )
        // The marker suppresses a re-import of a file the user deleted on purpose.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("usage.json").path
        ))
    }

    func testPartialDestinationIsFilledWithoutTouchingExistingEntries() throws {
        try makeLegacyTree()
        try write(#"{"schema":9,"mine":true}"#, to: destination.appendingPathComponent("settings.json"))

        let outcome = LegacyDataMigration.migrateCritical(legacy: legacy, destination: destination)
        XCTAssertTrue(outcome.criticalComplete)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("settings.json")),
            #"{"schema":9,"mine":true}"#
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("usage.json").path
        ))
    }

    func testEmptySigningSecretFailsCriticalPass() throws {
        try makeLegacyTree()
        try Data().write(to: legacy.appendingPathComponent("signing/keychain-pass"))

        let outcome = LegacyDataMigration.migrateCritical(legacy: legacy, destination: destination)
        XCTAssertFalse(outcome.criticalComplete)
        XCTAssertTrue(outcome.failures.contains("signing/keychain-pass"))
    }

    func testBackupsAreCopiedOnlyWhenAskedAndKeepExistingFiles() throws {
        try makeLegacyTree()
        _ = LegacyDataMigration.migrateCritical(legacy: legacy, destination: destination)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("backups").path
        ))

        XCTAssertTrue(LegacyDataMigration.copyBackups(legacy: legacy, destination: destination))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination
                .appendingPathComponent("backups/KagiPeek-2026-11-01-abc-local.app/Contents/Info.plist")
                .path
        ))

        try write("new", to: destination.appendingPathComponent("backups/new.app/Info.plist"))
        XCTAssertTrue(LegacyDataMigration.copyBackups(legacy: legacy, destination: destination))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("backups/new.app/Info.plist")),
            "new"
        )

        LegacyDataMigration.markBackupsComplete(destination: destination)
        let outcome = LegacyDataMigration.migrateCritical(legacy: legacy, destination: destination)
        XCTAssertFalse(outcome.backupsPending)
        XCTAssertEqual(
            LegacyDataMigration.readState(destination: destination)?.backupsComplete,
            true
        )
    }

    func testMissingLegacyFolderIsANoOp() throws {
        let outcome = LegacyDataMigration.migrateCritical(legacy: legacy, destination: destination)
        XCTAssertTrue(outcome.criticalComplete)
        XCTAssertFalse(outcome.backupsPending)
        XCTAssertEqual(outcome.failures, [])
    }
}
