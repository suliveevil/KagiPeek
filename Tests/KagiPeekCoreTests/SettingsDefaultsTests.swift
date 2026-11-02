import XCTest
@testable import KagiPeekCore

final class SettingsDefaultsTests: XCTestCase {
    func testSmartIsDefault() {
        let settings = AppSettingsSnapshot()
        XCTAssertEqual(settings.sortMode, .smart)
        XCTAssertEqual(settings.runRowKey, .runRowDefault)
        XCTAssertEqual(settings.copyRowKey, .copyRowDefault)
    }

    func testDecodingOlderPayloadKeepsDefaults() throws {
        let json = "{\"triggerMode\":\"holdModifiers\",\"holdDelay\":0.4}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: json)
        XCTAssertEqual(decoded.holdDelay, 0.4)
        XCTAssertEqual(decoded.sortMode, .smart)
        XCTAssertEqual(decoded.runRowKey, .runRowDefault)
    }

    /// v2.1 wrote `allowPanelExecute`; the field is gone, so the stored payload must still
    /// decode and the row keys must fall back to their defaults.
    func testLegacyPayloadWithAllowPanelExecuteStillDecodes() throws {
        let json = """
        {"triggerMode":"hotkey","allowPanelExecute":true,"allowSearchExecute":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: json)
        XCTAssertEqual(decoded.triggerMode, .hotkey)
        XCTAssertEqual(decoded.runRowKey, .runRowDefault)
        XCTAssertEqual(decoded.copyRowKey, .copyRowDefault)
    }
}
