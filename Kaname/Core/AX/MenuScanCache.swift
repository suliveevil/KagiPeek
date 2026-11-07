import AppKit
import Foundation
import os

/// Disk cache for menu scans, modelled on Menu-Bar-Search's: one JSON entry per app plus
/// a control file recording the settings every entry was written under.
///
/// The cache lives in `Application Support/Kaname/menu-cache`. Unlike settings and
/// statistics it is derived data — every entry can be reproduced by a scan — so an
/// unreadable file is dropped instead of preserved.
nonisolated struct MenuScanCache {
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

    /// The last scan written for this app, whatever the age cap says, when a hidden menu bar
    /// has to be stood in for.
    ///
    /// Unlike `cachedItems`, which serves the statistics, the rows this returns are meant to
    /// be run — and they still have to be written under the current settings, because rows
    /// shaped by other settings are the wrong rows rather than merely old ones. The age bound
    /// is `MenuCachePolicy.standInMaxAge`.
    static func loadStandIn(identity: String, fingerprint: String, now: Date = Date()) -> Entry? {
        guard MenuCachePolicy.isControlCurrent(
            read(Control.self, at: controlURL)?.settingsFingerprint,
            fingerprint: fingerprint
        ) else { return nil }
        guard let entry = read(Entry.self, at: entryURL(identity: identity)),
              MenuCachePolicy.mayStandIn(
                  scannedAt: entry.scannedAt,
                  entryFingerprint: entry.settingsFingerprint,
                  fingerprint: fingerprint,
                  now: now
              )
        else { return nil }
        return entry
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
            Diag.error(.settings, """
                could not create the menu cache folder: \(error.localizedDescription)
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
        prune(keeping: entryURL(identity: identity).lastPathComponent, now: now)
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

    // MARK: - Registry

    /// Drops the entries `ArtifactRetentionPolicy.menuCache` names.
    ///
    /// Runs after a save, so the entry just written is already in the folder when the count is
    /// taken: the ceiling is never exceeded by one, and the newest entry is the one the policy
    /// protects anyway. Two names are excluded regardless of what the policy says — the entry
    /// this call just produced (it may share a timestamp with a neighbour, and losing it would
    /// undo the save) and `control.json`, which is the index that makes every other entry
    /// readable. The whole folder is derived data, so a failed delete costs a stale file for
    /// one more scan; a debug line says so and the next save tries again.
    private static func prune(keeping current: String, now: Date) {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        } catch {
            Diag.debug(.settings, "could not list the menu cache for pruning: \(error.localizedDescription)")
            return
        }
        let candidates: [RetentionCandidate] = contents.compactMap { url in
            let name = url.lastPathComponent
            guard url.pathExtension == "json", name != controlURL.lastPathComponent, name != current else {
                return nil
            }
            // An entry whose date cannot be read is not evidence of anything, but there is no
            // reason to delete what cannot be dated either; the next save will see it again.
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return nil }
            return RetentionCandidate(name: name, modifiedAt: modified)
        }
        for artifact in ArtifactRetentionPolicy.menuCache.artifactsToDelete(entries: candidates, now: now) {
            do {
                try FileManager.default.removeItem(at: folderURL.appendingPathComponent(artifact.name))
            } catch {
                Diag.debug(.settings, """
                    could not delete the menu cache entry \(artifact.name): \
                    \(error.localizedDescription)
                    """)
            }
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
            Diag.error(.settings, """
                could not write \(url.lastPathComponent): \
                \(error.localizedDescription)
                """)
        }
    }
}
