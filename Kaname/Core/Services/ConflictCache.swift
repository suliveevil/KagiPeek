import Foundation

/// One finding, in the form it is written to disk.
///
/// `BindingConflict` is derived state (its category and verdict are computed from the items),
/// so only the items and the chord need storing; everything else comes back on load.
struct CachedConflict: Codable, Equatable, Sendable {
    let chordKey: String
    let items: [BindingItem]
}

struct ConflictCachePayload: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var scannedAt: Date
    var conflicts: [CachedConflict]
}

/// The cross-app conflict scan, kept between launches.
///
/// Scanning every running app's menu bar is the most expensive thing the Conflicts page can
/// do, and doing it on every visit made the page feel like it was hanging. It now happens
/// once, is written here, and afterwards only when the user asks for it.
enum ConflictCache {
    static let currentVersion = 1
    private static let store = JsonFileStore(fileName: "conflicts-cache.json")

    static func load() -> ConflictCachePayload? {
        guard let payload = store.load(ConflictCachePayload.self) else { return nil }
        guard payload.schemaVersion == currentVersion else { return nil }
        return payload
    }

    static func save(_ conflicts: [BindingConflict], at date: Date = Date()) {
        store.save(ConflictCachePayload(
            schemaVersion: currentVersion,
            scannedAt: date,
            conflicts: conflicts.map { CachedConflict(chordKey: $0.chordKey, items: $0.items) }
        ))
    }

    static var fileURL: URL { store.fileURL }
}
