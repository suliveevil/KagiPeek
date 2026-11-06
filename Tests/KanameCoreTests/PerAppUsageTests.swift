import XCTest
@testable import KanameCore

final class PerAppUsageTests: XCTestCase {
    func testBundleIDParsing() {
        XCTAssertEqual(UsageStatistics.bundleID(fromUsageKey: "com.foo|8:c"), "com.foo")
        XCTAssertEqual(UsageStatistics.bundleID(fromUsageKey: "*|8:v"), "*")
        XCTAssertEqual(UsageStatistics.bundleID(fromUsageKey: "no-separator"), "no-separator")
    }
}
