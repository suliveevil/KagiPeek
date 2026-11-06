import Foundation

/// Decodes the `AXMenuItemCmdModifiers` bit field into Kaname's modifier set.
///
/// The raw values below are measured from running apps, not assumed. On macOS 26 Safari:
///
/// | raw | bits set | item | macOS renders |
/// | --- | --- | --- | --- |
/// | 0 | – | 新建窗口 (⌘N) | ⌘N |
/// | 1 | Shift | 退出登录 (⇧⌘Q) | ⇧⌘Q |
/// | 2 | Option | 强制退出… (⌥⌘⎋) | ⌥⌘⎋ |
/// | 4 | Control | 锁屏 (⌃⌘Q) | ⌃⌘Q |
/// | 8 | No Command | 关于本机 (no shortcut) | – |
/// | 24 | Fn + No Command | 表情与符号 (🌐E) | 🌐E |
/// | 28 | Fn + Control + No Command | 填充 (🌐⌃F) | 🌐⌃F |
///
/// So bit 4 is the Globe/Fn key, the one bit the old `shortcutChord` dropped: it produced
/// `⌘E` from 24 and `⌃⌘F` from 28 minus the Globe. Bit 3 is not a modifier at all — it
/// suppresses the otherwise implied Command. Bits above 4 are unknown; the decoder reports
/// them instead of silently discarding them, and the scanner refuses to build a chord from
/// an incomplete decode.
nonisolated struct MenuShortcutModifiers: Equatable, Sendable {
    /// Bits Kaname knows how to name.
    static let knownBits = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4)

    var modifiers: ModifierSet
    var suppressesCommand: Bool
    var unknownBits: Int

    var isComplete: Bool { unknownBits == 0 }

    static func decode(rawValue: Int) -> MenuShortcutModifiers {
        var modifiers: ModifierSet = []
        if rawValue & (1 << 0) != 0 { modifiers.insert(.shift) }
        if rawValue & (1 << 1) != 0 { modifiers.insert(.option) }
        if rawValue & (1 << 2) != 0 { modifiers.insert(.control) }
        if rawValue & (1 << 4) != 0 { modifiers.insert(.function) }

        let suppressesCommand = rawValue & (1 << 3) != 0
        // Command is implied unless the "no command" bit is set.
        if !suppressesCommand { modifiers.insert(.command) }

        return MenuShortcutModifiers(
            modifiers: modifiers,
            suppressesCommand: suppressesCommand,
            unknownBits: rawValue & ~knownBits
        )
    }
}
