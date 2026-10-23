import Foundation

/// Where the hint panel is placed.
enum PanelPlacement: String, Codable, CaseIterable, Hashable, Sendable {
    /// Centered over the front window, at least as large as the window in both dimensions.
    case coverWindow
    /// User-defined size, centered on the screen.
    case fixedSize
    /// The whole visible screen.
    case fillScreen
    /// Next to the front window (the 1.x/2.0 behaviour).
    case besideWindow

    var titleKey: L10nKey {
        switch self {
        case .coverWindow: return .placementCoverWindow
        case .fixedSize: return .placementFixedSize
        case .fillScreen: return .placementFillScreen
        case .besideWindow: return .placementBesideWindow
        }
    }
}
