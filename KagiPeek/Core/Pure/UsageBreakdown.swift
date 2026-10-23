import Foundation

/// One line of the per-app statistics list: a shortcut, the command it runs, and how often.
struct UsageEntry: Identifiable, Equatable, Sendable {
    let usageKey: String
    /// nil when the command was never scanned in this session and the disk cache has no
    /// record of it — the count is still true, the title is what is missing.
    let title: String?
    let chord: KeyChord?
    let presses: Int
    let lastUsed: Date

    var id: String { usageKey }

    var isShortcutless: Bool { chord == nil || chord?.isEmpty == true }
}

/// Turns raw usage records into the list the statistics tab shows.
///
/// The records deliberately store only a usage key (owner + chord, never the title), so the
/// titles come from whatever the scan knows. Keeping this in the pure layer means the join —
/// and the honesty about what is missing — can be tested without a window.
enum UsageBreakdown {
    /// - Parameters:
    ///   - bundleID: the owner bucket, as `UsageStatistics.bundleID(fromUsageKey:)` reports it.
    ///   - records: every usage record.
    ///   - known: bindings from any source; only their `usageKey` is used for the join.
    static func entries(
        for bundleID: String,
        records: [String: UsageRecord],
        known: [BindingItem]
    ) -> [UsageEntry] {
        var byKey: [String: BindingItem] = [:]
        for item in known {
            byKey[item.usageKey] = item
        }

        var entries: [UsageEntry] = []
        for (key, record) in records {
            guard UsageStatistics.bundleID(fromUsageKey: key) == bundleID else { continue }
            let item = byKey[key]
            let chordKey = key.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            entries.append(
                UsageEntry(
                    usageKey: key,
                    title: item?.title,
                    chord: item?.chord ?? KeyChord.from(cacheKey: chordKey),
                    presses: record.count,
                    lastUsed: record.lastUsed
                )
            )
        }
        // Most-pressed first: the list answers "what do I actually use", not "what exists".
        return entries.sorted { lhs, rhs in
            if lhs.presses != rhs.presses { return lhs.presses > rhs.presses }
            if lhs.title != rhs.title {
                return (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending
            }
            return lhs.usageKey < rhs.usageKey
        }
    }
}
