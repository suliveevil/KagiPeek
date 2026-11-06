import Foundation

/// The "press the trigger modifier twice to pin the panel" gesture, as a state machine.
///
/// The engine used to keep `lastCommandDownAt` and re-implement the same three branches
/// inline in `handleModifiers`. The gesture is pure: it reads the trigger key's pressed
/// state and the clock and answers "did this release complete a double-tap?". A test can
/// feed it any stream of press/release edges and pin the windowing behaviour.
///
/// Only the **gap between the two taps** is timed. How long a finger stays on the key is
/// not part of the decision: a slow press is still a tap, and a trigger held on the second
/// tap still completes when it comes up. The gap is capped by `DoubleTapTiming`, so the
/// gesture means "two clean taps with nothing in between" rather than "two taps in under
/// 0.3 seconds".
///
/// `pressed` is the trigger key's state, not the whole modifier set: which physical key
/// counts is decided by `TriggerKey`, which is the only thing that knows left from right.
nonisolated struct ModifierDoubleTap: Equatable {
    /// The trigger key's state on the previous event, for edge detection.
    private var isPressed = false
    /// True while the current press still belongs to the gesture. A typed key clears it,
    /// so the chord's release is not recorded as a tap.
    private var pressIsCandidate = false
    /// When the first tap ended. The second tap must begin within the window.
    private var firstTapEndedAt: Date? = nil
    /// When the second press began, if that press is the second half of the gesture.
    private var secondTapDownAt: Date? = nil

    /// Feeds one `flagsChanged` event, as the trigger key's pressed state.
    ///
    /// A trigger is produced only by the second complete press-and-release pair. The first
    /// single tap is remembered, never acted on.
    mutating func process(pressed: Bool, now: Date, window: TimeInterval) -> Bool {
        defer { isPressed = pressed }

        // The trigger key went down. If a first tap is waiting, this begins the second tap;
        // otherwise it begins a fresh candidate.
        if pressed, !isPressed {
            if let firstTapEndedAt,
               now.timeIntervalSince(firstTapEndedAt) > window {
                // The gap was too long: this press starts a new first tap instead.
                self.firstTapEndedAt = nil
                secondTapDownAt = nil
            }
            pressIsCandidate = true
            if firstTapEndedAt != nil {
                secondTapDownAt = now
            }
            return false
        }

        // The trigger key came back up. A second tap completes regardless of how long it was
        // held; a lone first tap merely records its end time.
        if !pressed, isPressed {
            let secondDown = secondTapDownAt
            secondTapDownAt = nil
            if secondDown != nil {
                pressIsCandidate = false
                firstTapEndedAt = nil
                return true
            }
            if pressIsCandidate {
                firstTapEndedAt = now
            }
            pressIsCandidate = false
            return false
        }

        return false
    }

    /// A key was typed between modifier edges: this was a chord, not a gesture. It also
    /// drops any press in progress, so the chord's release cannot become a first tap.
    mutating func cancel() {
        pressIsCandidate = false
        firstTapEndedAt = nil
        secondTapDownAt = nil
    }
}
