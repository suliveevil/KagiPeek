import Foundation

/// The decision a key press in the search field asks for. Kept free of AppKit so it can be
/// unit-tested instead of living inside a local-event monitor.
nonisolated enum SearchKeyAction: Equatable, Sendable {
    /// Move the result selection by `delta` (+1 down, -1 up); the event is swallowed.
    case moveSelection(delta: Int)
    /// Close the search field; the event is swallowed.
    case close
    /// Jump back to the panel (bare `/` on an empty query); the event is swallowed. Tab
    /// deliberately does not get this action while the search field is focused.
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
        isQueryEmpty: Bool,
        characters: String? = nil
    ) -> SearchKeyAction {
        if isQueryEmpty, NavigationKey.isSlash(
            keyCode: keyCode,
            modifiers: modifiers,
            characters: characters
        ) {
            return .returnToPanel
        }
        // Bare Tab belongs to the field editor while the search box has focus: it is the
        // system's focus-traversal key, not a surface switch. Swallowing it here trapped the
        // caret in the query and made the two jobs compete for one keystroke. The panel,
        // which has no text input, is the only layer where Tab switches surfaces.
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
