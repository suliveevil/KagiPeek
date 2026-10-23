import XCTest
@testable import KagiPeekCore

// 日志文件的「按日滚动 / 保留天数 / 总大小上限」全是纯决策，时区在这里注入，
// 免得测试结果取决于跑测试的机器在哪个时区。

final class LogRotationPolicyTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - 文件名

    func testFileNameEncodesTheDay() {
        XCTAssertEqual(
            LogRotationPolicy.fileName(for: date(2026, 10, 23), timeZone: utc),
            "kagipeek-2026-10-23.log"
        )
    }

    func testFileNameRoundTrips() {
        let original = date(2026, 10, 23)
        let name = LogRotationPolicy.fileName(for: original, timeZone: utc)
        let parsed = LogRotationPolicy.date(fromFileName: name, timeZone: utc)
        XCTAssertEqual(parsed.map { calendar.startOfDay(for: $0) }, calendar.startOfDay(for: original))
    }

    func testForeignFileNamesAreNotLogFiles() {
        XCTAssertNil(LogRotationPolicy.date(fromFileName: "last-actions.json", timeZone: utc))
        XCTAssertNil(LogRotationPolicy.date(fromFileName: "kagipeek-2026-10-23.txt", timeZone: utc))
        XCTAssertNil(LogRotationPolicy.date(fromFileName: "crash-2026-10-23.log", timeZone: utc))
    }

    // MARK: - 滚动

    func testSameDayKeepsTheCurrentFile() {
        let now = date(2026, 10, 23, hour: 23, minute: 59)
        XCTAssertFalse(LogRotationPolicy.shouldRollover(
            currentFileName: "kagipeek-2026-10-23.log",
            now: now,
            timeZone: utc
        ))
    }

    func testMidnightRollsToANewFile() {
        let now = date(2026, 10, 24, hour: 0, minute: 0)
        XCTAssertTrue(LogRotationPolicy.shouldRollover(
            currentFileName: "kagipeek-2026-10-23.log",
            now: now,
            timeZone: utc
        ))
        XCTAssertEqual(LogRotationPolicy.fileName(for: now, timeZone: utc), "kagipeek-2026-10-24.log")
    }

    // MARK: - 保留天数

    func testFilesOlderThanRetentionArePruned() {
        let now = date(2026, 10, 23)
        let entries = [
            LogFileEntry(name: "kagipeek-2026-10-15.log", date: date(2026, 10, 15), size: 10),
            LogFileEntry(name: "kagipeek-2026-10-17.log", date: date(2026, 10, 17), size: 10)
        ]
        let pruned = LogRotationPolicy.filesToPrune(
            entries: entries, retentionDays: 7, timeZone: utc, now: now
        )
        // 8 天前过期；6 天前留下：边界两侧各一例。
        XCTAssertEqual(pruned.map(\.name), ["kagipeek-2026-10-15.log"])
    }

    func testTodaysFileIsNeverPruned() {
        let now = date(2026, 10, 23)
        let entries = [LogFileEntry(name: "kagipeek-2026-10-23.log", date: now, size: 10)]
        XCTAssertTrue(LogRotationPolicy.filesToPrune(entries: entries, timeZone: utc, now: now).isEmpty)
    }

    func testFutureDatedFileSurvivesRetentionButCountsTowardSize() {
        let now = date(2026, 10, 23)
        let future = LogFileEntry(
            name: "kagipeek-2026-11-01.log",
            date: date(2026, 11, 1),
            size: 900
        )
        let pruned = LogRotationPolicy.filesToPrune(entries: [future], timeZone: utc, now: now)
        XCTAssertTrue(pruned.isEmpty, "时钟回拨/时区跳变不该把文件当成过期")

        let capped = LogRotationPolicy.filesToPrune(
            entries: [future], totalLimit: 100, timeZone: utc, now: now
        )
        XCTAssertEqual(capped.map(\.name), ["kagipeek-2026-11-01.log"])
    }

    // MARK: - 总大小上限

    func testOverTotalLimitPrunesOldestFirst() {
        let now = date(2026, 10, 23)
        let entries = [
            LogFileEntry(name: "kagipeek-2026-10-22.log", date: date(2026, 10, 22), size: 400),
            LogFileEntry(name: "kagipeek-2026-10-21.log", date: date(2026, 10, 21), size: 400),
            LogFileEntry(name: "kagipeek-2026-10-23.log", date: now, size: 400)
        ]
        let pruned = LogRotationPolicy.filesToPrune(
            entries: entries, totalLimit: 900, retentionDays: 7, timeZone: utc, now: now
        )
        // 总量 1200 > 900：删最旧的一份刚好回到上限。
        XCTAssertEqual(pruned.map(\.name), ["kagipeek-2026-10-21.log"])
    }

    func testExactlyAtTheLimitPrunesNothing() {
        let now = date(2026, 10, 23)
        let entries = [
            LogFileEntry(name: "kagipeek-2026-10-22.log", date: date(2026, 10, 22), size: 500),
            LogFileEntry(name: "kagipeek-2026-10-23.log", date: now, size: 500)
        ]
        XCTAssertTrue(LogRotationPolicy.filesToPrune(
            entries: entries, totalLimit: 1000, timeZone: utc, now: now
        ).isEmpty)
    }

    func testExpiredAndOversizedAreBothReported() {
        let now = date(2026, 10, 23)
        let entries = [
            LogFileEntry(name: "kagipeek-2026-10-10.log", date: date(2026, 10, 10), size: 10),
            LogFileEntry(name: "kagipeek-2026-10-22.log", date: date(2026, 10, 22), size: 900),
            LogFileEntry(name: "kagipeek-2026-10-23.log", date: now, size: 300)
        ]
        let pruned = LogRotationPolicy.filesToPrune(
            entries: entries, totalLimit: 500, retentionDays: 7, timeZone: utc, now: now
        )
        XCTAssertEqual(Set(pruned.map(\.name)), [
            "kagipeek-2026-10-10.log",
            "kagipeek-2026-10-22.log"
        ])
    }
}
