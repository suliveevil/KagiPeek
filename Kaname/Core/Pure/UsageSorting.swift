import Foundation

/// How the flat Statistics list is ordered.
///
/// The three fields answer the three questions the page is asked: "which key was that?",
/// "what does this app do?", "what did I press?". Frequency is deliberately not a field:
/// the list is a reference table, and a count column does not need to be the sort key.
nonisolated enum UsageSortField: String, Codable, CaseIterable, Hashable, Sendable {
    case shortcut
    case app
    case description

    var titleKey: L10nKey {
        switch self {
        case .shortcut: return .statsSortShortcut
        case .app: return .statsSortApp
        case .description: return .statsSortDescription
        }
    }

    /// An unknown value from a newer build falls back instead of failing the settings file.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = UsageSortField(rawValue: raw) ?? .shortcut
    }
}

/// The orderings the Statistics tab offers, over the flat list of one line per usage key.
///
/// A row is never merged across owners: two apps that both have ⌘C are two presses on two
/// different commands, and merging them would also break the favourite key, which is the
/// usage key itself.
nonisolated enum UsageSorting {
    static func entries(
        _ entries: [UsageEntry],
        by field: UsageSortField,
        appName: (String) -> String
    ) -> [UsageEntry] {
        entries.sorted { lhs, rhs in
            switch field {
            case .shortcut:
                if let order = shortcutOrder(lhs, rhs) { return order }
                return tieBreak(lhs, rhs, appName: appName)
            case .app:
                let left = appName(owner(of: lhs))
                let right = appName(owner(of: rhs))
                if left != right {
                    return left.localizedStandardCompare(right) == .orderedAscending
                }
                if let order = shortcutOrder(lhs, rhs) { return order }
                return tieBreak(lhs, rhs, appName: appName)
            case .description:
                let left = sortTitle(lhs)
                let right = sortTitle(rhs)
                if left != right {
                    return left.localizedStandardCompare(right) == .orderedAscending
                }
                let leftApp = appName(owner(of: lhs))
                let rightApp = appName(owner(of: rhs))
                if leftApp != rightApp {
                    return leftApp.localizedStandardCompare(rightApp) == .orderedAscending
                }
                if let order = shortcutOrder(lhs, rhs) { return order }
                return lhs.usageKey < rhs.usageKey
            }
        }
    }

    private static func owner(of entry: UsageEntry) -> String {
        UsageStatistics.bundleID(fromUsageKey: entry.usageKey)
    }

    /// The panel's own chord order, so the Statistics tab and the panel agree on what
    /// "along the keyboard" means. `nil` means the two chords are equal in that order.
    private static func shortcutOrder(_ lhs: UsageEntry, _ rhs: UsageEntry) -> Bool? {
        let left = lhs.chord ?? .empty
        let right = rhs.chord ?? .empty
        if PanelOrdering.compare(left, right) { return true }
        if PanelOrdering.compare(right, left) { return false }
        return nil
    }

    /// A missing title sorts last rather than as an empty string, which would put every
    /// row the scan has not seen yet at the top of a "by command" list.
    private static func sortTitle(_ entry: UsageEntry) -> String {
        entry.title ?? "\u{10FFFF}"
    }

    private static func tieBreak(
        _ lhs: UsageEntry,
        _ rhs: UsageEntry,
        appName: (String) -> String
    ) -> Bool {
        let left = sortTitle(lhs)
        let right = sortTitle(rhs)
        if left != right {
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        let leftApp = appName(owner(of: lhs))
        let rightApp = appName(owner(of: rhs))
        if leftApp != rightApp {
            return leftApp.localizedStandardCompare(rightApp) == .orderedAscending
        }
        return lhs.usageKey < rhs.usageKey
    }
}
