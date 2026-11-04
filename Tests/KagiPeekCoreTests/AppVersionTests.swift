import XCTest
@testable import KagiPeekCore

final class AppVersionTests: XCTestCase {
    func testVersionShowsCommitInsteadOfBuildNumber() {
        XCTAssertEqual(
            AppVersion.display(shortVersion: "2.2.0", commit: "66e5582"),
            "v2.2.0 (66e5582)"
        )
    }

    func testMissingCommitSaysUnknownRatherThanBuildNumber() {
        XCTAssertEqual(AppVersion.display(shortVersion: "2.2.0", commit: nil), "v2.2.0 (unknown)")
        XCTAssertEqual(AppVersion.display(shortVersion: "2.2.0", commit: ""), "v2.2.0 (unknown)")
        XCTAssertEqual(AppVersion.display(shortVersion: "2.2.0", commit: "   "), "v2.2.0 (unknown)")
    }

    func testLongHashIsShortenedToSevenCharacters() {
        XCTAssertEqual(
            AppVersion.display(
                shortVersion: "2.2.0",
                commit: "66e5582f94839433043bc8cdcb450eb4a8e6bfb0"
            ),
            "v2.2.0 (66e5582)"
        )
        XCTAssertEqual(AppVersion.shortCommit("66e5582f94839433043bc8cdcb450eb4a8e6bfb0"), "66e5582")
        XCTAssertEqual(AppVersion.shortCommit("abc"), "abc")
        XCTAssertNil(AppVersion.shortCommit(nil))
    }
}
