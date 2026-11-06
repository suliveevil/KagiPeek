import XCTest
@testable import KanameCore

final class NumericSettingInputTests: XCTestCase {
    private let range = 6...60

    func testAcceptsAWholeNumberInsideTheRange() {
        XCTAssertEqual(NumericSettingInput.value(from: "24", in: range), 24)
        XCTAssertEqual(NumericSettingInput.value(from: "6", in: range), 6)
        XCTAssertEqual(NumericSettingInput.value(from: "60", in: range), 60)
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(NumericSettingInput.value(from: "  24\n", in: range), 24)
    }

    func testFoldsFullWidthDigits() {
        XCTAssertEqual(NumericSettingInput.value(from: "２４", in: range), 24)
    }

    func testRejectsValuesOutsideTheRange() {
        XCTAssertNil(NumericSettingInput.value(from: "5", in: range))
        XCTAssertNil(NumericSettingInput.value(from: "61", in: range))
    }

    func testRejectsAnythingThatIsNotABareInteger() {
        XCTAssertNil(NumericSettingInput.value(from: "", in: range))
        XCTAssertNil(NumericSettingInput.value(from: "   ", in: range))
        XCTAssertNil(NumericSettingInput.value(from: "24.0", in: range))
        XCTAssertNil(NumericSettingInput.value(from: "-24", in: range))
        XCTAssertNil(NumericSettingInput.value(from: "+24", in: range))
        XCTAssertNil(NumericSettingInput.value(from: "1 2", in: range))
        XCTAssertNil(NumericSettingInput.value(from: "24 pt", in: range))
        XCTAssertNil(NumericSettingInput.value(from: "abc", in: range))
        XCTAssertNil(NumericSettingInput.value(from: "999999999999999999999", in: range))
    }
}
