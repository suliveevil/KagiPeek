import Foundation

/// Maps macOS virtual key codes to stable tokens.
///
/// macOS compares menu shortcuts by *virtual key code*, not by the character produced
/// under the current layout. Anything involving option/control (where the character is
/// meaningless) and every non-printable key (arrows, function keys, delete, …) therefore
/// goes through this table. Values are the classic `kVK_*` constants.
nonisolated enum KeyMapper {
    private static let table: [UInt16: String] = [
        // Letters
        0x00: "a", 0x0B: "b", 0x08: "c", 0x02: "d", 0x0E: "e", 0x03: "f", 0x05: "g",
        0x04: "h", 0x22: "i", 0x26: "j", 0x28: "k", 0x25: "l", 0x2E: "m", 0x2D: "n",
        0x1F: "o", 0x23: "p", 0x0C: "q", 0x0F: "r", 0x01: "s", 0x11: "t", 0x20: "u",
        0x09: "v", 0x0D: "w", 0x07: "x", 0x10: "y", 0x06: "z",

        // Digits
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
        0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",

        // Punctuation
        0x18: "=", 0x1B: "-", 0x1E: "]", 0x21: "[", 0x27: "'", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x32: "`",

        // Whitespace and editing
        0x24: "return", 0x30: "tab", 0x31: "space", 0x33: "delete",
        0x35: "esc", 0x75: "fdelete",

        // Navigation
        0x7B: "left", 0x7C: "right", 0x7D: "down", 0x7E: "up",
        0x73: "home", 0x77: "end", 0x74: "pageup", 0x79: "pagedown",
        0x72: "help",

        // Function keys
        0x7A: "f1", 0x78: "f2", 0x63: "f3", 0x76: "f4", 0x60: "f5",
        0x61: "f6", 0x62: "f7", 0x64: "f8", 0x65: "f9", 0x6D: "f10",
        0x67: "f11", 0x6F: "f12", 0x69: "f13", 0x6B: "f14", 0x71: "f15",
        0x6A: "f16", 0x40: "f17", 0x4F: "f18", 0x50: "f19", 0x5A: "f20",

        // Keypad
        0x41: "kp.", 0x43: "kp*", 0x45: "kp+", 0x47: "kpclear", 0x4B: "kp/",
        0x4C: "enter", 0x4E: "kp-", 0x51: "kp=", 0x52: "kp0", 0x53: "kp1",
        0x54: "kp2", 0x55: "kp3", 0x56: "kp4", 0x57: "kp5", 0x58: "kp6",
        0x59: "kp7", 0x5B: "kp8", 0x5C: "kp9",

        // Misc
        0x0A: "iso-section", 0x5D: "jis-yen", 0x5E: "jis-underscore",
        0x66: "jis-keypad-comma"
    ]

    /// Reverse lookup used when replaying a shortcut into the front app.
    private static let reverseTable: [String: UInt16] = {
        var map: [String: UInt16] = [:]
        for (code, name) in table where map[name] == nil {
            map[name] = code
        }
        return map
    }()

    /// Physical-key token for a virtual key code, independent of the active layout.
    static func token(forKeyCode code: UInt16) -> KeyToken? {
        table[code].map { KeyToken($0) }
    }

    static func keyCode(for token: KeyToken) -> UInt16? {
        reverseTable[token.raw]
    }

    static func token(forKeyCode code: Int64) -> KeyToken? {
        guard code >= 0, code <= Int64(UInt16.max) else { return nil }
        return token(forKeyCode: UInt16(code))
    }

    /// Best-effort token for a live key event.
    ///
    /// Printable keys without option/control use the produced character (so AZERTY and
    /// Dvorak users see the key they actually pressed); everything else uses the physical
    /// key code, which is what macOS matches shortcuts against.
    nonisolated static func token(keyCode: UInt16, unicode: String?, modifiers: ModifierSet) -> KeyToken? {
        let usesPhysicalKey = modifiers.contains(.option) || modifiers.contains(.control)
        if !usesPhysicalKey, let unicode, let normalized = normalize(character: unicode) {
            return normalized
        }
        if let physical = token(forKeyCode: keyCode) {
            return physical
        }
        return unicode.flatMap(normalize(character:))
    }

    /// Normalises a menu-bar / event character to a token (" " → space, "C" → c, …).
    nonisolated static func normalize(character: String) -> KeyToken? {
        // A control character is not a printable key, so it must not become the token.
        // Esc, Tab, Return and Delete all carry one (U+001B, U+0009, U+000D, U+007F) and
        // `token(keyCode:unicode:)` prefers the character over the key code — so taking
        // them here made Escape resolve to U+001B, which is never equal to "esc", while
        // Tab and Return both trimmed down to "space". Rejecting the C0 block and DEL
        // lets those keys fall through to their virtual key code, which is what macOS
        // matches shortcuts against in the first place.
        if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 {
            if scalar.value < 0x20 || scalar.value == 0x7F { return nil }
        }
        let trimmed = character.trimmingCharacters(in: .whitespacesAndNewlines)
        if character == " " || trimmed.isEmpty && !character.isEmpty {
            return KeyToken("space")
        }
        guard !trimmed.isEmpty else { return nil }
        guard let scalar = trimmed.unicodeScalars.first else { return nil }
        if scalar.value > 0xF000, scalar.value < 0xF900 {
            // Private-use range used by NSFunctionKey; cannot be a printable shortcut key.
            return nil
        }
        if trimmed.count == 1 {
            return KeyToken(trimmed)
        }
        return nil
    }
}
