import XCTest
@testable import KagiPeekCore

/// Reading System Settings' own state without a TCC grant. Both parsers guard values that
/// only exist on some macOS versions, so the "no opinion" answers matter as much as the
/// positive ones: a wrong guess here would put a "you left this page" message on a panel
/// that is, in fact, pointing at the right page.
final class SettingsPaneProbeTests: XCTestCase {
    // MARK: - Which page is showing

    func testPrivacyExtensionCountsAsTheRightPage() {
        XCTAssertEqual(
            SettingsPaneProbe.privacyPageShown(inPaneURL: SettingsPaneProbe.privacyExtension),
            true
        )
    }

    func testAnotherExtensionCountsAsLeaving() {
        XCTAssertEqual(
            SettingsPaneProbe.privacyPageShown(inPaneURL: "com.apple.Displays-Settings.extension"),
            false
        )
    }

    func testLegacySecurityPaneIsStillRecognised() {
        XCTAssertEqual(
            SettingsPaneProbe.privacyPageShown(inPaneURL: "com.apple.preference.security?Privacy_Accessibility"),
            true
        )
    }

    func testMissingValueIsNoOpinionRatherThanAWrongAnswer() {
        XCTAssertNil(SettingsPaneProbe.privacyPageShown(inPaneURL: nil))
        XCTAssertNil(SettingsPaneProbe.privacyPageShown(inPaneURL: ""))
    }

    // MARK: - Sidebar width

    func testSidebarWidthComesFromTheFirstFrameRow() {
        let frame = "0.000000, 0.000000, 232.000000, 625.000000, NO, NO"
        XCTAssertEqual(SettingsPaneProbe.sidebarWidth(fromSplitFrame: frame), 232)
    }

    func testZeroOrMissingWidthIsNoOpinion() {
        XCTAssertNil(SettingsPaneProbe.sidebarWidth(fromSplitFrame: nil))
        XCTAssertNil(SettingsPaneProbe.sidebarWidth(fromSplitFrame: "0, 0, 0, 625, NO, NO"))
        XCTAssertNil(SettingsPaneProbe.sidebarWidth(fromSplitFrame: "not a frame"))
        XCTAssertNil(SettingsPaneProbe.sidebarWidth(fromSplitFrame: "0, 0"))
    }
}
