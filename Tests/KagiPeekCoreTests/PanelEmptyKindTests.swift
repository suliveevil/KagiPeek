import XCTest
@testable import KagiPeekCore

final class PanelEmptyKindTests: XCTestCase {
    /// A missing permission outranks the scan spinner: waiting cannot fix it.
    func testPermissionWinsOverScanning() {
        XCTAssertEqual(
            PanelEmptyKind.kind(
                isScanning: true,
                permissionDenied: true,
                showsFavoritesOnly: false,
                favoritesEmpty: false
            ),
            .permissionRequired
        )
    }

    /// A running scan outranks "no match": the list has not finished filling.
    func testScanningOutranksNoMatches() {
        XCTAssertEqual(
            PanelEmptyKind.kind(
                isScanning: true,
                permissionDenied: false,
                showsFavoritesOnly: false,
                favoritesEmpty: false
            ),
            .scanning
        )
    }

    /// Favorites-only with nothing pinned says so, instead of claiming the app has no items.
    func testFavoritesOnlyWithNoFavorites() {
        XCTAssertEqual(
            PanelEmptyKind.kind(
                isScanning: false,
                permissionDenied: false,
                showsFavoritesOnly: true,
                favoritesEmpty: true
            ),
            .noFavorites
        )
    }

    /// Everything ready and still nothing: an honest no-match.
    func testReadyAndEmptyIsNoMatches() {
        XCTAssertEqual(
            PanelEmptyKind.kind(
                isScanning: false,
                permissionDenied: false,
                showsFavoritesOnly: true,
                favoritesEmpty: false
            ),
            .noMatches
        )
        XCTAssertEqual(
            PanelEmptyKind.kind(
                isScanning: false,
                permissionDenied: false,
                showsFavoritesOnly: false,
                favoritesEmpty: false
            ),
            .noMatches
        )
    }

    /// Each kind names the message it draws, so the view has no second mapping to keep.
    func testEachKindHasItsMessage() {
        XCTAssertEqual(PanelEmptyKind.scanning.messageKey, .overlayScanning)
        XCTAssertEqual(PanelEmptyKind.permissionRequired.messageKey, .scanPermissionDenied)
        XCTAssertEqual(PanelEmptyKind.noFavorites.messageKey, .panelNoFavorites)
        XCTAssertEqual(PanelEmptyKind.noMatches.messageKey, .overlayNoCandidates)
    }
}
