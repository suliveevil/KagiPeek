import Foundation

/// Karabiner-style hyper (⌃⌥⇧⌘) used as a single "Escape" key.
///
/// The engine used to keep `hyperArmedAt` / `hyperUsedKey` and inline the same branches in
/// `handleModifiers`. The gesture is a state machine: a lone hyper press arms it, a key
/// pressed meanwhile marks it used, and a clean release within the window dismisses the
/// panel. Held longer — or used — it is just a modifier set that narrows the list.
struct HyperEscape: Equatable {
    enum Outcome: Equatable {
        /// A lone hyper press started; the panel narrows to it.
        case arm
        /// The hyper key was released cleanly within the window: dismiss the panel.
        case releaseDismiss
        /// The hyper press ended, but was used or took too long: just clear the arm.
        case clear
        /// No arm was standing; nothing to do.
        case none
    }

    /// When the hyper press went down, or nil when no hyper is armed.
    var armedAt: Date? = nil
    /// Whether another key was pressed while the hyper was down.
    var usedKey = false

    /// How short a clean hyper release has to be to count as Escape.
    static let dismissWindow: TimeInterval = 1.0

    private static let hyper: ModifierSet = [.control, .option, .shift, .command]

    /// Feeds one `flagsChanged` event.
    mutating func process(modifiers: ModifierSet, now: Date) -> Outcome {
        if modifiers == Self.hyper {
            // A lone hyper press: arm it. Repeating the press is still the same arm.
            if armedAt == nil {
                armedAt = now
                usedKey = false
            }
            return .arm
        }
        if let armedAt {
            let elapsed = now.timeIntervalSince(armedAt)
            let wasUsed = usedKey
            self.armedAt = nil
            usedKey = false
            if modifiers.isEmpty, elapsed < Self.dismissWindow, !wasUsed {
                return .releaseDismiss
            }
            return .clear
        }
        return .none
    }

    /// Marks the armed hyper as used — the panel consumed another key in between, so a
    /// clean release must no longer count as Escape.
    mutating func noteKeyUsed() {
        usedKey = true
    }
}
