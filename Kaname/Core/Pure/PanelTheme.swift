import Foundation

/// Look of the floating shortcut panel: follow the system, or pin one appearance.
///
/// The panel used to ship three named looks (Graphite, Midnight, Paper). Two of them were
/// dark and one light, and the only real question a person answers is "does it follow the
/// system or not" — so the setting now asks that, and the two palettes behind it are the
/// light and dark ones that already existed.
nonisolated enum PanelTheme: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case light
    case dark

    var titleKey: L10nKey {
        switch self {
        case .system: return .themeSystem
        case .light: return .themeLight
        case .dark: return .themeDark
        }
    }

    /// Old settings wrote the three look names. They map onto the two appearances rather
    /// than falling back to the default: an existing user keeps the panel they were used to.
    /// Values this build does not know follow the system, which is also the default.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "paper":
            self = .light
        case "graphite", "midnight":
            self = .dark
        case "light":
            self = .light
        case "dark":
            self = .dark
        default:
            self = .system
        }
    }
}
