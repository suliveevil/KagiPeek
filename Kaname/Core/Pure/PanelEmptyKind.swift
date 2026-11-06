import Foundation

/// Which "nothing here" the panel is showing.
///
/// An empty panel and a scan that never happened look identical; so does a search with no
/// match and a permission prompt that never appeared. One enum, ordered by what the user
/// must deal with first, keeps the four messages from drifting apart.
nonisolated enum PanelEmptyKind: Equatable, Sendable {
    /// Accessibility permission is missing: nothing can be scanned, so this wins.
    case permissionRequired
    /// The scan is still running: the list will fill itself.
    case scanning
    /// Favorites-only is on and there are no favorites yet.
    case noFavorites
    /// The text, the prefix or the filters matched nothing.
    case noMatches

    /// Priority: permission > scanning > favorites > no match. A permission problem hides
    /// the scan's own "still working" message, because the scan can never finish without it.
    static func kind(
        isScanning: Bool,
        permissionDenied: Bool,
        showsFavoritesOnly: Bool,
        favoritesEmpty: Bool
    ) -> PanelEmptyKind {
        if permissionDenied { return .permissionRequired }
        if isScanning { return .scanning }
        if showsFavoritesOnly && favoritesEmpty { return .noFavorites }
        return .noMatches
    }

    var messageKey: L10nKey {
        switch self {
        case .permissionRequired: return .scanPermissionDenied
        case .scanning: return .overlayScanning
        case .noFavorites: return .panelNoFavorites
        case .noMatches: return .overlayNoCandidates
        }
    }
}
