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
/// so Kaname accepts them wherever it consumes arrow keys.
nonisolated enum NavigationKey {
    /// Whether this press is the search palette's bare `/`.
    ///
    /// The character decides when it is known, the ANSI key code is the fallback for events
    /// that were not decoded. Paging keys are not here: they are configurable, so
    /// `PagingKeyPlan` owns that decision.
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
