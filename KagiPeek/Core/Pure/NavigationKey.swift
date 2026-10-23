import Foundation

enum NavigationDirection: Equatable, Sendable {
    case up
    case down
    case left
    case right
}

/// Maps arrow keys and their Emacs/macOS equivalents to a direction.
///
/// macOS text views have always bound ⌃F/⌃B/⌃N/⌃P to forward/backward/next/previous,
/// so KagiPeek accepts them wherever it consumes arrow keys.
enum NavigationKey {
    /// Semicolon pages back, single quote pages forward.
    static func pageStep(keyCode: UInt16, modifiers: ModifierSet) -> Int? {
        guard modifiers.isEmpty else { return nil }
        switch keyCode {
        case 41: return -1   // ;
        case 39: return 1    // '
        default: return nil
        }
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
