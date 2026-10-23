import Foundation

/// Where a binding was discovered.
enum BindingSource: String, Codable, Hashable, Sendable {
    /// Read from the frontmost app's menu bar through the Accessibility API.
    case menu
    /// One of the bundled fallback shortcuts.
    case builtIn
    /// A system-wide shortcut reported by Carbon (Spotlight, Mission Control, …).
    case system
    /// Reserved for user-defined entries.
    case user
    /// Read from a third-party tool's config file (Karabiner, skhd, …).
    case configFile
}

/// One discoverable shortcut.
struct BindingItem: Identifiable, Hashable, Codable, Sendable {
    /// Unique per (chord, group, title, source, app). Used as the SwiftUI identity.
    let id: String
    let chord: KeyChord
    /// Already cleaned for display.
    let title: String
    /// Menu path, e.g. `["File"]` or `["View", "Appearance"]`.
    let group: [String]
    let isEnabled: Bool
    let source: BindingSource
    let appBundleID: String?
    /// Where this row sits in the app's Accessibility menu tree, e.g. `"2,0,5"`.
    ///
    /// Two things need it. The id has to be unique, and a command with no shortcut has no
    /// chord to make it so — two entries can share a menu path and a title (dynamic menus
    /// repeat names), and a collision would silently merge their rows, their element and
    /// their click target. And the usage key has the same problem: keying every shortcut-less
    /// command of an app onto one empty chord would merge their statistics and favourites.
    let axPath: String?
    /// Which third-party tool a `.configFile` binding came from. Decides its layer, so
    /// it belongs on the item rather than beside the scanner that happened to read it.
    let configTool: ConfigTool?
    /// Stable key for usage statistics; independent of the localized title.
    let usageKey: String

    init(
        chord: KeyChord,
        title: String,
        group: [String],
        isEnabled: Bool = true,
        source: BindingSource,
        appBundleID: String? = nil,
        configTool: ConfigTool? = nil,
        axPath: String? = nil
    ) {
        let cleaned = DescriptionCleaner.clean(title)
        self.chord = chord
        self.title = cleaned
        self.group = group
        self.isEnabled = isEnabled
        self.source = source
        self.appBundleID = appBundleID
        self.configTool = configTool
        self.axPath = axPath
        // System hotkeys are global, so give them their own namespace instead of
        // sharing the generic "*" bucket with built-in fallback items. So do config
        // tools: they have no bundle ID, but they are just as much their own owner.
        self.usageKey = source == .system
            ? "system|\(chord.cacheKey)"
            : Self.makeUsageKey(
                chord: chord,
                appBundleID: appBundleID,
                configTool: configTool,
                axPath: axPath,
                path: group.joined(separator: "/") + "/" + cleaned
            )
        self.id = Self.makeID(
            chord: chord,
            title: cleaned,
            group: group,
            source: source,
            appBundleID: appBundleID,
            configTool: configTool,
            axPath: axPath
        )
    }

    static func makeUsageKey(
        chord: KeyChord,
        appBundleID: String?,
        configTool: ConfigTool? = nil,
        axPath: String? = nil,
        path: String = ""
    ) -> String {
        // A command with no shortcut has no chord to key on; its position in the menu is
        // the only identity that survives a rename.
        let owner = configTool?.rawValue ?? appBundleID ?? "*"
        let key = chord.isEmpty ? "path:\(axPath ?? path)" : chord.cacheKey
        return "\(owner)|\(key)"
    }

    static func makeID(
        chord: KeyChord,
        title: String,
        group: [String],
        source: BindingSource,
        appBundleID: String?,
        configTool: ConfigTool? = nil,
        axPath: String? = nil
    ) -> String {
        let owner = configTool?.rawValue ?? appBundleID ?? "*"
        return "\(owner)|\(chord.cacheKey)|\(group.joined(separator: "/"))|\(source.rawValue)|\(title)|\(axPath ?? "")"
    }

    /// The third-party tool a binding belongs to, when it has one.
    var toolDisplayName: String? { configTool?.displayName }

    /// First menu level, used as the panel's group heading.
    var displayGroup: String { group.first ?? "" }

    /// Deeper menu levels, shown as a subtitle when present.
    var subgroup: String? {
        guard group.count > 1 else { return nil }
        return group.dropFirst().joined(separator: " › ")
    }

    var isAppScoped: Bool { appBundleID != nil }
}
