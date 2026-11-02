import Foundation

/// The decision a key press in the search field asks for. Kept free of AppKit so it can be
/// unit-tested instead of living inside a local-event monitor.
nonisolated enum SearchKeyAction: Equatable, Sendable {
    /// Move the result selection by `delta` (+1 down, -1 up); the event is swallowed.
    case moveSelection(delta: Int)
    /// Close the search field; the event is swallowed.
    case close
    /// Jump back to the panel (bare `/` on an empty query); the event is swallowed.
    case returnToPanel
    /// Let the text field handle the event (typing, or caret movement with the arrows).
    case passThrough
}

/// Routes a key press in the search field to one action.
///
/// Physical arrows work bare, and macOS's Emacs equivalents (⌃N/⌃P/⌃B/⌃F) work through the
/// same `NavigationKey` mapping used everywhere else. Arrows carrying any other modifier
/// (⌘↓, ⇧↑ …) cannot move a single-line field's caret, so the up/down ones still move the
/// selection rather than being dropped; left/right always pass through.
nonisolated enum SearchKeyRouter {
    static func action(
        keyCode: UInt16,
        modifiers: ModifierSet,
        isQueryEmpty: Bool
    ) -> SearchKeyAction {
        if keyCode == KeyCode.slash, modifiers.isEmpty, isQueryEmpty {
            return .returnToPanel
        }
        // Physical arrows (bare) plus the Emacs keys with ⌃ held.
        if let direction = NavigationKey.direction(keyCode: keyCode, modifiers: modifiers) {
            switch direction {
            case .down: return .moveSelection(delta: 1)
            case .up: return .moveSelection(delta: -1)
            case .left, .right: return .passThrough
            }
        }
        if keyCode == KeyCode.escape { return .close }
        // Arrows under other modifiers (⌘↓, ⇧↑ …): the field cannot use them, keep navigating.
        if keyCode == KeyCode.down { return .moveSelection(delta: 1) }
        if keyCode == KeyCode.up { return .moveSelection(delta: -1) }
        return .passThrough
    }
}
