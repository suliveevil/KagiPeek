import Foundation

/// On-disk envelope for `settings.json`.
struct SettingsPayload: Codable {
    var schemaVersion: Int
    var settings: AppSettingsSnapshot
}

/// Reads the stored schema version and upgrades the payload to the current one.
///
/// Every field decodes with `decodeIfPresent`, so an older payload has never lost anything,
/// and every schema change so far has been either additive or a plain deletion (`v2.1`
/// removed `allowPanelExecute`, `v2.2` removed `allowSearchExecute`) — an unknown key is
/// simply ignored and disappears on the next save. There is therefore no rewrite step yet.
/// The version is still *read*, not only written: that is what tells a future change where
/// to add its step, and it lets the app report that it upgraded a file from an older build.
enum SettingsMigrator {
    static let currentVersion = AppSettingsSnapshot.currentSchemaVersion

    /// True when the file was written by an older build.
    static func isOutdated(_ payload: SettingsPayload) -> Bool {
        payload.schemaVersion < currentVersion
    }

    /// Upgrade hook. Steps for a future incompatible change go here, in order, keyed by the
    /// version they bring the payload up to.
    static func migrate(_ payload: SettingsPayload) -> AppSettingsSnapshot {
        // Nothing to rewrite for versions 1...current: the fields that changed were removed,
        // and a removed key needs no value.
        payload.settings.normalized()
    }
}
