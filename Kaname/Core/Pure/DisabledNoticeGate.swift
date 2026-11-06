import Foundation

/// Keeps a disabled row from repeating its explanation.
///
/// A disabled row looks the same whether it is briefly busy or permanently unavailable, so
/// the click has to explain itself. Explaining is only useful once: clicking the same row
/// three times in a row should not stack three identical notices, while moving to another
/// row is a new question and deserves an answer.
nonisolated struct DisabledNoticeGate: Equatable, Sendable {
    /// The same row may speak once in this many seconds.
    static let interval: TimeInterval = 3

    private(set) var lastRowID: String?
    private(set) var lastShownAt: Date?

    /// - Returns: whether the notice should be shown; records the answer when it is `true`.
    mutating func shouldShow(rowID: String, at now: Date) -> Bool {
        if let lastRowID, lastRowID == rowID, let lastShownAt,
           now.timeIntervalSince(lastShownAt) < Self.interval {
            return false
        }
        self.lastRowID = rowID
        self.lastShownAt = now
        return true
    }
}
