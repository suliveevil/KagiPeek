import XCTest
@testable import KagiPeekCore

final class UsageStatisticsTests: XCTestCase {
    func testRecordAccumulates() {
        var stats = UsageStatistics()
        let key = "*|8:c"
        stats.record(usageKey: key, at: Date(timeIntervalSince1970: 100))
        stats.record(usageKey: key, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(stats.record(for: key)?.count, 2)
        XCTAssertEqual(stats.totalPresses, 2)
        XCTAssertEqual(stats.record(for: key)?.lastUsed, Date(timeIntervalSince1970: 200))
    }

    func testResetClearsEverything() {
        var stats = UsageStatistics()
        stats.record(usageKey: "k", at: Date())
        stats.reset()
        XCTAssertTrue(stats.records.isEmpty)
        XCTAssertEqual(stats.totalPresses, 0)
    }

    func testPruneKeepsMostRecent() {
        var stats = UsageStatistics()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<(UsageStatistics.maxRecords + 50) {
            stats.record(usageKey: "key\(index)", at: base.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(stats.records.count, UsageStatistics.maxRecords)
        // The 50 oldest entries were dropped.
        XCTAssertNil(stats.records["key0"])
        XCTAssertNotNil(stats.records["key\(UsageStatistics.maxRecords + 49)"])
    }

    func testStatisticsRoundTrip() throws {
        var stats = UsageStatistics()
        stats.record(usageKey: "a|8:c", at: Date(timeIntervalSince1970: 42))
        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(UsageStatistics.self, from: data)
        XCTAssertEqual(decoded, stats)
    }
}
