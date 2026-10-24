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

    /// Bridges a CoreGraphics event tap's flags to the pure modifier set: the tap speaks
    /// `CGEventFlags`, the engine speaks `ModifierSet`, and the two mappings must not drift.
    static func from(cgEventFlags: CGEventFlags) -> ModifierSet {
        var set: ModifierSet = []
        if cgEventFlags.contains(.maskControl) { set.insert(.control) }
        if cgEventFlags.contains(.maskAlternate) { set.insert(.option) }
        if cgEventFlags.contains(.maskShift) { set.insert(.shift) }
        if cgEventFlags.contains(.maskCommand) { set.insert(.command) }
        return set
    }

    /// The inverse bridge: one chord, posted back through the HID tap
    /// (`ShortcutInjector`). The mirror image of `from(cgEventFlags:)`.
    static func cgEventFlags(for modifiers: ModifierSet) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}
