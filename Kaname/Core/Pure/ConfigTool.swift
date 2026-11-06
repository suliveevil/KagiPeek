import Foundation

/// A third-party keyboard tool whose shortcuts live in a config file rather than in
/// a menu bar or in the system's own hotkey table.
///
/// Kept as a value type so `BindingItem` can name the tool it came from without
/// pulling a scanner into the model, and so the layer it hooks belongs to the tool
/// rather than to whichever code happened to read the file.
nonisolated enum ConfigTool: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case karabiner
    case skhd
    case keyboardMaestro
    case betterTouchTool
    case hammerspoon
    case alfred

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .karabiner: return "Karabiner-Elements"
        case .skhd: return "skhd"
        case .keyboardMaestro: return "Keyboard Maestro"
        case .betterTouchTool: return "BetterTouchTool"
        case .hammerspoon: return "Hammerspoon"
        case .alfred: return "Alfred"
        }
    }

    /// Where in the event stack this tool hooks.
    ///
    /// This is the whole reason the layer model earns its keep: without config files
    /// there is nothing below `.system`, and "system beats menu" is the only answer
    /// available. With them, a Karabiner rule outranks everything macOS does.
    var layer: ShortcutLayer {
        switch self {
        case .karabiner: return .driver
        case .skhd, .betterTouchTool, .keyboardMaestro: return .eventTap
        case .hammerspoon, .alfred: return .globalHotKey
        }
    }

    /// Config locations to try, relative to the user's home directory.
    ///
    /// Every entry is a candidate, not a promise: a tool that is not installed simply
    /// has no file at these paths, and the scanner moves on.
    var relativeSearchPaths: [String] {
        switch self {
        case .karabiner:
            return [".config/karabiner/karabiner.json"]
        case .skhd:
            return [".config/skhd/skhdrc", ".skhdrc"]
        case .keyboardMaestro:
            return [
                "Library/Application Support/Keyboard Maestro/Keyboard Maestro Macros.plist"
            ]
        case .betterTouchTool:
            return ["Library/Application Support/BetterTouchTool"]
        case .hammerspoon:
            return [".hammerspoon/init.lua"]
        case .alfred:
            return [
                "Library/Application Support/Alfred/Alfred.alfredpreferences",
                "Library/Preferences/com.runningwithcrayons.Alfred-Preferences-3/Alfred.alfredpreferences",
                "Documents/Alfred.alfredpreferences"
            ]
        }
    }
}
