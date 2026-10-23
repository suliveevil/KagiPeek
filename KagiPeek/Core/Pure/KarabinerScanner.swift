import Foundation

/// Reads Karabiner-Elements' complex modifications.
///
/// Only `complex_modifications` rules are shortcuts. Simple modifications remap one key
/// to another (`caps_lock` → `escape`) and are not a chord anybody presses, so counting
/// them would fill the conflict list with entries that cannot clash.
///
/// A manipulator also has to declare at least one *mandatory* modifier. A bare `a` rule
/// fires on every press of that key, which is a remap wearing a shortcut's clothes, and
/// reporting it would claim a conflict with every menu item bound to that letter.
nonisolated enum KarabinerScanner {

    static func scan(homeDirectory: URL, fileManager: FileManager = .default) -> [ConfigBinding] {
        guard let path = ConfigFileScanner.firstExistingPath(
            ConfigTool.karabiner.relativeSearchPaths,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) else { return [] }
        guard let data = ConfigFileScanner.readData(atPath: path, fileManager: fileManager) else { return [] }
        return bindings(fromJSON: data)
    }

    static func bindings(fromJSON data: Data) -> [ConfigBinding] {
        guard let json = ConfigFileScanner.jsonObject(from: data),
              let profiles = json["profiles"] as? [[String: Any]] else { return [] }

        // The selected profile, or the first one when none is marked: Karabiner always
        // keeps one selected, but a hand-edited file need not say so.
        let profile = profiles.first { $0["selected"] as? Bool == true } ?? profiles.first
        guard let profile,
              let complex = profile["complex_modifications"] as? [String: Any],
              let rules = complex["rules"] as? [[String: Any]] else { return [] }

        var bindings: [ConfigBinding] = []
        for rule in rules {
            let description = rule["description"] as? String
            guard let manipulators = rule["manipulators"] as? [[String: Any]] else { continue }

            for manipulator in manipulators {
                guard let from = manipulator["from"] as? [String: Any],
                      let name = from["key_code"] as? String,
                      let token = token(forKarabinerKey: name),
                      let modifiers = mandatoryModifiers(in: from) else { continue }

                bindings.append(ConfigBinding(
                    chord: .combo(modifiers, token),
                    title: Self.title(for: description, fallback: manipulator["description"] as? String)
                ))
            }
        }
        return bindings
    }

    // MARK: - Pieces

    private static func mandatoryModifiers(in from: [String: Any]) -> ModifierSet? {
        guard let modifiers = from["modifiers"] as? [String: Any],
              let mandatory = modifiers["mandatory"] as? [String] else { return nil }
        var result: ModifierSet = []
        for name in mandatory {
            result.formUnion(Self.modifiers(forKarabinerModifier: name))
        }
        // An empty mandatory list is a bare-key remap, not a shortcut.
        return result.isEmpty ? nil : result
    }

    /// A rule with no description still needs a label; the chord itself is the honest one.
    private static func title(for description: String?, fallback: String?) -> String {
        let trimmed = (description ?? fallback)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return "Karabiner rule"
    }

    static func modifiers(forKarabinerModifier name: String) -> ModifierSet {
        switch name {
        case "command", "left_command", "right_command": return .command
        case "shift", "left_shift", "right_shift": return .shift
        case "option", "left_option", "right_option": return .option
        case "control", "left_control", "right_control": return .control
        default: return []
        }
    }

    /// Karabiner key names → KagiPeek tokens.
    ///
    /// The names are Karabiner's own (underscored, spelled out), so a single character
    /// falls through to the shared ANSI table rather than being listed twice.
    static func token(forKarabinerKey name: String) -> KeyToken? {
        let lowered = name.lowercased()
        if let named = namedKeyMap[lowered] { return named }
        if let character = ConfigFileScanner.token(forCharacter: lowered), lowered.count == 1 {
            return character
        }
        return nil
    }

    private static let namedKeyMap: [String: KeyToken] = [
        "return_or_enter": "return", "escape": "esc", "delete_or_backspace": "delete",
        "delete_forward": "fdelete", "tab": "tab", "spacebar": "space",
        "grave_accent_and_tilde": "`", "hyphen": "-", "equal_sign": "=",
        "open_bracket": "[", "close_bracket": "]", "backslash": "\\",
        "semicolon": ";", "quote": "'", "comma": ",", "period": ".", "slash": "/",
        "left_arrow": "left", "right_arrow": "right", "down_arrow": "down", "up_arrow": "up",
        "page_up": "pageup", "page_down": "pagedown", "home": "home", "end": "end",
        "f1": "f1", "f2": "f2", "f3": "f3", "f4": "f4", "f5": "f5",
        "f6": "f6", "f7": "f7", "f8": "f8", "f9": "f9", "f10": "f10",
        "f11": "f11", "f12": "f12", "f13": "f13", "f14": "f14", "f15": "f15",
        "f16": "f16", "f17": "f17", "f18": "f18", "f19": "f19", "f20": "f20"
    ]
}
