import Foundation

/// The "press ⌘ twice to pin the panel" gesture, as a state machine.
///
/// The engine used to keep `lastCommandDownAt` and re-implement the same three branches
/// inline in `handleModifiers`. The gesture is pure: it reads the modifier stream and the
/// clock and answers "did this release complete a double-tap?". A test can feed it any
/// stream of modifier events and pin the windowing behaviour.
struct CommandDoubleTap: Equatable {
    /// When the current ⌘ press began, while a complete tap is still being formed.
    var commandDownAt: Date? = nil
    /// When the first complete ⌘ tap ended. The second tap must begin within the window.
    var firstTapEndedAt: Date? = nil
    /// When the second ⌘ press began. Its release must also land inside the window.
    var secondTapDownAt: Date? = nil

    /// Feeds one `flagsChanged` event.
    ///
    /// A trigger is produced only by the second complete press-and-release pair. The first
    /// single tap is remembered, never acted on.
    mutating func process(
        modifiers: ModifierSet,
        previous: ModifierSet,
        now: Date,
        window: TimeInterval
    ) -> Bool {
        // ⌘ went down alone. If a first tap is waiting, this begins the second tap; otherwise
        // it begins a fresh candidate.
        if modifiers == [.command], previous.isEmpty {
            if let firstTapEndedAt,
               now.timeIntervalSince(firstTapEndedAt) > window {
                // The gap was too long: this press starts a new first tap instead.
                self.firstTapEndedAt = nil
                secondTapDownAt = nil
            }
            commandDownAt = now
            if firstTapEndedAt != nil {
                secondTapDownAt = now
            }
            return false
        }

        // ⌘ came back up alone. It completes the second tap only when that tap both started
        // and ended inside the window. A lone first tap merely records its end time.
        if modifiers.isEmpty, previous == [.command] {
            let secondDown = secondTapDownAt
            let firstDown = commandDownAt
            commandDownAt = nil
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

        // Any other modifier transition breaks the gesture. A real key press is reported by
        // the engine through `cancel()`, because key events do not pass through this stream.
        reset()
        return false
    }

    /// A key was typed between modifier edges: this was a chord, not a gesture.
    mutating func cancel() {
        reset()
    }

    private mutating func reset() {
        commandDownAt = nil
        firstTapEndedAt = nil
        secondTapDownAt = nil
    }
}
