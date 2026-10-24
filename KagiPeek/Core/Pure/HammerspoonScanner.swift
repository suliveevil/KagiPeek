import Foundation

/// Reads Hammerspoon's `init.lua` and extracts the hot keys it registers.
///
/// There is no API for this: the config is Lua source, so the scanner has to find every
/// `hs.hotkey.bind(...)` call and resolve the arguments that are literals. A bind whose
/// modifiers or key come from a variable (`local hyper = {"cmd", "alt"}`) is skipped
/// rather than guessed at — a half-resolved modifier set would claim a conflict for a
/// combo that is not the one being pressed.
///
/// Only `init.lua` is read; binds inside `require`d modules are out of reach of a parser
/// that does not run Lua, and pretending otherwise would be worse than saying nothing.
nonisolated enum HammerspoonScanner {

    static func scan(homeDirectory: URL, fileManager: FileManager = .default) -> [ConfigBinding] {
        guard let path = ConfigFileScanner.firstExistingPath(
            ConfigTool.hammerspoon.relativeSearchPaths,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) else { return [] }
        guard let text = ConfigFileScanner.readText(atPath: path, fileManager: fileManager) else { return [] }
        return bindings(from: text)
    }

    static func bindings(from source: String) -> [ConfigBinding] {
        let characters = Array(stripComments(source))
        let needle = Array("hs.hotkey.bind")

        var bindings: [ConfigBinding] = []
        var index = 0
        while index <= characters.count - needle.count {
            guard matches(characters, at: index, needle) else { index += 1; continue }

            guard let openParen = firstOpenParen(characters, after: index + needle.count),
                  let (arguments, closeParen) = readArguments(characters, openParenIndex: openParen) else {
                index += needle.count
                continue
            }
            if let binding = binding(fromArguments: arguments) {
                bindings.append(binding)
            }
            index = closeParen + 1
        }
        return bindings
    }

    // MARK: - Arguments

    static func binding(fromArguments arguments: [String]) -> ConfigBinding? {
        guard arguments.count >= 2,
              let modifiers = modifiers(fromModsArgument: arguments[0]),
              let token = token(fromKeyArgument: arguments[1]) else { return nil }

        // The optional third argument is the message Hammerspoon flashes on screen. When
        // it is a literal it makes a far better label than "Hammerspoon hotkey".
        var title = "Hammerspoon hotkey"
        if arguments.count >= 3,
           let message = stringLiteralContent(arguments[2]),
           !message.isEmpty {
            title = message
        }
        return ConfigBinding(chord: .combo(modifiers, token), title: title)
    }

    /// Resolves the modifiers argument: a literal table (`{"cmd", "shift"}`, including the
    /// empty `{}`) or a literal string (`"cmd"`, `"cmd-alt"`). Anything else is nil, which
    /// is the signal to skip the whole bind rather than trust a set we cannot read.
    static func modifiers(fromModsArgument raw: String) -> ModifierSet? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            let inner = Array(trimmed.dropFirst().dropLast())
            var modifiers: ModifierSet = []
            var residual = ""
            var index = 0
            while index < inner.count {
                let character = inner[index]
                if character == "\"" || character == "'" {
                    let (token, next) = readQuoted(inner, openQuoteIndex: index)
                    modifiers.formUnion(modifierSet(fromToken: token))
                    index = next
                } else {
                    if !character.isWhitespace && character != "," { residual.append(character) }
                    index += 1
                }
            }
            // Anything alphanumeric left outside the quotes is an identifier we cannot
            // resolve, and silently dropping it would understate the combo.
            if residual.contains(where: { $0.isLetter || $0.isNumber || $0 == "_" }) { return nil }
            return modifiers
        }
        if let string = stringLiteralContent(trimmed) {
            return modifierSet(fromToken: string)
        }
        return nil
    }

    /// A string literal through Hammerspoon's key names, or a bare integer, which
    /// Hammerspoon also accepts as a raw key code.
    static func token(fromKeyArgument raw: String) -> KeyToken? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let string = stringLiteralContent(trimmed) {
            return token(forHammerspoonKey: string)
        }
        if let code = Int(trimmed), code >= 0, code <= Int(UInt16.max) {
            return KeyMapper.token(forKeyCode: UInt16(code))
        }
        return nil
    }

    /// Hammerspoon accepts several spellings and even the glyphs, and one string can pack
    /// more than one modifier ("cmd-alt"), so this matches on substrings.
    ///
    /// `fn` is left out on purpose: it is not one of the four modifiers conflicts are
    /// grouped by, and Hammerspoon cannot register it as one anyway. Deliberately
    /// substring-based and glyph-aware — Hammerspoon packs modifiers into one token
    /// ("cmd-alt") — not the whole-word table the search palette uses.
    static func modifierSet(fromToken token: String) -> ModifierSet {
        let lowered = token.lowercased()
        var modifiers: ModifierSet = []
        if lowered.contains("cmd") || lowered.contains("command") || lowered.contains("⌘") {
            modifiers.insert(.command)
        }
        if lowered.contains("shift") || lowered.contains("⇧") { modifiers.insert(.shift) }
        if lowered.contains("alt") || lowered.contains("option") || lowered.contains("opt") || lowered.contains("⌥") {
            modifiers.insert(.option)
        }
        if lowered.contains("ctrl") || lowered.contains("control") || lowered.contains("⌃") {
            modifiers.insert(.control)
        }
        return modifiers
    }

    static func token(forHammerspoonKey key: String) -> KeyToken? {
        let lowered = key.lowercased()
        if let named = namedKeyMap[lowered] { return named }
        guard lowered.count == 1 else { return nil }
        return ConfigFileScanner.token(forCharacter: lowered)
    }

    private static let namedKeyMap: [String: KeyToken] = [
        "return": "return", "enter": "return", "escape": "esc", "esc": "esc",
        "space": "space", "tab": "tab", "delete": "delete", "forwarddelete": "fdelete",
        "home": "home", "end": "end", "pageup": "pageup", "pagedown": "pagedown",
        "help": "help", "left": "left", "right": "right", "up": "up", "down": "down",
        "pad.": "kp.", "pad*": "kp*", "pad+": "kp+", "pad/": "kp/", "pad-": "kp-",
        "pad=": "kp=", "padclear": "kpclear", "padenter": "enter",
        "pad0": "kp0", "pad1": "kp1", "pad2": "kp2", "pad3": "kp3", "pad4": "kp4",
        "pad5": "kp5", "pad6": "kp6", "pad7": "kp7", "pad8": "kp8", "pad9": "kp9"
    ].merging(ConfigFileScanner.functionKeyNames) { current, _ in current }

    // MARK: - Lua source helpers

    /// Removes Lua comments so a commented-out bind never registers.
    ///
    /// Strings are tracked while scanning, because a `--` inside a string literal is not
    /// a comment and stripping from there would truncate the source mid-call.
    static func stripComments(_ source: String) -> String {
        let characters = Array(source)
        var output = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\"" || character == "'" {
                let (raw, next) = readQuotedRaw(characters, openQuoteIndex: index)
                output += raw
                index = next
                continue
            }

            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                // A long comment `--[[ … ]]` runs to its closing bracket; everything else
                // runs to the end of the line.
                if let level = longBracketLevel(characters, at: index + 2) {
                    let closing = "]" + String(repeating: "=", count: level) + "]"
                    if let end = range(of: closing, in: characters, from: index + 2) {
                        index = end.upperBound
                        continue
                    }
                    index = characters.count
                    continue
                }
                if let newline = characters[index...].firstIndex(of: "\n") {
                    index = newline
                    continue
                }
                index = characters.count
                continue
            }

            output.append(character)
            index += 1
        }
        return output
    }

    /// Reads the arguments of one call, splitting on top-level commas.
    ///
    /// Nesting and quotes are tracked so a comma inside a table or a string does not split
    /// an argument in half.
    static func readArguments(
        _ characters: [Character],
        openParenIndex: Int
    ) -> (arguments: [String], closeParenIndex: Int)? {
        // Depth starts inside the call: the opening paren is the boundary, not part of the
        // first argument, and leaving it on would turn `{"cmd"}` into `({"cmd"}` — which is
        // no longer a literal table, so every bind would silently resolve to nothing.
        var depth = 1
        var arguments: [String] = []
        var current = ""
        var index = openParenIndex + 1

        while index < characters.count {
            let character = characters[index]

            if character == "\"" || character == "'" {
                let (raw, next) = readQuotedRaw(characters, openQuoteIndex: index)
                current += raw
                index = next
                continue
            }

            switch character {
            case "(", "{", "[":
                depth += 1
                current.append(character)
            case ")", "}", "]":
                depth -= 1
                if depth == 0 {
                    arguments.append(current)
                    return (arguments, index)
                }
                current.append(character)
            case "," where depth == 1:
                arguments.append(current)
                current = ""
            default:
                current.append(character)
            }
            index += 1
        }
        return nil
    }

    static func firstOpenParen(_ characters: [Character], after index: Int) -> Int? {
        var cursor = index
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "(" { return cursor }
            if !character.isWhitespace { return nil }
            cursor += 1
        }
        return nil
    }

    static func matches(_ characters: [Character], at index: Int, _ needle: [Character]) -> Bool {
        guard index + needle.count <= characters.count else { return false }
        for offset in 0..<needle.count where characters[index + offset] != needle[offset] {
            return false
        }
        return true
    }

    /// Reads a quoted string, returning the content with escapes resolved.
    static func readQuoted(_ characters: [Character], openQuoteIndex: Int) -> (token: String, next: Int) {
        let (raw, next) = readQuotedRaw(characters, openQuoteIndex: openQuoteIndex)
        return (stringLiteralContent(raw) ?? "", next)
    }

    private static func readQuotedRaw(
        _ characters: [Character],
        openQuoteIndex: Int
    ) -> (raw: String, next: Int) {
        let quote = characters[openQuoteIndex]
        var raw = String(quote)
        var index = openQuoteIndex + 1

        while index < characters.count {
            let character = characters[index]
            raw.append(character)
            if character == "\\" {
                if index + 1 < characters.count {
                    raw.append(characters[index + 1])
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if character == quote {
                return (raw, index + 1)
            }
            index += 1
        }
        return (raw, index)
    }

    /// The content of a Lua string literal, or nil when the argument is not one.
    static func stringLiteralContent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let quote = trimmed.first,
              quote == "\"" || quote == "'",
              trimmed.last == quote else { return nil }

        let body = trimmed.dropFirst().dropLast()
        var output = ""
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character == "\\" {
                let next = body.index(after: index)
                guard next < body.endIndex else { break }
                output.append(body[next])
                index = body.index(after: next)
                continue
            }
            output.append(character)
            index = body.index(after: index)
        }
        return output
    }

    private static func longBracketLevel(_ characters: [Character], at index: Int) -> Int? {
        guard index < characters.count, characters[index] == "[" else { return nil }
        var cursor = index + 1
        var level = 0
        while cursor < characters.count, characters[cursor] == "=" {
            level += 1
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "[" else { return nil }
        return level
    }

    private static func range(of needle: String, in characters: [Character], from start: Int) -> Range<Int>? {
        let target = Array(needle)
        guard target.count > 0 else { return nil }
        var index = start
        while index + target.count <= characters.count {
            if matches(characters, at: index, target) { return index..<(index + target.count) }
            index += 1
        }
        return nil
    }
}
