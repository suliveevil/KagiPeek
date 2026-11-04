import Foundation

/// Whether a `flagsChanged` may narrow the open panel.
///
/// The press that summons the panel is a trigger, not a filter: with hold-to-open the
/// modifier is still physically down when the panel appears, and treating it as a held
/// prefix narrowed the list before the user saw it. The panel records that it is waiting
/// for that key's release; this is the one place that decides what a modifier event means.
///
/// State-driven, never time-based: a 200 ms grace window would misfire on a quick double
/// tap and would still narrow a slow release.
nonisolated enum TriggerNarrowGate {
    enum Decision: Equatable {
        /// The trigger key is still down: ignore the event, keep the full list.
        case wait
        /// The trigger key was just released: clear the flag, do not narrow.
        case clearPending
        /// Not a trigger hold any more: narrow as usual.
        case narrow
    }

    /// - Parameters:
    ///   - waitingForRelease: the panel was opened by the modifier gesture and has not yet
    ///     seen that key go up.
    ///   - triggerKeyDown: the event's modifier set still contains the trigger key.
    static func decision(waitingForRelease: Bool, triggerKeyDown: Bool) -> Decision {
        guard waitingForRelease else { return .narrow }
        return triggerKeyDown ? .wait : .clearPending
    }
}
