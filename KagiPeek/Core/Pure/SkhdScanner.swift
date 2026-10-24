import Foundation

/// Reads skhd's `skhdrc`.
///
/// One line is `modifier - key : command`, or `mod + mod - key : command`. The split
/// happens on the *last* `" - "` because a key can itself contain a dash, and a line
/// without one is a bare key binding, which is not a shortcut.
///
/// Mode declarations (`::` and `mode < ...`) are skipped: a mode binding only fires after
/// another key has armed it, so listing it as a always-on conflict would be wrong.
nonisolated enum SkhdScanner {

    static func scan(homeDirectory: URL, fileManager: FileManager = .default) -> [ConfigBinding] {
        guard let path = ConfigFileScanner.firstExistingPath(
            ConfigTool.skhd.relativeSearchPaths,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) else { return [] }
        guard let text = ConfigFileScanner.readText(atPath: path, fileManager: fileManager) else { return [] }
        return bindings(from: text)
    }

    static func bindings(from text: String) -> [ConfigBinding] {
        var bindings: [ConfigBinding] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // A mode block: `modeName < binding : command` or a `::` declaration. Neither
            // is live until the mode is armed.
            if trimmed.contains("::") || trimmed.contains(" < ") { continue }

            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let hotkeyPart = String(trimmed[trimmed.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            let commandPart = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            guard let dash = hotkeyPart.range(of: " - ", options: .backwards) else { continue }
            let modifiersPart = String(hotkeyPart[hotkeyPart.startIndex..<dash.lowerBound])
            let keyPart = String(hotkeyPart[dash.upperBound...]).trimmingCharacters(in: .whitespaces)

            guard let token = token(forSkhdKey: keyPart) else { continue }
            let modifiers = Self.modifiers(from: modifiersPart)
            guard !modifiers.isEmpty else { continue }

            bindings.append(ConfigBinding(
                chord: .combo(modifiers, token),
                title: commandPart.isEmpty ? "skhd" : commandPart
            ))
        }
        return bindings
    }

    // MARK: - Pieces

    /// `hyper` and `meh` are skhd's own shorthands for three and four modifiers at once.
    /// Deliberately skhd's grammar ("+"-separated tokens with shorthands), not shared with
    /// the other alias tables — their inputs spell modifiers differently.
    static func modifiers(from text: String) -> ModifierSet {
        var modifiers: ModifierSet = []
        for token in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch token {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            case "hyper": modifiers.formUnion([.command, .option, .shift, .control])
            case "meh": modifiers.formUnion([.option, .shift, .control])
            default: break
            }
        }
        return modifiers
    }

    static func token(forSkhdKey name: String) -> KeyToken? {
        let lowered = name.lowercased()
        if let named = namedKeyMap[lowered] { return named }
        if lowered.count == 1 { return ConfigFileScanner.token(forCharacter: lowered) }
        return nil
    }

    private static let namedKeyMap: [String: KeyToken] = [
        "return": "return", "escape": "esc", "delete": "delete", "tab": "tab",
        "space": "space", "left": "left", "right": "right", "down": "down", "up": "up",
        "pageup": "pageup", "pagedown": "pagedown", "home": "home", "end": "end"
    ].merging(ConfigFileScanner.functionKeyNames) { current, _ in current }
}
