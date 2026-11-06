import Foundation

nonisolated struct UsageRecord: Codable, Hashable, Sendable {
    var count: Int
    var lastUsed: Date
}

/// keyfreq-style statistics, kept free of any storage so it can be unit tested.
///
/// Only binding identifiers, counts and timestamps are stored — never raw key events.
nonisolated struct UsageStatistics: Codable, Equatable, Sendable {
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

    static func bundleID(fromUsageKey key: String) -> String {
        key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? "*"
    }
}
