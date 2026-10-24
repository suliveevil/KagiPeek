import Foundation

/// The "press ⌘ twice to pin the panel" gesture, as a state machine.
///
/// The engine used to keep `lastCommandDownAt` and re-implement the same three branches
/// inline in `handleModifiers`. The gesture is pure: it reads the modifier stream and the
/// clock and answers "did this release complete a double-tap?". A test can feed it any
/// stream of modifier events and pin the windowing behaviour.
struct CommandDoubleTap: Equatable {
    /// When the command key went down while nothing else was down, or nil when no candidate
    /// press is being watched.
    var lastCommandDownAt: Date? = nil

    /// Feeds one `flagsChanged` event.
    ///
    /// - Returns: true when the release of the command key happened within `window` of its
    ///   press and nothing else was pressed in between — the caller toggles the pinned panel.
    mutating func process(
        modifiers: ModifierSet,
        previous: ModifierSet,
        now: Date,
        window: TimeInterval
    ) -> Bool {
        // ⌘ went down alone: a candidate press to watch.
        if modifiers == [.command], previous.isEmpty {
            lastCommandDownAt = now
            return false
        }
        // ⌘ came back up alone within the window: the double-tap completed.
        if modifiers.isEmpty, previous == [.command],
           let started = lastCommandDownAt,
           now.timeIntervalSince(started) <= window {
            lastCommandDownAt = nil
            return true
        }
        // Any other modifier between press and release breaks the gesture. A plain ⌘ press
        // followed by ⌘⌥ is not a double-tap of anything.
        if !modifiers.isEmpty {
            lastCommandDownAt = nil
        }
        return false
    }
}
