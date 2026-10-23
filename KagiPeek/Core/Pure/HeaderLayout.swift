import Foundation

/// How much of the panel title bar fits at a given width.
///
/// The panel can be as narrow as 300 pt (one column, beside the window) and as wide as the
/// screen. The chrome gives way in a fixed order — the result count first, then the
/// favourites toggle, the subtitle and the app name, and finally the search field shrinks —
/// while the settings and close buttons never leave. The thresholds are pure arithmetic, so
/// they live here instead of inside the view and can be tested.
enum HeaderLayout {
    case full
    case tight
    case minimal

    init(width: Double) {
        if width >= 600 {
            self = .full
        } else if width >= 460 {
            self = .tight
        } else {
            self = .minimal
        }
    }

    /// Preferred width of the search field.
    var fieldIdeal: Double {
        switch self {
        case .full: return 260
        case .tight: return 170
        case .minimal: return 110
        }
    }

    /// The field may shrink this far before the trailing buttons would be pushed out.
    var fieldMin: Double {
        switch self {
        case .full: return 120
        case .tight: return 90
        case .minimal: return 56
        }
    }

    /// Only the widest layout has room for the result count.
    var showsCount: Bool { self == .full }
    /// The favourites shortcut is the first control to go: rows carry the star as well.
    var showsFavoritesToggle: Bool { self != .minimal }
    /// The four modifier chips cost about 84 pt. They leave with the subtitle and the app
    /// name — below 460 pt the panel is a single column and needs the width for rows.
    var showsModifierFilter: Bool { self != .minimal }
    var showsAppName: Bool { self != .minimal }
    var showsSubtitle: Bool { self != .minimal }
}
