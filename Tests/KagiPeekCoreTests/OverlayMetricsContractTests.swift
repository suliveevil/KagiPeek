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

    /// The fill-screen page grows with the screen, but the configured limit is still an
    /// upper bound: a page never asks for more rows than the window can show.
    func testFillScreenPageSizeIsBoundedByTheScreenAndTheSetting() {
        // 16-inch MacBook Pro, visible frame: 1728 × 1050. The screen could hold far more
        // than 24, so the setting wins.
        XCTAssertEqual(
            OverlayMetrics.fillScreenPageSize(
                visibleFrame: CGSize(width: 1728, height: 1050),
                maxItemsPerPage: 24
            ),
            24
        )
        // A screen too small for even a full header and footer still shows one row.
        XCTAssertEqual(
            OverlayMetrics.fillScreenPageSize(
                visibleFrame: CGSize(width: 400, height: 100),
                maxItemsPerPage: 24
            ),
            1
        )
    }
}
