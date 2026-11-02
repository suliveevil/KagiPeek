import XCTest
@testable import KagiPeekCore

final class PerAppUsageTests: XCTestCase {
    func testGroupsByBundleID() {
        var stats = UsageStatistics()
        let now = Date(timeIntervalSince1970: 1_000)
        stats.record(usageKey: "com.apple.Safari|8:c", at: now)
        stats.record(usageKey: "com.apple.Safari|8:c", at: now.addingTimeInterval(5))
        stats.record(usageKey: "*|8:v", at: now)
        stats.record(usageKey: "com.example.editor|8:s", at: now)

        let summaries = stats.summariesByApp()
        XCTAssertEqual(summaries.count, 3)
        XCTAssertEqual(summaries.first?.bundleID, "com.apple.Safari")
        XCTAssertEqual(summaries.first?.presses, 2)
        XCTAssertEqual(summaries.first?.shortcutCount, 1)
        XCTAssertTrue(summaries.contains { $0.bundleID == "*" && $0.isGlobal })
    }

    func testBundleIDParsing() {
        XCTAssertEqual(UsageStatistics.bundleID(fromUsageKey: "com.foo|8:c"), "com.foo")
        XCTAssertEqual(UsageStatistics.bundleID(fromUsageKey: "*|8:v"), "*")
        XCTAssertEqual(UsageStatistics.bundleID(fromUsageKey: "no-separator"), "no-separator")
    }
}
