import Combine
import Foundation
import os

/// keyfreq-style statistics persisted in `Application Support/KagiPeek/usage.json`.
///
/// Records are keyed by `bundleID|chord`, so statistics are per app and survive
/// reinstalls that do not wipe Application Support. Only identifiers and timestamps are
/// stored — never raw key events.
///
/// Recording a press touches the in-memory state only; the file is rewritten once, on a
/// utility queue, after a short pause. Rows can be run several times a second, and a
/// synchronous whole-file write on the main thread was visible as a hitch.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var statistics: UsageStatistics
    /// Pinned shortcuts, keyed like the statistics.
    @Published private(set) var favorites: Set<String> = []

    /// `usage.json` has its own version: coupling it to the settings schema meant that a
    /// settings migration would silently claim the statistics file had changed too.
    static let currentSchemaVersion = 1

    private struct Payload: Codable {
        var schemaVersion: Int
        var statistics: UsageStatistics
        var favorites: Set<String>?
    }

    private let defaults: UserDefaults
    private let fileStore = JsonFileStore(fileName: "usage.json")
    private let writeQueue = DispatchQueue(label: "com.voltline.kagipeek.usage-write", qos: .utility)
    private var pendingWrite: DispatchWorkItem?
    private static let storageKey = "usage.v2"
    private static let writeDelay: TimeInterval = 1.2

    var records: [String: UsageRecord] { statistics.records }
    var totalPresses: Int { statistics.totalPresses }
    var trackedCount: Int { statistics.records.count }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let payload = fileStore.load(Payload.self) {
            statistics = payload.statistics
            favorites = payload.favorites ?? []
        } else if let data = defaults.data(forKey: Self.storageKey),
                  let decoded = try? JSONDecoder().decode(UsageStatistics.self, from: data) {
            AppLog.storage.notice("importing statistics from the 2.0 UserDefaults blob")
            statistics = decoded
        } else {
            statistics = UsageStatistics()
        }
        // Create the file eagerly so the About tab's data folder is never empty.
        flush()
    }

    func record(usageKey: String, at date: Date = Date()) {
        statistics.record(usageKey: usageKey, at: date)
        schedulePersist()
    }

    func isFavorite(_ usageKey: String) -> Bool {
        favorites.contains(usageKey)
    }

    func toggleFavorite(_ usageKey: String) {
        if favorites.contains(usageKey) {
            favorites.remove(usageKey)
        } else {
            favorites.insert(usageKey)
        }
        schedulePersist()
    }

    func reset() {
        statistics.reset()
        favorites = []
        schedulePersist()
    }

    func summariesByApp() -> [AppUsageSummary] {
        statistics.summariesByApp()
    }

    var dataFolderURL: URL {
        DataDirectory.url
    }

    /// Writes any pending change now. Called on termination.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        let payload = makePayload()
        let store = fileStore
        writeQueue.sync { store.save(payload) }
    }

    private func schedulePersist() {
        pendingWrite?.cancel()
        let payload = makePayload()
        let store = fileStore
        let item = DispatchWorkItem { store.save(payload) }
        pendingWrite = item
        writeQueue.asyncAfter(deadline: .now() + Self.writeDelay, execute: item)
    }

    private func makePayload() -> Payload {
        Payload(
            schemaVersion: Self.currentSchemaVersion,
            statistics: statistics,
            favorites: favorites
        )
    }
}
