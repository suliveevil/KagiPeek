import XCTest
@testable import KanameCore

final class V21SettingsDefaultsTests: XCTestCase {
    func testPanelDefaults() {
        let settings = AppSettingsSnapshot()
        XCTAssertEqual(settings.panelPlacement, .coverWindow)
        XCTAssertEqual(settings.switchHotkey, .switchDefault)
        XCTAssertEqual(settings.fixedPanelWidth, 720)
    }

    func testPlacementRoundTrip() throws {
        var settings = AppSettingsSnapshot()
        settings.panelPlacement = .fillScreen
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
        XCTAssertEqual(decoded.panelPlacement, .fillScreen)
    }
}
