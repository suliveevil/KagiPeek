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
}
