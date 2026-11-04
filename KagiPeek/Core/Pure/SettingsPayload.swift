import Foundation

/// On-disk envelope for `settings.json`.
nonisolated struct SettingsPayload: Codable {
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
nonisolated enum SettingsMigrator {
    static let currentVersion = AppSettingsSnapshot.currentSchemaVersion

    /// True when the file was written by an older build.
    static func isOutdated(_ payload: SettingsPayload) -> Bool {
        payload.schemaVersion < currentVersion
    }

    /// A file from a newer build may contain fields this build cannot decode. It is shown
    /// from the decoded subset, but every automatic write is refused so the original file
    /// survives a downgrade.
    static func canAutomaticallyRewrite(schemaVersion: Int) -> Bool {
        schemaVersion <= currentVersion
    }

    static func isFuture(_ payload: SettingsPayload) -> Bool {
        !canAutomaticallyRewrite(schemaVersion: payload.schemaVersion)
    }

    /// Upgrade hook. Steps for a future incompatible change go here, in order, keyed by the
    /// version they bring the payload up to.
    static func migrate(_ payload: SettingsPayload) -> AppSettingsSnapshot {
        var settings = payload.settings
        // v3 stored the old default pair (↩ runs, ⌘↩ copies). Only that exact pair moves:
        // a pair the user recorded is a decision, and a default they never touched is not.
        // One half changed on its own is also left alone, so a custom pair never ends up
        // half-new and half-old.
        if payload.schemaVersion < 4,
           settings.runRowKey == .legacyRunRowDefault,
           settings.copyRowKey == .legacyCopyRowDefault {
            settings.runRowKey = .runRowDefault
            settings.copyRowKey = .copyRowDefault
        }
        // v5 split the old four-way `triggerMode` into two independent switches plus a
        // gesture and a key. The old hotkeys were always live, so only `disabled` turns
        // them off; `hotkey` meant the gesture alone was off.
        if payload.schemaVersion < 5, let legacy = settings.triggerMode {
            settings.hotkeyTriggerEnabled = legacy != .disabled
            switch legacy {
            case .holdModifiers:
                settings.modifierTriggerEnabled = true
                settings.triggerGesture = .hold
                settings.triggerKey = .anyModifier
            case .doubleTapCommand:
                settings.modifierTriggerEnabled = true
                settings.triggerGesture = .doubleTap
                settings.triggerKey = .anyModifier
            case .hotkey, .disabled:
                settings.modifierTriggerEnabled = false
                settings.triggerGesture = .hold
                settings.triggerKey = .rightCommand
            }
        }
        // v6 added `panelOrder`. A v5 file has no key, so `decodeIfPresent` already yields
        // `.byModifier`, the behaviour every earlier build had; there is nothing to rewrite.
        // The step is listed here so the next reader sees where the boundary sits.
        // The legacy key is never written back: `nil` encodes as absent.
        settings.triggerMode = nil
        return settings.normalized()
    }
}
