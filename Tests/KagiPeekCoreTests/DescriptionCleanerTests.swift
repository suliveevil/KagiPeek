import XCTest
@testable import KagiPeekCore

final class DescriptionCleanerTests: XCTestCase {
    func testCollapsesWhitespaceAndStripsHint() {
        XCTAssertEqual(DescriptionCleaner.clean("  Save   As…\t⌘S "), "Save As…")
        XCTAssertEqual(DescriptionCleaner.clean("Open\u{00A0}Recent"), "Open Recent")
    }

    func testKeepsMeaningfulTrailingArrow() {
        XCTAssertEqual(DescriptionCleaner.clean("Continue →"), "Continue →")
    }

    func testLeadingPlusIsRemoved() {
        XCTAssertEqual(DescriptionCleaner.clean("+file"), "file")
    }

    func testTruncation() {
        XCTAssertEqual(DescriptionCleaner.truncate("abcdefghij", maxLength: 5), "abcd…")
        XCTAssertEqual(DescriptionCleaner.truncate("abc", maxLength: 5), "abc")
        XCTAssertEqual(DescriptionCleaner.truncate("abcdefghij", maxLength: 8), "abcdefg…")
    }
}
