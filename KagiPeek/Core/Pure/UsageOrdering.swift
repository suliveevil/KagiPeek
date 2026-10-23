import Foundation

/// Ordering for the lists on the Statistics tab.
///
/// The sort mode was born as a *panel* setting, and the Statistics tab showed the picker
/// without honouring it: both lists were hard-coded to "most pressed first", so changing the
/// picker there did nothing at all. Rather than move the picker away, each mode is now
/// translated into what it means for a list of statistics:
///
/// * `smart` — recent and frequent first (the same decay the panel uses);
/// * `keyOrder` — the panel's chord order: modifiers as printed, then the key;
/// * `alphabetical` — by command name;
/// * `frequencyDesc` — most pressed first.
enum UsageOrdering {
    static func entries(_ entries: [UsageEntry], mode: RankMode, now: Date = Date()) -> [UsageEntry] {
        switch mode {
        case .alphabetical:
            return entries.sorted { lhs, rhs in
                let order = (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "")
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.usageKey < rhs.usageKey
            }
        case .keyOrder:
            return entries.sorted { lhs, rhs in
                // The panel's own comparator, not a string order over the cache key: the
                // statistics page and the panel are two views of the same list, and "along
                // the keyboard" has to mean one thing. It also puts a function key beside
                // the letter it is named after, and a shortcut-less command last — an
                // empty key is not "before A".
                let left = lhs.chord ?? .empty
                let right = rhs.chord ?? .empty
                if PanelOrdering.compare(left, right) { return true }
                if PanelOrdering.compare(right, left) { return false }
                return (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending
            }
        case .smart:
            return entries.sorted { lhs, rhs in
                let left = Ranker.decayedUsefulness(
                    UsageRecord(count: lhs.presses, lastUsed: lhs.lastUsed),
                    now: now
                )
                let right = Ranker.decayedUsefulness(
                    UsageRecord(count: rhs.presses, lastUsed: rhs.lastUsed),
                    now: now
                )
                if left != right { return left > right }
                return lhs.presses > rhs.presses
            }
        case .frequencyDesc:
            return entries.sorted { lhs, rhs in
                if lhs.presses != rhs.presses { return lhs.presses > rhs.presses }
                return (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending
            }
        }
    }

    /// The same modes for the app groups. Apps have no chord and no command name, so
    /// `keyOrder` falls back to the app name — the reader still gets a stable, predictable
    /// order instead of an arbitrary one.
    static func apps(
        _ apps: [AppUsageSummary],
        mode: RankMode,
        name: (String) -> String
    ) -> [AppUsageSummary] {
        switch mode {
        case .alphabetical, .keyOrder:
            return apps.sorted { lhs, rhs in
                let order = name(lhs.bundleID).localizedCaseInsensitiveCompare(name(rhs.bundleID))
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.bundleID < rhs.bundleID
            }
        case .smart, .frequencyDesc:
            return apps.sorted { lhs, rhs in
                if lhs.presses != rhs.presses { return lhs.presses > rhs.presses }
                return name(lhs.bundleID).localizedCaseInsensitiveCompare(name(rhs.bundleID)) == .orderedAscending
            }
        }
    }
}
