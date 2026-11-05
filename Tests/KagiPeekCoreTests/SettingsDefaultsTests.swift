import XCTest
@testable import KagiPeekCore

final class SettingsDefaultsTests: XCTestCase {
    func testSmartIsDefault() {
        let settings = AppSettingsSnapshot()
        XCTAssertEqual(settings.sortMode, .smart)
        XCTAssertEqual(settings.runRowKey, .runRowDefault)
        XCTAssertEqual(settings.copyRowKey, .copyRowDefault)
        XCTAssertTrue(settings.modifierTriggerEnabled)
        XCTAssertTrue(settings.hotkeyTriggerEnabled)
        XCTAssertEqual(settings.triggerGesture, .hold)
        XCTAssertEqual(settings.triggerKey, .rightCommand)
    }

    func testDecodingOlderPayloadKeepsDefaults() throws {
        let json = "{\"triggerMode\":\"holdModifiers\",\"holdDelay\":0.4}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: json)
        XCTAssertEqual(decoded.triggerMode, .holdModifiers)
        XCTAssertEqual(decoded.holdDelay, 0.4)
        XCTAssertEqual(decoded.sortMode, .smart)
        XCTAssertEqual(decoded.runRowKey, .runRowDefault)
    }

    /// An accumulated binary tail (`0.9000000000000001`) must not survive normalization:
    /// settings.json is written from the normalized snapshot.
    func testHoldDelayIsRoundedToItsStepBeforePersisting() throws {
        var settings = AppSettingsSnapshot()
        settings.holdDelay = 0.9000000000000001
        let normalized = settings.normalized()
        XCTAssertEqual(normalized.holdDelay, 0.9)

        let json = String(data: try JSONEncoder().encode(normalized), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"holdDelay\":0.9"), json)

        settings.holdDelay = 0.7
        XCTAssertEqual(settings.normalized().holdDelay, 0.7)
    }

    /// v2.1 wrote `allowPanelExecute`; the field is gone, so the stored payload must still
    /// decode and the row keys must fall back to their defaults.
    func testLegacyPayloadWithAllowPanelExecuteStillDecodes() throws {
        let json = """
        {"triggerMode":"hotkey","allowPanelExecute":true,"allowSearchExecute":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: json)
        XCTAssertEqual(decoded.triggerMode, .hotkey)
        XCTAssertEqual(decoded.runRowKey, .runRowDefault)
        XCTAssertEqual(decoded.copyRowKey, .copyRowDefault)
    }

    /// A v3 file whose row keys were never touched still carries the old default pair (↩ /
    /// ⌘↩); the migration moves it to Space / Return.
    func testUntouchedLegacyRowKeyPairMigratesToSpaceAndReturn() {
        var legacy = AppSettingsSnapshot()
        legacy.runRowKey = .legacyRunRowDefault
        legacy.copyRowKey = .legacyCopyRowDefault
        let migrated = SettingsMigrator.migrate(
            SettingsPayload(schemaVersion: 3, settings: legacy)
        )
        XCTAssertEqual(migrated.runRowKey, .runRowDefault)
        XCTAssertEqual(migrated.copyRowKey, .copyRowDefault)
    }

    /// A pair the user recorded is kept as it is: the migration only recognises the exact
    /// untouched pair.
    func testCustomRowKeyPairSurvivesMigration() {
        var custom = AppSettingsSnapshot()
        custom.runRowKey = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [])
        custom.copyRowKey = HotkeySpec(keyCode: KeyCode.delete, modifiers: [.command])
        let migrated = SettingsMigrator.migrate(
            SettingsPayload(schemaVersion: 3, settings: custom)
        )
        XCTAssertEqual(migrated.runRowKey, custom.runRowKey)
        XCTAssertEqual(migrated.copyRowKey, custom.copyRowKey)
    }

    /// One end changed on its own is a decision too, so the untouched half must not move.
    func testHalfCustomisedPairSurvivesMigration() {
        var half = AppSettingsSnapshot()
        half.runRowKey = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.shift])
        half.copyRowKey = .legacyCopyRowDefault
        let migrated = SettingsMigrator.migrate(
            SettingsPayload(schemaVersion: 3, settings: half)
        )
        XCTAssertEqual(migrated.runRowKey, half.runRowKey)
        XCTAssertEqual(migrated.copyRowKey, half.copyRowKey)
    }

    /// A file already written by this build (v5) is not migrated again: its row keys and
    /// trigger fields are whatever it says.
    func testCurrentVersionPayloadIsNotMigrated() {
        var current = AppSettingsSnapshot()
        current.runRowKey = .legacyRunRowDefault
        current.copyRowKey = .legacyCopyRowDefault
        current.modifierTriggerEnabled = false
        current.hotkeyTriggerEnabled = false
        current.triggerGesture = .doubleTap
        current.triggerKey = .leftCommand
        let migrated = SettingsMigrator.migrate(
            SettingsPayload(schemaVersion: 5, settings: current)
        )
        XCTAssertEqual(migrated.runRowKey, .legacyRunRowDefault)
        XCTAssertEqual(migrated.copyRowKey, .legacyCopyRowDefault)
        XCTAssertFalse(migrated.modifierTriggerEnabled)
        XCTAssertEqual(migrated.triggerGesture, .doubleTap)
        XCTAssertEqual(migrated.triggerKey, .leftCommand)
    }

    // MARK: - v5 trigger migration

    private func migrate(_ mode: TriggerMode?) -> AppSettingsSnapshot {
        var legacy = AppSettingsSnapshot()
        legacy.triggerMode = mode
        return SettingsMigrator.migrate(SettingsPayload(schemaVersion: 4, settings: legacy))
    }

    /// Holding any modifier kept working; the migration must keep that meaning instead of
    /// narrowing it to a single key.
    func testLegacyHoldModifiersMigratesToAnyModifier() {
        let migrated = migrate(.holdModifiers)
        XCTAssertTrue(migrated.modifierTriggerEnabled)
        XCTAssertTrue(migrated.hotkeyTriggerEnabled)
        XCTAssertEqual(migrated.triggerGesture, .hold)
        XCTAssertEqual(migrated.triggerKey, .anyModifier)
        XCTAssertNil(migrated.triggerMode)
    }

    /// The old double-tap only listened to ⌘. `anyModifier` keeps the gesture working on the
    /// keys people actually use, rather than silently requiring one side.
    func testLegacyDoubleTapMigratesToAnyModifier() {
        let migrated = migrate(.doubleTapCommand)
        XCTAssertTrue(migrated.modifierTriggerEnabled)
        XCTAssertTrue(migrated.hotkeyTriggerEnabled)
        XCTAssertEqual(migrated.triggerGesture, .doubleTap)
        XCTAssertEqual(migrated.triggerKey, .anyModifier)
    }

    /// `hotkey` meant "gesture off, hotkeys instead", so the hotkeys stay live; `disabled`
    /// meant everything was off.
    func testLegacyHotkeyAndDisabledMigrateTheirTwoSwitches() {
        let hotkeyOnly = migrate(.hotkey)
        XCTAssertFalse(hotkeyOnly.modifierTriggerEnabled)
        XCTAssertTrue(hotkeyOnly.hotkeyTriggerEnabled)
        XCTAssertEqual(hotkeyOnly.triggerGesture, .hold)
        XCTAssertEqual(hotkeyOnly.triggerKey, .rightCommand)

        let disabled = migrate(.disabled)
        XCTAssertFalse(disabled.modifierTriggerEnabled)
        XCTAssertFalse(disabled.hotkeyTriggerEnabled)
        XCTAssertEqual(disabled.triggerGesture, .hold)
        XCTAssertEqual(disabled.triggerKey, .rightCommand)
    }

    /// A payload with no legacy mode must not turn anything off: the v5 defaults win.
    func testMissingTriggerModeKeepsV5Defaults() {
        let migrated = migrate(nil)
        XCTAssertTrue(migrated.modifierTriggerEnabled)
        XCTAssertTrue(migrated.hotkeyTriggerEnabled)
        XCTAssertEqual(migrated.triggerGesture, .hold)
        XCTAssertEqual(migrated.triggerKey, .rightCommand)
    }

    /// The legacy key must disappear from the file on the next save, not linger beside the
    /// new fields.
    func testReencodedSettingsOmitTriggerMode() throws {
        var settings = AppSettingsSnapshot()
        settings.triggerMode = .holdModifiers
        let data = try JSONEncoder().encode(settings)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("triggerMode"))
        XCTAssertTrue(json.contains("modifierTriggerEnabled"))
        XCTAssertTrue(json.contains("hotkeyTriggerEnabled"))
        XCTAssertTrue(json.contains("triggerKey"))
    }

    // MARK: - v9 config-tool display switch

    func testConfigToolsAreHiddenByDefaultAndScanningStaysOn() {
        let settings = AppSettingsSnapshot()
        XCTAssertTrue(settings.scanConfigFiles)
        XCTAssertFalse(settings.showConfigToolsInPanel)
    }

    /// The tool cards were drawn unconditionally before v9. That was never a choice the
    /// user made, so an old file adopts the new default instead of keeping them on — and
    /// the scan switch is left exactly as the file had it.
    func testLegacyPayloadMigratesToHiddenConfigTools() throws {
        let json = #"{"scanConfigFiles":true,"showConfigToolsInPanel":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: json)
        let migrated = SettingsMigrator.migrate(
            SettingsPayload(schemaVersion: 8, settings: decoded)
        )
        XCTAssertTrue(migrated.scanConfigFiles)
        XCTAssertFalse(migrated.showConfigToolsInPanel)
    }

    /// A v9 file states the switch itself; the migration must not second-guess it.
    func testCurrentPayloadKeepsShownConfigTools() {
        var settings = AppSettingsSnapshot()
        settings.showConfigToolsInPanel = true
        let migrated = SettingsMigrator.migrate(
            SettingsPayload(schemaVersion: 9, settings: settings)
        )
        XCTAssertTrue(migrated.showConfigToolsInPanel)
    }

    func testConfigToolSwitchRoundTrips() throws {
        var settings = AppSettingsSnapshot()
        settings.showConfigToolsInPanel = true
        let decoded = try JSONDecoder().decode(
            AppSettingsSnapshot.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertTrue(decoded.showConfigToolsInPanel)
    }
}
