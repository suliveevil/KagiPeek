import XCTest
@testable import KagiPeekCore

final class SemanticVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(SemanticVersion("v1.2.0")?.description, "1.2.0")
        XCTAssertEqual(SemanticVersion("2")?.description, "2.0.0")
        XCTAssertEqual(SemanticVersion("1.2.3-beta.1")?.description, "1.2.3")
        XCTAssertNil(SemanticVersion("latest"))
    }

    func testComparison() {
        let old = SemanticVersion("1.2.0")!
        let new = SemanticVersion("2.0.0")!
        XCTAssertTrue(old < new)
        XCTAssertFalse(new < old)
        XCTAssertEqual(SemanticVersion("1.2.0"), SemanticVersion("v1.2.0"))
    }
}
