import Foundation

/// Turns a press-and-release of a modifier into a sticky tick.
///
/// Two ways of narrowing have to live side by side, and they are distinguished by a single
/// question: did the user let go quickly without typing anything?
///
/// - **hold** — which-key style. The list narrows while the key is down and goes back to
///   full the moment it is released. A way of *looking*.
/// - **tap** — emacs style. Pressing and releasing ⌥ leaves ⌥ ticked, so the next tap
///   (⌘) narrows *on top of it*, and the sequence ends with an ordinary key. A way of
///   *composing*: ⌥ ⌘ C is ⌥⌘C without ever holding two keys at once.
///
/// The two are told apart by time and by what happened in between: a release counts as a tap
/// only if it came soon enough and no other key was pressed while the modifier was down.
/// Anything slower is a hold, and a modifier that was used *with* a key was never a tap at
/// all — it was half of a shortcut.
struct ModifierTapTracker: Equatable, Sendable {
    /// When the current press began; nil while no press is being tracked.
    private(set) var startedAt: Date?
    /// Every modifier seen since the press began, so ⌥⌘ rolled across two events still
    /// reads as one press.
    private(set) var pressed: ModifierSet = []
    /// Whether a key was pressed while the modifier was down, which means it was a shortcut.
    private(set) var consumedByKey = false

    mutating func reset() {
        startedAt = nil
        pressed = []
        consumedByKey = false
    }

    /// A key went down while a modifier was held, so this press is part of a shortcut.
    mutating func noteKeyPress() {
        guard startedAt != nil else { return }
        consumedByKey = true
    }

    /// Feeds one modifier-change event.
    ///
    /// - Parameters:
    ///   - modifiers: what is down now, already stripped of a lone ⇧ (which is never a
    ///     decision to narrow — capital letters arrive with it).
    ///   - previous: what was down before this event, to tell a fresh press from a continued
    ///     one. A press that was already down when the panel opened is the trigger that
    ///     opened it, not a tap, and must not become a tick.
    /// - Returns: the modifiers to tick, once, on the release that ends a tap.
    mutating func flagsChanged(
        _ modifiers: ModifierSet,
        previous: ModifierSet,
        now: Date,
        window: TimeInterval
    ) -> ModifierSet? {
        if !modifiers.isEmpty {
            if startedAt == nil {
                guard previous.isEmpty else { return nil }
                startedAt = now
                pressed = modifiers
                consumedByKey = false
            } else {
                pressed.formUnion(modifiers)
            }
            return nil
        }
        guard let started = startedAt else { return nil }
        // Read both before `reset()` clears them — the flags have to survive their own
        // cleanup, or a modifier that was used with a key (the ⌘ of ⌘C) reads as a tap.
        let tapped = pressed
        let wasConsumed = consumedByKey
        reset()
        guard !tapped.isEmpty,
              !wasConsumed,
              now.timeIntervalSince(started) <= window
        else { return nil }
        return tapped
    }
}
