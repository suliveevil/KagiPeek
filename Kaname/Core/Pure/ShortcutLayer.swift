import Foundation

/// Where in the macOS keyboard event stack a shortcut is hooked.
///
/// A keypress travels up a fairly well documented stack, and the first layer that
/// claims it usually swallows it before anything above ever sees it. Karabiner
/// rewrites the event inside a virtual keyboard driver, so it acts first; CGEvent
/// taps get the next look; then the system's own symbolic hotkeys; then global
/// Carbon hotkeys; and last of all the frontmost app's menu.
///
/// Ordering is by raw value: lower means earlier in the stack, which means more
/// likely to win.
///
/// It is a heuristic, not a promise. Two tools on the same layer are decided by
/// registration order, which no config file on disk records. Watching a real
/// keypress settles it, and that is what `ShortcutTester` is for.
nonisolated enum ShortcutLayer: Int, CaseIterable, Comparable, Codable, Sendable {
    /// Karabiner-Elements. Remaps in a virtual HID driver, below the OS.
    case driver = 0
    /// A CGEvent tap: skhd, BetterTouchTool, the Keyboard Maestro engine.
    case eventTap = 1
    /// A macOS symbolic hotkey.
    case system = 2
    /// A global hotkey registered with Carbon (Hammerspoon, Alfred).
    case globalHotKey = 3
    /// An always-on tool whose hook point we cannot tell from its config.
    case otherGlobal = 4
    /// An app menu item. Only live while that app is frontmost.
    case menuItem = 5

    static func < (lhs: ShortcutLayer, rhs: ShortcutLayer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // MARK: - Classification

    /// Maps a binding to its layer.
    ///
    /// Config-file bindings are the interesting case: the `.configFile` source lumps
    /// six very different tools together, so the tool decides, not the source.
    static func classify(_ item: BindingItem) -> ShortcutLayer {
        if let tool = item.configTool { return tool.layer }
        switch item.source {
        case .system: return .system
        case .menu, .builtIn, .user: return .menuItem
        case .configFile: return .otherGlobal
        }
    }

    /// Whether a binding on this layer listens all the time rather than only while
    /// its own app is frontmost.
    var isAlwaysOn: Bool { self != .menuItem }

    /// Whether this is the operating system's own shortcut layer.
    ///
    /// The conflict list needs this to tell "macOS is in the way" from "a tool you installed
    /// is in the way": both swallow the menu item, but the fix lives in different places —
    /// System Settings versus that tool's config.
    var isSystemLayer: Bool { self == .system }

    // MARK: - Display

    /// Short badge text for the conflict list.
    var badgeKey: L10nKey {
        switch self {
        case .driver: return .layerDriver
        case .eventTap: return .layerEventTap
        case .system: return .layerSystem
        case .globalHotKey: return .layerGlobalHotkey
        case .otherGlobal: return .layerGlobal
        case .menuItem: return .layerMenuItem
        }
    }

    /// One sentence on why this layer sits where it does. Shown as the reasoning
    /// behind the winner hint, so it has to make sense on its own.
    var explanationKey: L10nKey {
        switch self {
        case .driver: return .layerDriverExplanation
        case .eventTap: return .layerEventTapExplanation
        case .system: return .layerSystemExplanation
        case .globalHotKey: return .layerGlobalHotkeyExplanation
        case .otherGlobal: return .layerGlobalExplanation
        case .menuItem: return .layerMenuItemExplanation
        }
    }
}
