import XCTest
@testable import KagiPeekCore

final class OverlayMetricsContractTests: XCTestCase {
    func testNaturalWidthFitsTheRequestedColumnCount() {
        var settings = AppSettingsSnapshot()
        for columns in 1...4 {
            settings.columnCount = columns
            let size = OverlayMetrics.size(for: PanelState(), settings: settings)
            XCTAssertEqual(
                OverlayMetrics.columns(forWidth: size.width),
                columns,
                "natural width for \(columns) columns must not collapse to fewer columns"
            )
        }
    }

    /// The fill-screen page is the whole point of the mode: on a 16-inch display it must be
    /// several times the small-window limit, and it must never fall below that limit.
    func testFillScreenPageSizeGrowsWithTheScreen() {
        // 16-inch MacBook Pro, visible frame: 1728 × 1050. Four 300pt columns (the cap) of
        // thirty rows each — five times the 24-row limit the small window uses.
        XCTAssertEqual(
            OverlayMetrics.fillScreenPageSize(
                visibleFrame: CGSize(width: 1728, height: 1050),
                maxItemsPerPage: 24
            ),
            4 * 30,
            "four columns of thirty rows are what a full-screen page can hold"
        )
        // A screen too small for even one row still has to show the configured page.
        XCTAssertEqual(
            OverlayMetrics.fillScreenPageSize(
                visibleFrame: CGSize(width: 400, height: 100),
                maxItemsPerPage: 24
            ),
            24
        )
    }
}
