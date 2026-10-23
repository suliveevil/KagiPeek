import AppKit
import Combine
import Foundation
import ServiceManagement
import os

/// Persists settings in `Application Support/KagiPeek/settings.json` and migrates both the
/// 1.x preference keys and the 2.0 JSON blob out of UserDefaults on first launch.
///
/// This store is the **single writer** of that file. Edits are coalesced with a short
/// debounce and the write reads the snapshot at fire time, so a burst of changes (dragging a
/// slider, typing in a text editor) produces one atomic write of the latest state instead of
/// a race in which an older copy could overwrite a newer one.
@MainActor
final class SettingsStore: ObservableObject {
    static let legacyBundleIdentifier = "com.Voltline.KagiPeek"

    @Published var settings: AppSettingsSnapshot {
        didSet {
            guard !isLoading, settings != oldValue else { return }
            schedulePersist()
        }
    }

    @Published private(set) var launchAtLoginMessage: String?

    private let defaults: UserDefaults
    private let fileStore = JsonFileStore(fileName: "settings.json")
    private var isLoading = false
    private var pendingWrite: DispatchWorkItem?
    /// Set while the screenshot harness runs. It overwrites layout settings so a screenshot
    /// does not depend on the machine that took it — and those overrides must never reach the
    /// user's file, which they quietly did: a preview run left the app in English.
    private var isPreviewSession = false
    private var previewBackup: AppSettingsSnapshot?

    private static let storageKey = "settings.v2"
    /// Long enough to swallow a burst, short enough that a crash loses at most one gesture.
    private static let writeDelay: TimeInterval = 0.35

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLoading = true

        if let payload = fileStore.load(SettingsPayload.self) {
            if SettingsMigrator.isOutdated(payload) {
                AppLog.storage.notice("""
                    settings.json is schema \(payload.schemaVersion), upgrading to \
                    \(SettingsMigrator.currentVersion)
                    """)
            }
            settings = SettingsMigrator.migrate(payload)
        } else if let data = defaults.data(forKey: Self.storageKey),
                  let decoded = try? JSONDecoder().decode(AppSettingsSnapshot.self, from: data) {
            AppLog.storage.notice("importing settings from the 2.0 UserDefaults blob")
            settings = decoded.normalized()
        } else {
            settings = Self.migrateLegacy(defaults: defaults).normalized()
        }

        isLoading = false
        // Create the file eagerly so "show data folder" is never empty and so a removed key
        // disappears from disk on the first launch after an upgrade.
        writeNow()
    }

    func resetToDefaults() {
        settings = AppSettingsSnapshot()
        launchAtLoginMessage = nil
    }

    // MARK: - Preview harness

    /// Takes a copy of the real settings and stops persisting. Called only by
    /// `ShortcutEngine.startPreview`.
    func beginPreviewSession() {
        guard !isPreviewSession else { return }
        previewBackup = settings
        isPreviewSession = true
    }

    /// Puts the real settings back and persists them. Safe to call when no preview ran.
    func endPreviewSession() {
        guard isPreviewSession else { return }
        isPreviewSession = false
        if let backup = previewBackup {
            settings = backup
            previewBackup = nil
        }
        flush()
    }

    /// Keeps the login item in sync with the persisted flag, e.g. after migrating
    /// "Launch at login" from a 1.x install.
    func syncLaunchAtLoginIfNeeded() {
        guard #available(macOS 13.0, *) else { return }
        let status = SMAppService.mainApp.status
        guard settings.launchAtLogin, status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            launchAtLoginMessage = error.localizedDescription
            AppLog.ui.error("login item registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLogin = enabled
        applyLaunchAtLogin(enabled)
    }

    /// Writes any pending change immediately. Called on termination, where a debounced write
    /// would never fire.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        writeNow()
    }

    private func schedulePersist() {
        // A preview session edits in memory only: the overrides exist to make a screenshot
        // reproducible, not to become the user's configuration.
        guard !isPreviewSession else { return }
        pendingWrite?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingWrite = nil
                self.writeNow()
            }
        }
        pendingWrite = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDelay, execute: item)
    }

    private func writeNow() {
        guard !isPreviewSession else { return }
        fileStore.save(SettingsPayload(
            schemaVersion: AppSettingsSnapshot.currentSchemaVersion,
            settings: settings
        ))
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            launchAtLoginMessage = "macOS 13+ required"
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginMessage = nil
        } catch {
            launchAtLoginMessage = error.localizedDescription
            AppLog.ui.error("login item change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Migration

    private static func migrateLegacy(defaults: UserDefaults) -> AppSettingsSnapshot {
        let legacy = UserDefaults(suiteName: legacyBundleIdentifier) ?? defaults
        var settings = AppSettingsSnapshot()

        let delay = legacy.double(forKey: "settings.overlayHoldDelaySeconds")
        if delay > 0 { settings.holdDelay = delay }

        if let style = legacy.string(forKey: "settings.keyDisplayStyle") {
            settings.keyStyle = style == "words" ? .words : .symbols
        }
        let columns = legacy.integer(forKey: "settings.overlayColumnCount")
        if columns > 0 { settings.columnCount = columns }
        let maxItems = legacy.integer(forKey: "settings.maxDisplayCount")
        if maxItems > 0 { settings.maxItemsPerPage = maxItems }
        settings.launchAtLogin = legacy.bool(forKey: "settings.launchAtLoginEnabled")
        return settings
    }
}
