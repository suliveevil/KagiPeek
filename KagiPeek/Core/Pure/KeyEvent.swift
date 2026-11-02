import Foundation

enum KeyEventKind {
    case flagsChanged
    case keyDown
    case keyUp
    case interruption
}

struct KeyEvent {
    let kind: KeyEventKind
    let modifiers: ModifierSet
    /// nil when the event carries no mappable key (pure modifier change, or an exotic key).
    let key: KeyToken?
    let keyCode: UInt16
    let isRepeat: Bool
    let happenedAt: Date
    /// Typed text when the event carries it (the panel reads it while it owns the keys).
    var characters: String? = nil
}
