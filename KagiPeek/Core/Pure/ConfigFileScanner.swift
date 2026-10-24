import Foundation

/// One shortcut read out of a config file, before it becomes a `BindingItem`.
///
/// Scanners produce this and nothing else: it keeps them free of the id, usage-key
/// and localisation rules a `BindingItem` carries, so a parser test can assert on a
/// chord and a label without building a model first.
nonisolated struct ConfigBinding: Hashable, Sendable {
    var chord: KeyChord
    var title: String
}

/// What one config scan found.
struct ConfigScanResult: Sendable, Equatable {
    var items: [BindingItem] = []
    /// How many shortcuts each tool contributed, including the ones that came back empty.
    var counts: [ConfigTool: Int] = [:]
    /// Tools whose file exists but could not be read or parsed.
    var unreadable: Set<ConfigTool> = []
    var scannedAt = Date()

    var totalCount: Int { items.count }
}

/// Reads the shortcut definitions third-party keyboard tools keep in config files.
///
/// These matter for a reason a menu scan cannot see: every tool here hooks the keyboard
/// *below* where an app's menu lives, and most of them can swallow a key before the app
/// ever knows it was pressed. A conflict list without them can only say "two things want
/// ⌘⇧4", never "⌘⇧4 will never reach Safari".
///
/// Every scanner is split the same way: a pure `parse` that takes text, data or a decoded
/// plist, and a `scan` that finds the file on disk and hands it over. That split is what
/// makes the parsers testable with a fixture instead of a real `~/.config`.
enum ConfigFileScanner {

    /// Upper bound on a config file we are willing to read into memory. A corrupted file
    /// or a symlink to something enormous must not become an unbounded allocation.
    static let maxConfigBytes = 50 * 1024 * 1024

    /// The function-key row, spelled the same in every tool's grammar. One table so three
    /// scanners cannot drift into three different spellings of "f13".
    static let functionKeyNames: [String: KeyToken] = [
        "f1": "f1", "f2": "f2", "f3": "f3", "f4": "f4", "f5": "f5",
        "f6": "f6", "f7": "f7", "f8": "f8", "f9": "f9", "f10": "f10",
        "f11": "f11", "f12": "f12", "f13": "f13", "f14": "f14", "f15": "f15",
        "f16": "f16", "f17": "f17", "f18": "f18", "f19": "f19", "f20": "f20"
    ]

    // MARK: - Scanning

    static func scan(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        tools: [ConfigTool] = ConfigTool.allCases
    ) -> ConfigScanResult {
        var result = ConfigScanResult()
        for tool in tools {
            let bindings = bindings(for: tool, homeDirectory: homeDirectory)
            result.counts[tool] = bindings.count
            result.items.append(contentsOf: bindings.map { Self.item($0, tool: tool) })
        }
        result.scannedAt = Date()
        return result
    }

    static func bindings(for tool: ConfigTool, homeDirectory: URL) -> [ConfigBinding] {
        switch tool {
        case .karabiner:
            return KarabinerScanner.scan(homeDirectory: homeDirectory)
        case .skhd:
            return SkhdScanner.scan(homeDirectory: homeDirectory)
        case .keyboardMaestro:
            return KeyboardMaestroScanner.scan(homeDirectory: homeDirectory)
        case .betterTouchTool:
            return BetterTouchToolScanner.scan(homeDirectory: homeDirectory)
        case .hammerspoon:
            return HammerspoonScanner.scan(homeDirectory: homeDirectory)
        case .alfred:
            return AlfredScanner.scan(homeDirectory: homeDirectory)
        }
    }

    // MARK: - Building items

    /// Turns a parsed binding into a `BindingItem` owned by its tool.
    ///
    /// The group is the tool's name because that is the only heading that tells the user
    /// where the row came from; a config binding has no menu path to sit under.
    static func item(_ binding: ConfigBinding, tool: ConfigTool) -> BindingItem {
        BindingItem(
            chord: binding.chord,
            title: binding.title,
            group: [tool.displayName],
            isEnabled: true,
            source: .configFile,
            appBundleID: nil,
            configTool: tool
        )
    }

    // MARK: - File access

    /// First existing path among a tool's candidates, resolved against the home directory.
    static func firstExistingPath(
        _ candidates: [String],
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> String? {
        for candidate in candidates {
            let path = homeDirectory.appendingPathComponent(candidate).path
            if fileManager.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Reads a file, refusing anything past `maxConfigBytes`.
    static func readData(
        atPath path: String,
        limit: Int = maxConfigBytes,
        fileManager: FileManager = .default
    ) -> Data? {
        if let attributes = try? fileManager.attributesOfItem(atPath: path),
           let size = attributes[.size] as? Int,
           size > limit {
            return nil
        }
        return fileManager.contents(atPath: path)
    }

    static func readText(
        atPath path: String,
        limit: Int = maxConfigBytes,
        fileManager: FileManager = .default
    ) -> String? {
        guard let data = readData(atPath: path, limit: limit, fileManager: fileManager) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes a property list, tolerating a file that is not one.
    static func propertyList(from data: Data) -> Any? {
        try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    static func jsonObject(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Shared key names

    /// ANSI key names shared by several tools, mapped to KagiPeek's tokens.
    ///
    /// Every scanner has its own spelling for the named keys (Karabiner says
    /// `return_or_enter`, skhd says `return`), but they all agree on single characters,
    /// and that agreement is worth one table rather than five.
    static func token(forCharacter character: String) -> KeyToken? {
        guard character.count == 1 else { return nil }
        return characterKeyMap[character.lowercased()]
    }

    private static let characterKeyMap: [String: KeyToken] = [
        "a": "a", "s": "s", "d": "d", "f": "f", "h": "h", "g": "g",
        "z": "z", "x": "x", "c": "c", "v": "v", "b": "b", "q": "q",
        "w": "w", "e": "e", "r": "r", "y": "y", "t": "t",
        "o": "o", "u": "u", "i": "i", "p": "p", "l": "l",
        "j": "j", "k": "k", "n": "n", "m": "m",
        "1": "1", "2": "2", "3": "3", "4": "4", "5": "5",
        "6": "6", "7": "7", "8": "8", "9": "9", "0": "0",
        "-": "-", "=": "=", "[": "[", "]": "]",
        "\\": "\\", ";": ";", "'": "'",
        ",": ",", ".": ".", "/": "/", "`": "`"
    ]
}

// MARK: - Modifier masks

/// Carbon modifier masks, spelled out so the config scanners stay free of `import Carbon`.
///
/// Keyboard Maestro stores its triggers with exactly these bits, which is why they live
/// here rather than in any one scanner.
nonisolated enum CarbonModifierMask {
    static let command = 256
    static let shift = 512
    static let option = 2048
    static let control = 4096

    /// Converts a stored mask to KagiPeek's modifier set.
    static func modifierSet(fromCarbonMask mask: Int) -> ModifierSet {
        var modifiers: ModifierSet = []
        if mask & command != 0 { modifiers.insert(.command) }
        if mask & shift != 0 { modifiers.insert(.shift) }
        if mask & option != 0 { modifiers.insert(.option) }
        if mask & control != 0 { modifiers.insert(.control) }
        return modifiers
    }

    /// Converts the raw Cocoa modifier value Alfred and BetterTouchTool store, which is
    /// already `NSEvent.ModifierFlags`' own bit layout without the device-dependent bits.
    static func modifierSet(fromCocoaRawValue rawValue: Int) -> ModifierSet {
        var modifiers: ModifierSet = []
        if rawValue & (1 << 20) != 0 { modifiers.insert(.command) }   // NX_COMMANDMASK
        if rawValue & (1 << 17) != 0 { modifiers.insert(.shift) }     // NX_SHIFTMASK
        if rawValue & (1 << 19) != 0 { modifiers.insert(.option) }    // NX_ALTERNATEMASK
        if rawValue & (1 << 18) != 0 { modifiers.insert(.control) }   // NX_CONTROLMASK
        return modifiers
    }
}
