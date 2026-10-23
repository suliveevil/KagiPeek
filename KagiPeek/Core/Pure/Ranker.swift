import Foundation

struct UsageRecord: Codable, Hashable, Sendable {
    var count: Int
    var lastUsed: Date
}

/// How the statistics page orders its lists.
///
/// Two cases have been removed from this enum, for two different reasons, and both are still
/// decoded below because a settings file on disk may name them:
///
/// - `contextFirst` scored identically to `frequencyDesc` — the frontmost app's rows win in
///   every mode anyway — so it was a menu item that changed nothing.
/// - `review` ordered by "least recently used first". It was a second, weaker way to ask for
///   the same thing `smart` already answers with decayed usefulness, and the whole review
///   idea is gone rather than left as a sorting option nothing else in the app refers to.
enum RankMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Recent and frequent first, by decayed usefulness.
    case smart
    case frequencyDesc
    case keyOrder
    case alphabetical

    /// Decodes leniently: a throwing decode here would take the whole settings document with
    /// it, and an old file may still name a mode that no longer exists.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "contextFirst": self = .frequencyDesc
        // `review` has no successor: "least recently used" was the opposite of what the
        // statistics page is for, so an old file falls back to the default.
        case "review": self = .smart
        default: self = RankMode(rawValue: raw) ?? .smart
        }
    }

    var titleKey: L10nKey {
        switch self {
        case .smart: return .sortSmart
        case .frequencyDesc: return .sortFrequencyDesc
        case .keyOrder: return .sortKeyOrder
        case .alphabetical: return .sortAlphabetical
        }
    }
}

/// Usage maths shared with the statistics ordering.
enum Ranker {
    /// Exponentially decayed press count with a 60-day half-life-ish curve.
    static func decayedUsefulness(_ record: UsageRecord?, now: Date) -> Double {
        guard let record else { return 0 }
        let age = max(0, now.timeIntervalSince(record.lastUsed) / 86_400)
        return Double(max(0, record.count)) * exp(-age / 60.0)
    }
}
