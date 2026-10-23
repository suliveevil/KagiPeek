import Foundation

/// Names for the system-wide shortcuts macOS reports without one.
///
/// `CopySymbolicHotKeys` answers with a key code, a modifier mask and an enabled flag. It
/// also has a `kHISymbolicHotKeyDescription` field, but every entry on a current Mac leaves
/// it empty — the human name lives in System Settings, not in the API. Without a name the
/// panel had nothing to print in the title column and fell back to the shortcut itself, so a
/// row read "⌘M … ⌘M": a description that only repeated the key.
///
/// These are the assignments a stock Mac ships with, keyed by the chord. Two deliberate
/// limits:
///
/// - **Only the ones that can be named honestly.** A chord the user reassigned is no longer
///   in the table and keeps the shortcut as its label; a wrong name is worse than none.
/// - **Window and app shortcuts are included** (⌘M, ⌘⌥M, ⌘`, ⌘Tab): macOS registers them as
///   symbolic hotkeys too, which is why they appear in this list at all.
enum SystemHotkeyNames {
    struct Entry {
        let modifiers: ModifierSet
        let key: String
        let english: String
        let chinese: String
    }

    /// Sorted for reading, not for lookup: `chordKey` is what the dictionary uses.
    static let entries: [Entry] = [
        // Spotlight and input
        .init(modifiers: [.command], key: "space", english: "Spotlight", chinese: "聚焦搜索"),
        .init(modifiers: [.command, .option], key: "space", english: "Finder search window", chinese: "Finder 搜索窗口"),
        .init(modifiers: [.control], key: "space", english: "Select input source", chinese: "切换输入法"),
        .init(modifiers: [.control, .command], key: "space", english: "Emoji & Symbols", chinese: "表情与符号"),
        // Mission Control and spaces
        .init(modifiers: [.control], key: "up", english: "Mission Control", chinese: "调度中心"),
        .init(modifiers: [.control], key: "down", english: "Application windows", chinese: "应用窗口"),
        .init(modifiers: [.control], key: "left", english: "Move left a space", chinese: "左边一个空间"),
        .init(modifiers: [.control], key: "right", english: "Move right a space", chinese: "右边一个空间"),
        // Screenshots
        .init(modifiers: [.command, .shift], key: "3", english: "Screenshot", chinese: "截屏"),
        .init(modifiers: [.command, .shift], key: "4", english: "Screenshot selection", chinese: "截屏（区域）"),
        .init(modifiers: [.command, .shift], key: "5", english: "Screenshot toolbar", chinese: "截屏（工具栏）"),
        .init(modifiers: [.command, .shift], key: "6", english: "Screenshot Touch Bar", chinese: "截屏（触控栏）"),
        .init(modifiers: [.control, .command, .shift], key: "3", english: "Screenshot to clipboard", chinese: "截屏并拷贝"),
        .init(modifiers: [.control, .command, .shift], key: "4", english: "Screenshot selection to clipboard", chinese: "截屏（区域）并拷贝"),
        // Session
        .init(modifiers: [.control, .command], key: "q", english: "Lock Screen", chinese: "锁定屏幕"),
        .init(modifiers: [.command, .shift], key: "q", english: "Log Out…", chinese: "退出登录…"),
        .init(modifiers: [.command, .shift, .option, .control], key: "q", english: "Log Out Immediately", chinese: "立即退出登录"),
        // Apps and windows
        .init(modifiers: [.command], key: "tab", english: "Switch apps", chinese: "切换 App"),
        .init(modifiers: [.command, .shift], key: "tab", english: "Switch apps (backwards)", chinese: "反向切换 App"),
        .init(modifiers: [.command], key: "`", english: "Next window", chinese: "下一个窗口"),
        .init(modifiers: [.command, .shift], key: "`", english: "Previous window", chinese: "上一个窗口"),
        .init(modifiers: [.command], key: "m", english: "Minimize", chinese: "最小化"),
        .init(modifiers: [.command, .option], key: "m", english: "Minimize all", chinese: "全部最小化"),
        .init(modifiers: [.command, .option], key: "esc", english: "Force Quit", chinese: "强制退出"),
        // Menus and focus
        .init(modifiers: [.command, .shift], key: "/", english: "Help menu", chinese: "帮助菜单"),
        .init(modifiers: [.control, .command], key: "d", english: "Look up in Dictionary", chinese: "查词典"),
        .init(modifiers: [.control], key: "f2", english: "Focus the menu bar", chinese: "聚焦菜单栏"),
        .init(modifiers: [.control], key: "f3", english: "Focus the Dock", chinese: "聚焦程序坞"),
        .init(modifiers: [.control], key: "f8", english: "Focus the menu bar extras", chinese: "聚焦菜单栏状态项")
    ]

    /// The name of `chord`, or nil when this chord is not one macOS ships with.
    ///
    /// Nil is an answer: the caller prints the shortcut itself, which is what the row's key
    /// column already shows but is at least true for a chord that was reassigned.
    static func name(for chord: KeyChord, language: AppLanguage) -> String? {
        // A sequence (⌘K then ⌘S) is not any of these: the table describes single presses, and
        // matching only its first step would hand a sequence the name of an unrelated shortcut.
        guard chord.steps.count == 1, let step = chord.steps.first else { return nil }
        guard let entry = lookup[chordKey(modifiers: step.modifiers, key: step.key)] else { return nil }
        return language == .chinese ? entry.chinese : entry.english
    }

    private static func chordKey(modifiers: ModifierSet, key: KeyToken?) -> String {
        "\(modifiers.rawValue):\(key?.raw ?? "-")"
    }

    private static let lookup: [String: Entry] = {
        var table: [String: Entry] = [:]
        for entry in entries {
            table[chordKey(modifiers: entry.modifiers, key: KeyToken(entry.key))] = entry
        }
        return table
    }()
}
