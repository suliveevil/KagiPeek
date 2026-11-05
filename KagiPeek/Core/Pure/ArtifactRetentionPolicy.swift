import Foundation

/// One file a retention policy may consider, as the policy sees it.
///
/// A *candidate*, not a survivor: most of these come back from `artifactsToDelete`. The name
/// says what the value is, not what becomes of it.
nonisolated struct RetentionCandidate: Equatable, Sendable {
    /// File name including its extension.
    var name: String
    /// Last modification time, which is also the write time for both folders this serves.
    var modifiedAt: Date
    /// A `.partial` crash fragment is a session's live evidence until the next launch turns
    /// it into a report. It is never a deletion candidate, whatever its age.
    var isPartial: Bool = false
}

/// Decides which crash reports and menu-cache entries are too old or too many.
///
/// Two independent windows, applied together:
/// 1. age — an entry older than `maximumAge` goes;
/// 2. count — after the age rule, only the `keepMostRecent` newest entries stay.
///
/// Two entries are never deleted by either rule: a partial fragment (still evidence for the
/// next launch) and the single newest non-partial entry. The newest exception matters because
/// a user who crashes once a year, or an app that is scanned once and then not for months,
/// should not lose the *only* record because the calendar moved. Count-based retention is
/// what bounds growth; age-based retention is what eventually removes a folder full of old
/// entries that never reached the count limit.
///
/// Pure by construction: it takes dates and returns names. The services that call it own the
/// file system; this type never touches a folder, which is what lets the boundaries below be
/// tested without creating files.
nonisolated struct ArtifactRetentionPolicy: Equatable, Sendable {
    /// How many non-partial entries survive the count rule.
    ///
    /// 0 and negative are treated as 1: "keep the newest" is an invariant, not a suggestion.
    var keepMostRecent: Int
    /// Entries older than this go, except the newest. `nil` disables the age rule.
    var maximumAge: TimeInterval?

    static let crashReports = ArtifactRetentionPolicy(
        // 20 reports. A crash that repeats tends to repeat within a handful of launches, and
        // 20 is enough to see that pattern across days and across an update. A report carries
        // the recent actions and a 200-line log tail, so 20 is a few megabytes in the worst
        // case — bounded, but not so small that the second occurrence of a rare crash is
        // already gone. No age rule: the only report of a bug that happened last year is
        // still the only report of that bug.
        keepMostRecent: 20,
        maximumAge: nil
    )

    static let menuCache = ArtifactRetentionPolicy(
        // 200 apps. A power user has 150–300 applications, so this keeps essentially every
        // app they have opened; an entry is usually tens of kilobytes of menu rows, making
        // the ceiling tens of megabytes rather than unbounded. The count is the disk bound.
        keepMostRecent: 200,
        // 90 days. The cache is derived data, but a stale entry also supplies the titles in
        // usage statistics for an app that is not front, so deleting too eagerly costs more
        // than a rescan. A quarter is long enough that the entry is either for an app the
        // user still opens (and so gets refreshed) or for one they have genuinely stopped
        // using; the count rule above handles the rest.
        maximumAge: 90 * 24 * 60 * 60
    )

    /// Names the caller should delete. Never includes a partial fragment or the newest
    /// non-partial entry.
    func artifactsToDelete(entries: [RetentionCandidate], now: Date = Date()) -> [RetentionCandidate] {
        let keep = max(1, keepMostRecent)
        let deletable = entries.filter { !$0.isPartial }
        guard !deletable.isEmpty else { return [] }

        // Newest first, name as the tie-break so two entries written in the same second do
        // not make the outcome depend on directory enumeration order.
        let newestFirst = deletable.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.name > rhs.name
        }

        var doomed: [RetentionCandidate] = []
        for (index, entry) in newestFirst.enumerated() {
            // The newest entry is never deleted, even when it is older than `maximumAge`.
            if index == 0 { continue }
            let tooOld: Bool
            if let maximumAge {
                tooOld = now.timeIntervalSince(entry.modifiedAt) > maximumAge
            } else {
                tooOld = false
            }
            if tooOld || index >= keep {
                doomed.append(entry)
            }
        }
        return doomed
    }
}
