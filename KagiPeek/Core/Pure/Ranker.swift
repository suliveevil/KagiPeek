import Foundation

struct UsageRecord: Codable, Hashable, Sendable {
    var count: Int
    var lastUsed: Date
}

/// How the search results are ordered.
///
/// There used to be a `contextFirst` case next to `smart`. It scored identically to
/// `frequencyDesc` — the frontmost app's rows win in every mode anyway — so it was a menu
/// item that changed nothing, and it is gone.
enum RankMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Context first, then frequency, with a gentle boost for shortcuts you used to use.
    case smart
    case frequencyDesc
    case review
    case keyOrder
    case alphabetical

    /// Decodes leniently: an old settings file may still say `contextFirst`, and a throwing
    /// decode here would take the whole settings document with it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "contextFirst" {
            self = .frequencyDesc
        } else {
            self = RankMode(rawValue: raw) ?? .smart
        }
    }

    var titleKey: L10nKey {
        switch self {
        case .smart: return .sortSmart
        case .frequencyDesc: return .sortFrequencyDesc
        case .review: return .sortReview
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
