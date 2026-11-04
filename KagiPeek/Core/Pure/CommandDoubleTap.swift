import Foundation

/// The "press the trigger modifier twice to pin the panel" gesture, as a state machine.
///
/// The engine used to keep `lastCommandDownAt` and re-implement the same three branches
/// inline in `handleModifiers`. The gesture is pure: it reads the trigger key's pressed
/// state and the clock and answers "did this release complete a double-tap?". A test can
/// feed it any stream of press/release edges and pin the windowing behaviour.
///
/// `pressed` is the trigger key's state, not the whole modifier set: which physical key
/// counts is decided by `TriggerKey`, which is the only thing that knows left from right.
nonisolated struct ModifierDoubleTap: Equatable {
    /// The trigger key's state on the previous event, for edge detection.
    private var isPressed = false
    /// When the current press began, while a complete tap is still being formed.
    private var pressStartedAt: Date? = nil
    /// When the first complete tap ended. The second tap must begin within the window.
    private var firstTapEndedAt: Date? = nil
    /// When the second press began. Its release must also land inside the window.
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
            pressStartedAt = now
            if firstTapEndedAt != nil {
                secondTapDownAt = now
            }
            return false
        }

        // The trigger key came back up. It completes the second tap only when that tap both
        // started and ended inside the window. A lone first tap merely records its end time.
        if !pressed, isPressed {
            let secondDown = secondTapDownAt
            let firstDown = pressStartedAt
            pressStartedAt = nil
            secondTapDownAt = nil
            if let secondDown {
                let completed = now.timeIntervalSince(secondDown) <= window
                firstTapEndedAt = nil
                return completed
            }
            if let firstDown, now.timeIntervalSince(firstDown) <= window {
                firstTapEndedAt = now
                return false
            }
            firstTapEndedAt = nil
            return false
        }

        return false
    }

    /// A key was typed between modifier edges: this was a chord, not a gesture.
    mutating func cancel() {
        pressStartedAt = nil
        firstTapEndedAt = nil
        secondTapDownAt = nil
    }
}
