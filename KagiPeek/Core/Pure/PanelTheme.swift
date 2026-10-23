import Foundation

/// Look of the floating shortcut panel.
enum PanelTheme: String, Codable, CaseIterable, Hashable, Sendable {
    case graphite
    case midnight
    case paper

    var titleKey: L10nKey {
        switch self {
        case .graphite: return .themeGraphite
        case .midnight: return .themeMidnight
        case .paper: return .themePaper
        }
    }
}
