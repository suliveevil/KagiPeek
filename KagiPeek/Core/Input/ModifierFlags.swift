import AppKit

extension ModifierSet {
    /// Bridges an AppKit event's flags to the pure modifier set.
    ///
    /// It lives here rather than in a view: the search palette and the
    /// surface panel all need it, and a copy in one view file meant every other surface had
    /// to import that view to get it.
    static func from(flags: NSEvent.ModifierFlags) -> ModifierSet {
        var set: ModifierSet = []
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.command) { set.insert(.command) }
        return set
    }
}
