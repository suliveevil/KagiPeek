import Foundation

/// The one timing rule behind "press the trigger key twice".
///
/// The window is not a user preference any more. It follows the system double-click speed,
/// which every macOS user has already tuned for their own hands, and is clamped so neither
/// an extreme system setting nor a very slow one changes the gesture's meaning. Keeping the
/// clamp here — not in the UI — makes the decision pure and testable.
nonisolated enum DoubleTapTiming {
    /// The system value is clamped into this range. The lower bound keeps two distinct
    /// presses from merging on a very fast machine; the upper bound keeps a stray press
    /// much later from completing a gesture that was over.
    static let range: ClosedRange<TimeInterval> = 0.25...0.6

    /// The gap allowed between the two taps, derived from the system double-click speed.
    static func window(systemDoubleClickInterval: TimeInterval) -> TimeInterval {
        guard systemDoubleClickInterval.isFinite else { return range.lowerBound }
        return min(max(systemDoubleClickInterval, range.lowerBound), range.upperBound)
    }
}
