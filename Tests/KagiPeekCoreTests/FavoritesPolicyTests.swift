import XCTest
@testable import KagiPeekCore

/// The favorites rules that used to be two booleans passed into every rebuild and repeated
/// in two cache keys — now one value with named semantics.
final class FavoritesPolicyTests: XCTestCase {
    private struct Row: Equatable {
        let item: String
        let favorite: Bool

        init(_ title: String) {
            item = title
            favorite = title.hasPrefix("F")
        }
    }

    private func isFavorite(_ row: Row) -> Bool {
        row.favorite
    }

    /// The star toggle narrows to favorites; off, the rows pass through untouched.
    func testFavoritesOnlyNarrowsWhenOn() {
        var policy = FavoritesPolicy()
        policy.showsFavoritesOnly = true
        let rows = [Row("Copy"), Row("FCut"), Row("Paste"), Row("FPaste")]
        XCTAssertEqual(
            policy.favoritesOnly(rows, isFavorite: isFavorite).map(\.item),
            ["FCut", "FPaste"]
        )
    }

    func testFavoritesOnlyPassesThroughWhenOff() {
        let policy = FavoritesPolicy()
        let rows = [Row("Copy"), Row("FCut")]
        XCTAssertEqual(policy.favoritesOnly(rows, isFavorite: isFavorite), rows)
    }

    /// Pin-to-top moves favorites ahead of the rest, keeping each group's order.
    func testPinningFavoritesFirst() {
        var policy = FavoritesPolicy()
        policy.pinToTop = true
        let rows = [Row("Copy"), Row("FCut"), Row("Paste"), Row("FPaste")]
        XCTAssertEqual(
            policy.pinningFavoritesFirst(rows, isFavorite: isFavorite).map(\.item),
            ["FCut", "FPaste", "Copy", "Paste"]
        )
    }

    func testPinningOffKeepsTheOrder() {
        var policy = FavoritesPolicy()
        policy.pinToTop = false
        let rows = [Row("FCut"), Row("Copy")]
        XCTAssertEqual(policy.pinningFavoritesFirst(rows, isFavorite: isFavorite), rows)
    }

    /// The whole policy participates in equality, so a cache key holding it invalidates on
    /// any rule change — including the search-only `canBeFiltered`.
    func testEqualityCoversEveryRule() {
        XCTAssertEqual(FavoritesPolicy(), FavoritesPolicy())
        var different = FavoritesPolicy()
        different.canBeFiltered = true
        XCTAssertNotEqual(FavoritesPolicy(), different)
    }
}
