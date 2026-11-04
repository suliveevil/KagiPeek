import Foundation

nonisolated enum NavigationDirection: Equatable, Sendable {
    case up
    case down
    case left
    case right
}

/// Maps arrow keys and their Emacs/macOS equivalents to a direction.
///
/// macOS text views have always bound ⌃F/⌃B/⌃N/⌃P to forward/backward/next/previous,
/// so KagiPeek accepts them wherever it consumes arrow keys.
nonisolated enum NavigationKey {
    /// Semicolon pages back, single quote pages forward.
    ///
    /// Decided by the typed character, not the ANSI key code: on a layout where key code 41
    /// produces something else, pressing that physical key must not silently page the list.
    /// `characters` is nil only when the event was not decoded (synthetic events in tests,
    /// or a tap running without character decoding); the ANSI codes are the fallback for
    /// exactly that case.
    static func pageStep(keyCode: UInt16, modifiers: ModifierSet, characters: String? = nil) -> Int? {
        guard modifiers.isEmpty else { return nil }
        if let first = characters?.first {
            switch first {
            case ";": return -1
            case "'": return 1
            default: return nil
            }
        }
        switch keyCode {
        case 41: return -1   // ; (ANSI)
        case 39: return 1    // ' (ANSI)
        default: return nil
        }
    }

    /// Whether this press is the search palette's bare `/`.
    ///
    /// Same split as `pageStep`: the character decides when it is known, the ANSI key code
    /// is the fallback for events that were not decoded.
    static func isSlash(keyCode: UInt16, modifiers: ModifierSet, characters: String? = nil) -> Bool {
        guard modifiers.isEmpty else { return false }
        if let first = characters?.first {
            return first == "/"
        }
        return keyCode == KeyCode.slash
    }

    static func direction(keyCode: UInt16, modifiers: ModifierSet) -> NavigationDirection? {
        if modifiers.isEmpty {
            switch keyCode {
            case 126: return .up
            case 125: return .down
            case 123: return .left
            case 124: return .right
            default: return nil
            }
        }
        guard modifiers == [.control] else { return nil }
        switch keyCode {
        case 35: return .up     // P
        case 45: return .down   // N
        case 11: return .left   // B
        case 3: return .right   // F
        default: return nil
        }
    }
}
