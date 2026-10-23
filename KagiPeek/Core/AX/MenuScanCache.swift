import AppKit
import Foundation
import os

/// Disk cache for menu scans, modelled on Menu-Bar-Search's: one JSON entry per app plus
/// a control file recording the settings every entry was written under.
///
/// The cache lives in `Application Support/KagiPeek/menu-cache`. Unlike settings and
/// statistics it is derived data — every entry can be reproduced by a scan — so an
/// unreadable file is dropped instead of preserved.
struct MenuScanCache {
    struct Entry: Codable {
        var items: [BindingItem]
        var scannedAt: Date
        var settingsFingerprint: String
    }

    struct Control: Codable {
        var schemaVersion: Int
        var settingsFingerprint: String
        var updatedAt: Date
    }

    private static let folderName = "menu-cache"

    private static var folderURL: URL {
        DataDirectory.url.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Why a cache read did not answer. Carried out of `load` because "the panel was slow
    /// again" is only answerable if the miss has a name.
    enum CacheMiss: String, Error {
        /// No control file, or one that cannot be decoded.
        case control
        /// The control file was written under different settings (or an older schema).
        case fingerprint
        /// The entry's own settings differ from the current ones.
        case entryFingerprint
        /// The entry is older than `MenuCachePolicy.entryMaxAge` (or dated in the future).
        case expired
        /// The entry file itself is missing or undecodable.
        case decode
    }

    /// - Returns: the entry when the control file, the entry's own fingerprint and its age
    ///   all say it can still be trusted; the reason it could not otherwise.
    static func load(identity: String, fingerprint: String, now: Date = Date()) -> Result<Entry, CacheMiss> {
        guard let control = read(Control.self, at: controlURL) else { return .failure(.control) }
        guard MenuCachePolicy.isControlCurrent(control.settingsFingerprint, fingerprint: fingerprint) else {
            return .failure(.fingerprint)
        }
        guard let entry = read(Entry.self, at: entryURL(identity: identity)) else { return .failure(.decode) }
        guard entry.settingsFingerprint == fingerprint else { return .failure(.entryFingerprint) }
        guard MenuCachePolicy.isEntryUsable(
            scannedAt: entry.scannedAt,
            entryFingerprint: entry.settingsFingerprint,
            fingerprint: fingerprint,
            now: now
        ) else { return .failure(.expired) }
        return .success(entry)
    }

    /// Items of a cached scan, whatever its age.
    ///
    /// Only for display: the statistics need a title and a shortcut for apps that are not in
    /// front and may not have been scanned today. A stale row is never executed — presses
    /// always re-walk the menu path and verify the title — so reading it here is safe.
    static func cachedItems(identity: String) -> [BindingItem] {
        read(Entry.self, at: entryURL(identity: identity))?.items ?? []
    }

    static func save(identity: String, fingerprint: String, items: [BindingItem], now: Date = Date()) {
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            AppLog.storage.error("""
                could not create the menu cache folder: \(error.localizedDescription, privacy: .public)
                """)
            return
        }
        write(
            Entry(items: items, scannedAt: now, settingsFingerprint: fingerprint),
            at: entryURL(identity: identity)
        )
        write(
            Control(
                schemaVersion: MenuCachePolicy.schemaVersion,
                settingsFingerprint: fingerprint,
                updatedAt: now
            ),
            at: controlURL
        )
    }

    /// Drops every entry. Used when the whole cache must go — a reset to defaults writes
    /// settings the fingerprints alone cannot be trusted to catch.
    static func invalidateAll() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in contents where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Files

    private static var controlURL: URL {
        folderURL.appendingPathComponent("control.json")
    }

    private static func entryURL(identity: String) -> URL {
        folderURL.appendingPathComponent("menus-\(sanitized(identity)).json")
    }

    /// Bundle ids are already file-safe; a pid fallback ("pid:123") is not, and two
    /// identities must not collide onto one file.
    private static func sanitized(_ identity: String) -> String {
        String(identity.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character
                : "_"
        })
    }

    private static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, at url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            // A cache is an optimisation: a write that fails costs the next scan its
            // shortcut and nothing more. Say so and move on.
            AppLog.storage.error("""
                could not write \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }
}
