import Combine
import Foundation
import os

/// keyfreq-style statistics persisted in `Application Support/Kaname/usage.json`.
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

    // nonisolated + Sendable: the payload is built on the main actor, then handed to a
    // nonisolated work item that runs on the background write queue.
    private nonisolated struct Payload: Codable, Sendable {
        var schemaVersion: Int
        var statistics: UsageStatistics
        var favorites: Set<String>?
    }

    private let defaults: UserDefaults
    private let fileStore = JsonFileStore(fileName: "usage.json")
    private let writeQueue = DispatchQueue(label: "com.suliveevil.kaname.usage-write", qos: .utility)
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
            Diag.info(.settings, "importing statistics from the 2.0 UserDefaults blob")
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

    /// Clears press counts only. Favourites are user-authored pins, not statistics, and a
    /// button labelled "Reset statistics" must not silently unpin them.
    func reset() {
        statistics.reset()
        schedulePersist()
    }

    var dataFolderURL: URL {
        DataDirectory.url
    }

    /// Writes any pending change now. Called on termination.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        let item = Self.makeWriteItem(store: fileStore, payload: makePayload())
        writeQueue.sync(execute: item)
    }

    private func schedulePersist() {
        pendingWrite?.cancel()
        let item = Self.makeWriteItem(store: fileStore, payload: makePayload())
        pendingWrite = item
        writeQueue.asyncAfter(deadline: .now() + Self.writeDelay, execute: item)
    }

    /// Builds the disk-write item off the main actor. A DispatchWorkItem formed inside this
    /// MainActor-isolated type would itself be MainActor-isolated and trap when the background
    /// write queue runs it (the runtime executor check). Forming it in a nonisolated context
    /// keeps the block safe to run on `writeQueue`; every capture is Sendable.
    private nonisolated static func makeWriteItem(
        store: JsonFileStore,
        payload: Payload
    ) -> DispatchWorkItem {
        DispatchWorkItem { store.save(payload) }
    }

    private func makePayload() -> Payload {
        Payload(
            schemaVersion: Self.currentSchemaVersion,
            statistics: statistics,
            favorites: favorites
        )
    }
}
