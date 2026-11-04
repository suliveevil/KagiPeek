import Foundation

nonisolated enum KeyPosition: String, Codable, CaseIterable, Hashable, Sendable {
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
nonisolated enum RowAction: String, Codable, CaseIterable, Hashable, Sendable {
    case execute
    case copy
}

/// The pre-v5 "trigger mode". Decoded only: `SettingsMigrator` turns it into the three v5
/// fields, and it is never written back.
nonisolated enum TriggerMode: String, Codable, CaseIterable, Hashable, Sendable {
    case holdModifiers
    case doubleTapCommand
    case hotkey
    case disabled
}

/// How the modifier gesture fires the panel.
nonisolated enum TriggerGesture: String, Codable, CaseIterable, Hashable, Sendable {
    case hold
    case doubleTap

    var titleKey: L10nKey {
        switch self {
        case .hold: return .triggerGestureHold
        case .doubleTap: return .triggerGestureDoubleTap
        }
    }
}

/// The single modifier that triggers the panel.
///
/// `ModifierSet` only knows which modifiers are down, not which side. The side comes from
/// `flagsChanged`'s key code, which is why each case carries its physical code.
nonisolated enum TriggerKey: String, Codable, CaseIterable, Hashable, Sendable {
    case anyModifier
    case leftControl
    case leftOption
    case leftCommand
    case rightCommand
    case rightOption

    var titleKey: L10nKey {
        switch self {
        case .anyModifier: return .triggerKeyAnyModifier
        case .leftControl: return .triggerKeyLeftControl
        case .leftOption: return .triggerKeyLeftOption
        case .leftCommand: return .triggerKeyLeftCommand
        case .rightCommand: return .triggerKeyRightCommand
        case .rightOption: return .triggerKeyRightOption
        }
    }

    /// The physical key this trigger answers to. `anyModifier` covers every non-Shift
    /// modifier: Shift alone is typing capitals, not a gesture.
    var keyCodes: Set<UInt16> {
        switch self {
        case .anyModifier: return [55, 54, 58, 61, 59, 62] // ⌘ ⌥ ⌃, both sides
        case .leftControl: return [59]
        case .leftOption: return [58]
        case .leftCommand: return [55]
        case .rightCommand: return [54]
        case .rightOption: return [61]
        }
    }

    var modifier: ModifierSet? {
        switch self {
        case .anyModifier: return nil
        case .leftControl: return .control
        case .leftOption, .rightOption: return .option
        case .leftCommand, .rightCommand: return .command
        }
    }

    /// True when this `flagsChanged` is a press of the trigger key.
    func isPressed(keyCode: UInt16, modifiers: ModifierSet) -> Bool {
        if let modifier {
            return keyCodes.contains(keyCode) && modifiers.contains(modifier)
        }
        return !modifiers.isEmpty && modifiers != [.shift]
    }

    /// Key codes the tap swallows while this trigger is live: the press and the release of
    /// the same physical key. Shift and Caps Lock stay available to the front app.
    var swallowedKeyCodes: Set<UInt16> { keyCodes }
}

/// A recorded key binding: a global hotkey, or one of the two row keys.
///
/// The type is shared because both are "a virtual key plus a modifier set". The rules differ,
/// and they live with the recorder rather than here: a global hotkey must carry ⌘/⌥/⌃, while
/// a row key may be a bare Return but never a bare character (that would break chord entry
/// and filtering). See `ShortcutEngine.handleRecording`.
nonisolated struct HotkeySpec: Codable, Hashable, Sendable {
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
    /// Space runs a row and Return copies it: the two keys a person already uses on a
    /// selected item, and the pair the draft asks for.
    static let runRowDefault = HotkeySpec(keyCode: KeyCode.space, modifiers: []) // Space
    static let copyRowDefault = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: []) // ↩

    /// The pair this build shipped before the row keys moved to Space/Return. A stored pair
    /// that still matches both exactly is migrated; anything recorded by hand wins.
    static let legacyRunRowDefault = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: []) // ↩
    static let legacyCopyRowDefault = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.command]) // ⌘↩
}

/// Persisted user settings. Missing keys fall back to defaults so upgrades never break.
nonisolated struct AppSettingsSnapshot: Codable, Equatable, Sendable {
    /// Legacy field: read once by `SettingsMigrator`, then cleared. Never written back.
    var triggerMode: TriggerMode? = nil
    /// Whether the modifier gesture is live. Independent of `hotkeyTriggerEnabled`.
    var modifierTriggerEnabled: Bool = true
    /// Whether the three global hotkeys are live. Independent of the modifier gesture:
    /// both on is fine, one on is fine, and both off is the pause state.
    var hotkeyTriggerEnabled: Bool = true
    var triggerGesture: TriggerGesture = .hold
    var triggerKey: TriggerKey = .rightCommand
    var holdDelay: Double = 0.5
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
    var panelTheme: PanelTheme = .system
    var keyPosition: KeyPosition = .right
    /// How the panel lists menu items: by shortcut (the reference-card default) or grouped
    /// by top-level menu. Changing it reorders an open panel without rescanning.
    var panelOrder: PanelSortOrder = .byModifier
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
    /// either version still decodes. Version 4 moves the default row keys to Space/Return, so
    /// that one rewrites a value (see `SettingsMigrator`). Version 5 replaces `triggerMode`
    /// with `modifierTriggerEnabled` / `triggerGesture` / `triggerKey`; the old key is read
    /// and never written back. Version 6 adds `panelOrder`; a v5 file has no key, so the
    /// default (`byModifier`) applies without a rewrite. Version 7 removes `doubleTapWindow`:
    /// the double-tap window now follows the system double-click speed, so an old value is
    /// ignored and disappears on the next save.
    static let currentSchemaVersion = 7

    init() {}

    private enum CodingKeys: String, CodingKey {
        case triggerMode, modifierTriggerEnabled, hotkeyTriggerEnabled, triggerGesture, triggerKey
        case holdDelay, panelHotkey, searchHotkey, switchHotkey
        case showExecutedHUD, keyStyle, columnCount, maxItemsPerPage, maxDescriptionLength
        case showDisabledItems, includeBuiltInCatalog, sortMode, language
        case showAppleMenu
        case panelPlacement, fixedPanelWidth, fixedPanelHeight
        case excludedBundleIDs, launchAtLogin
        case ignoredCommands
        case panelTheme, keyPosition, panelOrder, pinFavoritesToTop, favoritesCanBeFiltered
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
        // A legacy value this build does not know must not fail the whole file: only the
        // trigger mapping is lost, and the v5 defaults take over.
        if let legacy = try? container.decodeIfPresent(TriggerMode.self, forKey: .triggerMode) {
            triggerMode = legacy
        }
        modifierTriggerEnabled = try decode(.modifierTriggerEnabled, fallback.modifierTriggerEnabled)
        hotkeyTriggerEnabled = try decode(.hotkeyTriggerEnabled, fallback.hotkeyTriggerEnabled)
        triggerGesture = try decode(.triggerGesture, fallback.triggerGesture)
        triggerKey = try decode(.triggerKey, fallback.triggerKey)
        holdDelay = try decode(.holdDelay, fallback.holdDelay)
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
        panelOrder = try decode(.panelOrder, fallback.panelOrder)
        pinFavoritesToTop = try decode(.pinFavoritesToTop, fallback.pinFavoritesToTop)
        favoritesCanBeFiltered = try decode(.favoritesCanBeFiltered, fallback.favoritesCanBeFiltered)
        runRowKey = try decode(.runRowKey, fallback.runRowKey)
        copyRowKey = try decode(.copyRowKey, fallback.copyRowKey)
        scanConfigFiles = try decode(.scanConfigFiles, fallback.scanConfigFiles)
        diagnosticsEnabled = try decode(.diagnosticsEnabled, fallback.diagnosticsEnabled)
        verboseDiagnostics = try decode(.verboseDiagnostics, fallback.verboseDiagnostics)
        showDockIcon = try decode(.showDockIcon, fallback.showDockIcon)
    }

    /// Written by hand only to leave out `triggerMode`: the synthesized encoder would write
    /// the legacy key as `null`, and a v5 file must not carry any trace of it.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modifierTriggerEnabled, forKey: .modifierTriggerEnabled)
        try container.encode(hotkeyTriggerEnabled, forKey: .hotkeyTriggerEnabled)
        try container.encode(triggerGesture, forKey: .triggerGesture)
        try container.encode(triggerKey, forKey: .triggerKey)
        try container.encode(holdDelay, forKey: .holdDelay)
        try container.encode(panelHotkey, forKey: .panelHotkey)
        try container.encode(searchHotkey, forKey: .searchHotkey)
        try container.encode(switchHotkey, forKey: .switchHotkey)
        try container.encode(showExecutedHUD, forKey: .showExecutedHUD)
        try container.encode(keyStyle, forKey: .keyStyle)
        try container.encode(columnCount, forKey: .columnCount)
        try container.encode(maxItemsPerPage, forKey: .maxItemsPerPage)
        try container.encode(maxDescriptionLength, forKey: .maxDescriptionLength)
        try container.encode(showDisabledItems, forKey: .showDisabledItems)
        try container.encode(includeBuiltInCatalog, forKey: .includeBuiltInCatalog)
        try container.encode(sortMode, forKey: .sortMode)
        try container.encode(language, forKey: .language)
        try container.encode(showAppleMenu, forKey: .showAppleMenu)
        try container.encode(panelPlacement, forKey: .panelPlacement)
        try container.encode(fixedPanelWidth, forKey: .fixedPanelWidth)
        try container.encode(fixedPanelHeight, forKey: .fixedPanelHeight)
        try container.encode(excludedBundleIDs, forKey: .excludedBundleIDs)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(ignoredCommands, forKey: .ignoredCommands)
        try container.encode(panelTheme, forKey: .panelTheme)
        try container.encode(keyPosition, forKey: .keyPosition)
        try container.encode(panelOrder, forKey: .panelOrder)
        try container.encode(pinFavoritesToTop, forKey: .pinFavoritesToTop)
        try container.encode(favoritesCanBeFiltered, forKey: .favoritesCanBeFiltered)
        try container.encode(runRowKey, forKey: .runRowKey)
        try container.encode(copyRowKey, forKey: .copyRowKey)
        try container.encode(scanConfigFiles, forKey: .scanConfigFiles)
        try container.encode(diagnosticsEnabled, forKey: .diagnosticsEnabled)
        try container.encode(verboseDiagnostics, forKey: .verboseDiagnostics)
        try container.encode(showDockIcon, forKey: .showDockIcon)
    }

    /// Persisted values are clamped back into these bounds. They are the same ranges the
    /// settings UI offers, so normalization can never disagree with the picker that set them.
    private enum Bounds {
        static let holdDelay: ClosedRange<Double> = 0.3...0.9
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
        // The settings UI steps `holdDelay` by 0.1. Rounding after the clamp drops the
        // binary tail (0.9000000000000001) before it reaches settings.json.
        copy.holdDelay = (clamp(copy.holdDelay, to: Bounds.holdDelay) * 10).rounded() / 10
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
