import Foundation

/// The favorites rules that feed ranking, row budgeting and search, as one value.
///
/// The engine used to pass `showsFavoritesOnly` and the two settings (`pinFavoritesToTop`,
/// `favoritesCanBeFiltered`) into every rebuild separately, and each cache key repeated two
/// of them as independent booleans — a third boolean in one place that a second place
/// forgot is exactly the drift booleans invite. One value means a cache key can hold the
/// whole policy and a rebuild reads a single source of truth.
struct FavoritesPolicy: Equatable {
    /// The user narrowed the panel/palette to favorites only (the star toggle).
    var showsFavoritesOnly: Bool = false
    /// Settings: favorite rows come before the rest in the final order.
    var pinToTop: Bool = true
    /// Settings: favorites may surface in search results even when they would not match.
    var canBeFiltered: Bool = false

    /// Rows narrowed to favorites only, unchanged when the filter is off.
    func favoritesOnly<T>(_ rows: [T], isFavorite: (T) -> Bool) -> [T] {
        showsFavoritesOnly ? rows.filter(isFavorite) : rows
    }

    /// The same rows reordered with favorites first, unchanged when pinning is off.
    func pinningFavoritesFirst<T>(_ rows: [T], isFavorite: (T) -> Bool) -> [T] {
        guard pinToTop else { return rows }
        let favorites = rows.filter(isFavorite)
        let rest = rows.filter { !isFavorite($0) }
        return favorites + rest
    }
}
