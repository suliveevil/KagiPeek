import Foundation

enum KeyPosition: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case right

    var titleKey: L10nKey {
        switch self {
        case .left: return .keyPositionLeft
        case .right: return .keyPositionRight
        }
    }
}

/// What a row key does in the panel.
///
/// Both surfaces take the keyboard, so "execute" closes the surface and replays the chord
/// into the app that should receive it, while "copy" leaves the surface open and only
/// touches the pasteboard. Which physical key asks for which action is a recorded binding
/// (`runRowKey` / `copyRowKey`), not a hard-coded Return.
enum RowAction: String, Codable, CaseIterable, Hashable, Sendable {
    case execute
    case copy
}

enum TriggerMode: String, Codable, CaseIterable, Hashable, Sendable {
    case holdModifiers
    case doubleTapCommand
    case hotkey
    case disabled

    var titleKey: L10nKey {
        switch self {
        case .holdModifiers: return .triggerHoldModifiers
        case .doubleTapCommand: return .triggerDoubleTap
        case .hotkey: return .triggerHotkey
        case .disabled: return .triggerOff
        }
    }
}

/// A recorded key binding: a global hotkey, or one of the two row keys.
///
/// The type is shared because both are "a virtual key plus a modifier set". The rules differ,
/// and they live with the recorder rather than here: a global hotkey must carry ⌘/⌥/⌃, while
/// a row key may be a bare Return but never a bare character (that would break chord entry
/// and filtering). See `ShortcutEngine.handleRecording`.
struct HotkeySpec: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: ModifierSet

    var chord: KeyChord {
        let token = KeyMapper.token(forKeyCode: keyCode) ?? KeyToken("key\(keyCode)")
        return .combo(modifiers, token)
    }

    /// Exact match, with Return and the keypad Enter treated as the same key: a laptop and a
    /// full-size keyboard should behave the same. Both directions follow, so a binding
    /// recorded on either one answers to the other.
    func matches(keyCode: UInt16, modifiers: ModifierSet) -> Bool {
        KeyAliases.enterCodes(for: self.keyCode).contains(keyCode) && modifiers == self.modifiers
    }

    /// Every (keyCode, modifiers) pair that should be swallowed while this binding is live.
    var capturedIdentifiers: [(keyCode: UInt16, modifiers: ModifierSet)] {
        KeyAliases.enterCodes(for: keyCode).map { (keyCode: $0, modifiers: modifiers) }
    }

    static let panelDefault = HotkeySpec(keyCode: 40, modifiers: [.control, .option, .command]) // ⌃⌥⌘K
    static let searchDefault = HotkeySpec(keyCode: 3, modifiers: [.control, .option, .command]) // ⌃⌥⌘F
    static let switchDefault = HotkeySpec(keyCode: 1, modifiers: [.control, .option, .command]) // ⌃⌥⌘S
    static let runRowDefault = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: []) // ↩
    static let copyRowDefault = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.command]) // ⌘↩
}

/// Persisted user settings. Missing keys fall back to defaults so upgrades never break.
struct AppSettingsSnapshot: Codable, Equatable, Sendable {
    var triggerMode: TriggerMode = .holdModifiers
    var holdDelay: Double = 0.5
    var doubleTapWindow: Double = 0.3
    var panelHotkey: HotkeySpec = .panelDefault
    var searchHotkey: HotkeySpec = .searchDefault
    var switchHotkey: HotkeySpec = .switchDefault
    var panelPlacement: PanelPlacement = .coverWindow
    var fixedPanelWidth: Double = 720
    var fixedPanelHeight: Double = 620
    var showExecutedHUD: Bool = true
    var keyStyle: KeyFormatter.Style = .symbols
    var columnCount: Int = 2
    var maxItemsPerPage: Int = 24
    var maxDescriptionLength: Int = 30
    var showDisabledItems: Bool = true
    var includeBuiltInCatalog: Bool = true
    /// Scan the Apple menu too. Off by default: its items belong to the system, not to the
    /// app in front, and would pad every list with commands the app does not own.
    var showAppleMenu: Bool = false

    var sortMode: RankMode = .smart
    var language: AppLanguage = .system
    var excludedBundleIDs: [String] = []
    var launchAtLogin: Bool = false
    var ignoredCommands: [IgnoredCommand] = []
    var panelTheme: PanelTheme = .graphite
    var keyPosition: KeyPosition = .right
    var pinFavoritesToTop: Bool = true
    var favoritesCanBeFiltered: Bool = false
    var runRowKey: HotkeySpec = .runRowDefault
    var copyRowKey: HotkeySpec = .copyRowDefault
    /// Whether the third-party config scanners run. Off means no file outside KagiPeek's
    /// own data folder is ever opened.
    var scanConfigFiles: Bool = true
    /// Whether diagnostics are written to `Application Support/KagiPeek/logs`. On by default:
    /// a bug report without logs is a guess, and the data never leaves the machine.
    var diagnosticsEnabled: Bool = true
    /// Include verbose/debug lines in the file log. Off by default: those levels cover
    /// high-frequency paths and exist for a directed investigation, not for daily use.
    var verboseDiagnostics: Bool = false
    /// Show a Dock icon as well as the menu bar item.
    ///
    /// Off by default — this is a menu bar app. It exists as an escape hatch for the case
    /// where a menu bar manager (Thaw, Ice, Bartender…) keeps swallowing the item: the Dock
    /// icon is a second door into the same settings, and it cannot be captured.
    var showDockIcon: Bool = false

    /// Bumped when a stored payload needs a rewrite. Version 3 removed `allowSearchExecute`
    /// after version 2 removed `allowPanelExecute`; both were plain deletions, so a file from
    /// either version still decodes (see `SettingsMigrator`).
    static let currentSchemaVersion = 3

    init() {}

    private enum CodingKeys: String, CodingKey {
        case triggerMode, holdDelay, doubleTapWindow, panelHotkey, searchHotkey, switchHotkey
        case showExecutedHUD, keyStyle, columnCount, maxItemsPerPage, maxDescriptionLength
        case showDisabledItems, includeBuiltInCatalog, sortMode, language
        case showAppleMenu
        case panelPlacement, fixedPanelWidth, fixedPanelHeight
        case excludedBundleIDs, launchAtLogin
        case ignoredCommands
        case panelTheme, keyPosition, pinFavoritesToTop, favoritesCanBeFiltered
        case runRowKey, copyRowKey, scanConfigFiles
        case diagnosticsEnabled, verboseDiagnostics, showDockIcon
    }

    /// Keys that exist only in older payloads. Kept out of `CodingKeys` on purpose: a key
    /// there would have to map to a property, and these are read once and never written back.
    private enum LegacyKeys: String, CodingKey {
        /// The pre-2.3 field: a flat list of titles that applied to every app.
        case ignoredCommandTitles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettingsSnapshot()
        // One line per field: a missing key keeps the default, so an older payload always
        // decodes and the next save drops the keys this build no longer has.
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        triggerMode = try decode(.triggerMode, fallback.triggerMode)
        holdDelay = try decode(.holdDelay, fallback.holdDelay)
        doubleTapWindow = try decode(.doubleTapWindow, fallback.doubleTapWindow)
        panelHotkey = try decode(.panelHotkey, fallback.panelHotkey)
        searchHotkey = try decode(.searchHotkey, fallback.searchHotkey)
        switchHotkey = try decode(.switchHotkey, fallback.switchHotkey)
        showExecutedHUD = try decode(.showExecutedHUD, fallback.showExecutedHUD)
        keyStyle = try decode(.keyStyle, fallback.keyStyle)
        columnCount = try decode(.columnCount, fallback.columnCount)
        maxItemsPerPage = try decode(.maxItemsPerPage, fallback.maxItemsPerPage)
        maxDescriptionLength = try decode(.maxDescriptionLength, fallback.maxDescriptionLength)
        showDisabledItems = try decode(.showDisabledItems, fallback.showDisabledItems)
        includeBuiltInCatalog = try decode(.includeBuiltInCatalog, fallback.includeBuiltInCatalog)
        showAppleMenu = try decode(.showAppleMenu, fallback.showAppleMenu)
        panelPlacement = try decode(.panelPlacement, fallback.panelPlacement)
        fixedPanelWidth = try decode(.fixedPanelWidth, fallback.fixedPanelWidth)
        fixedPanelHeight = try decode(.fixedPanelHeight, fallback.fixedPanelHeight)
        sortMode = try decode(.sortMode, fallback.sortMode)
        language = try decode(.language, fallback.language)
        excludedBundleIDs = try decode(.excludedBundleIDs, fallback.excludedBundleIDs)
        launchAtLogin = try decode(.launchAtLogin, fallback.launchAtLogin)
        if let stored = try container.decodeIfPresent([IgnoredCommand].self, forKey: .ignoredCommands) {
            ignoredCommands = stored
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent([String].self, forKey: .ignoredCommandTitles) {
            // Every old rule was global: keep that meaning instead of dropping the list.
            ignoredCommands = legacy.map { IgnoredCommand(title: $0, appBundleID: nil) }
        } else {
            ignoredCommands = fallback.ignoredCommands
        }
        panelTheme = try decode(.panelTheme, fallback.panelTheme)
        keyPosition = try decode(.keyPosition, fallback.keyPosition)
        pinFavoritesToTop = try decode(.pinFavoritesToTop, fallback.pinFavoritesToTop)
        favoritesCanBeFiltered = try decode(.favoritesCanBeFiltered, fallback.favoritesCanBeFiltered)
        runRowKey = try decode(.runRowKey, fallback.runRowKey)
        copyRowKey = try decode(.copyRowKey, fallback.copyRowKey)
        scanConfigFiles = try decode(.scanConfigFiles, fallback.scanConfigFiles)
        diagnosticsEnabled = try decode(.diagnosticsEnabled, fallback.diagnosticsEnabled)
        verboseDiagnostics = try decode(.verboseDiagnostics, fallback.verboseDiagnostics)
        showDockIcon = try decode(.showDockIcon, fallback.showDockIcon)
    }

    /// Persisted values are clamped back into these bounds. They are the same ranges the
    /// settings UI offers, so normalization can never disagree with the picker that set them.
    private enum Bounds {
        static let holdDelay: ClosedRange<Double> = 0.1...1.5
        static let doubleTapWindow: ClosedRange<Double> = 0.15...0.8
        static let fixedPanelWidth: ClosedRange<Double> = 320...4000
        static let fixedPanelHeight: ClosedRange<Double> = 240...3000
        static let columnCount: ClosedRange<Int> = 1...3
        static let maxItemsPerPage: ClosedRange<Int> = 6...60
        static let maxDescriptionLength: ClosedRange<Int> = 8...80
    }

    private func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Keeps persisted values inside sane bounds.
    func normalized() -> AppSettingsSnapshot {
        var copy = self
        copy.holdDelay = clamp(copy.holdDelay, to: Bounds.holdDelay)
        copy.doubleTapWindow = clamp(copy.doubleTapWindow, to: Bounds.doubleTapWindow)
        copy.fixedPanelWidth = clamp(copy.fixedPanelWidth, to: Bounds.fixedPanelWidth)
        copy.fixedPanelHeight = clamp(copy.fixedPanelHeight, to: Bounds.fixedPanelHeight)
        copy.columnCount = clamp(copy.columnCount, to: Bounds.columnCount)
        copy.maxItemsPerPage = clamp(copy.maxItemsPerPage, to: Bounds.maxItemsPerPage)
        copy.maxDescriptionLength = clamp(copy.maxDescriptionLength, to: Bounds.maxDescriptionLength)
        copy.excludedBundleIDs = copy.excludedBundleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        copy.ignoredCommands = IgnoredCommands.normalized(copy.ignoredCommands)
        return copy
    }
}
