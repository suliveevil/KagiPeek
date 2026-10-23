import Foundation

/// keyfreq-style statistics, kept free of any storage so it can be unit tested.
///
/// Only binding identifiers, counts and timestamps are stored — never raw key events.
struct UsageStatistics: Codable, Equatable, Sendable {
    static let maxRecords = 800

    var totalPresses: Int = 0
    var records: [String: UsageRecord] = [:]

    mutating func record(usageKey: String, at date: Date = Date()) {
        var record = records[usageKey] ?? UsageRecord(count: 0, lastUsed: date)
        record.count += 1
        record.lastUsed = date
        records[usageKey] = record
        totalPresses += 1
        prune()
    }

    mutating func reset() {
        records = [:]
        totalPresses = 0
    }

    /// Drops the least recently used entries once the cap is exceeded.
    mutating func prune() {
        guard records.count > Self.maxRecords else { return }
        let kept = records
            .sorted { lhs, rhs in lhs.value.lastUsed > rhs.value.lastUsed }
            .prefix(Self.maxRecords)
        records = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    func record(for usageKey: String) -> UsageRecord? {
        records[usageKey]
    }

    // MARK: - Per-app aggregation

    static func bundleID(fromUsageKey key: String) -> String {
        key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? "*"
    }

    /// Usage grouped by the app that owns each binding ("*" = system / built-in rows).
    func summariesByApp() -> [AppUsageSummary] {
        var buckets: [String: (presses: Int, shortcuts: Set<String>, lastUsed: Date)] = [:]
        for (key, record) in records {
            let bundleID = Self.bundleID(fromUsageKey: key)
            var bucket = buckets[bundleID] ?? (0, [], .distantPast)
            bucket.presses += record.count
            bucket.shortcuts.insert(key)
            bucket.lastUsed = max(bucket.lastUsed, record.lastUsed)
            buckets[bundleID] = bucket
        }
        return buckets
            .map { bundleID, bucket in
                AppUsageSummary(
                    bundleID: bundleID,
                    presses: bucket.presses,
                    shortcutCount: bucket.shortcuts.count,
                    lastUsed: bucket.lastUsed
                )
            }
            .sorted { lhs, rhs in
                if lhs.presses != rhs.presses { return lhs.presses > rhs.presses }
                return lhs.bundleID < rhs.bundleID
            }
    }
}

struct AppUsageSummary: Identifiable, Equatable, Sendable {
    let bundleID: String
    let presses: Int
    let shortcutCount: Int
    let lastUsed: Date

    var id: String { bundleID }
    var isGlobal: Bool { bundleID == "*" }
}
