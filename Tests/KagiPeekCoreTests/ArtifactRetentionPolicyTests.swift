import XCTest
@testable import KagiPeekCore

// 崩溃报告和菜单缓存是磁盘上仅有的两处「无上限增长」的目录，淘汰规则是纯决策：
// 输入日期、输出名字，所以边界可以在这里一一定住，不必真的建文件。

final class ArtifactRetentionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var day: TimeInterval { 24 * 60 * 60 }

    private func entry(_ name: String, ageDays: Double, partial: Bool = false) -> RetainedArtifact {
        RetainedArtifact(
            name: name,
            modifiedAt: now.addingTimeInterval(-ageDays * day),
            isPartial: partial
        )
    }

    private func names(_ entries: [RetainedArtifact]) -> [String] {
        entries.map(\.name).sorted()
    }

    // MARK: - 空与边界

    func testAnEmptyFolderHasNothingToDelete() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 5, maximumAge: day)
        XCTAssertTrue(policy.artifactsToDelete(entries: [], now: now).isEmpty)
    }

    func testEverythingInsideTheWindowIsKept() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 5, maximumAge: 10 * day)
        let entries = [
            entry("a.json", ageDays: 0),
            entry("b.json", ageDays: 3),
            entry("c.json", ageDays: 9)
        ]
        XCTAssertTrue(policy.artifactsToDelete(entries: entries, now: now).isEmpty)
    }

    /// 全超窗时也删不到底：最新那条是「唯一记录」的兜底，数量规则才负责封顶。
    func testEverythingOlderThanTheWindowGoesExceptTheNewest() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 10, maximumAge: 7 * day)
        let entries = [
            entry("newest.json", ageDays: 30),
            entry("older.json", ageDays: 40),
            entry("oldest.json", ageDays: 50)
        ]
        XCTAssertEqual(
            names(policy.artifactsToDelete(entries: entries, now: now)),
            ["older.json", "oldest.json"]
        )
    }

    /// 年龄边界取严格大于：正好 7 天不算过期，7 天零 1 秒才算。
    func testTheAgeBoundaryIsExclusive() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 10, maximumAge: 7 * day)
        let entries = [
            entry("newest.json", ageDays: 0),
            entry("exactly.json", ageDays: 7),
            entry("just-past.json", ageDays: 7 + 1 / 86_400)
        ]
        XCTAssertEqual(names(policy.artifactsToDelete(entries: entries, now: now)), ["just-past.json"])
    }

    // MARK: - 数量规则

    func testTheCountRuleKeepsExactlyTheRequestedNumber() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 3, maximumAge: nil)
        let entries = (0..<6).map { entry("report-\($0).json", ageDays: Double($0)) }
        XCTAssertEqual(
            names(policy.artifactsToDelete(entries: entries, now: now)),
            ["report-3.json", "report-4.json", "report-5.json"]
        )
    }

    /// 0 和负数不是一个「全部删掉」的授权，而是「只留最新」的写法。
    func testKeepMostRecentZeroKeepsOnlyTheNewest() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 0, maximumAge: nil)
        let entries = [entry("a.json", ageDays: 2), entry("b.json", ageDays: 0)]
        XCTAssertEqual(names(policy.artifactsToDelete(entries: entries, now: now)), ["a.json"])
    }

    func testKeepMostRecentNegativeKeepsOnlyTheNewest() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: -3, maximumAge: nil)
        let entries = [entry("a.json", ageDays: 2), entry("b.json", ageDays: 0)]
        XCTAssertEqual(names(policy.artifactsToDelete(entries: entries, now: now)), ["a.json"])
    }

    func testWithoutAMaximumAgeOnlyTheCountRuleApplies() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 2, maximumAge: nil)
        let entries = [
            entry("ancient.json", ageDays: 3_650),
            entry("old.json", ageDays: 400),
            entry("recent.json", ageDays: 1)
        ]
        XCTAssertEqual(
            names(policy.artifactsToDelete(entries: entries, now: now)),
            ["ancient.json"]
        )
    }

    // MARK: - 两条不可删的规则

    /// 一年只崩一次的用户，唯一那份报告不该因为日历翻页而消失。
    func testTheNewestEntrySurvivesEvenWhenItIsFarTooOld() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 1, maximumAge: day)
        let entries = [entry("only.json", ageDays: 900)]
        XCTAssertTrue(policy.artifactsToDelete(entries: entries, now: now).isEmpty)
    }

    /// `.partial` 是下一次启动要转成报告的现场证据，多旧都不能删。
    func testPartialFragmentsAreNeverDeleted() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 1, maximumAge: day)
        let entries = [
            entry("new.json", ageDays: 0),
            entry("dead-session.partial", ageDays: 365, partial: true)
        ]
        XCTAssertTrue(policy.artifactsToDelete(entries: entries, now: now).isEmpty)
    }

    /// 最新的条目恰好是 partial 时，保护必须落到最新的**非 partial** 上，
    /// 否则「永不删最新」会在最需要它的那一次失效。
    func testTheNewestNonPartialSurvivesWhenTheNewestEntryIsAPartial() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 1, maximumAge: nil)
        let entries = [
            entry("live.partial", ageDays: 0, partial: true),
            entry("older.json", ageDays: 5),
            entry("oldest.json", ageDays: 9)
        ]
        XCTAssertEqual(names(policy.artifactsToDelete(entries: entries, now: now)), ["oldest.json"])
    }

    func testAFolderOfOnlyPartialsIsLeftAlone() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 1, maximumAge: day)
        let entries = [
            entry("a.partial", ageDays: 100, partial: true),
            entry("b.partial", ageDays: 200, partial: true)
        ]
        XCTAssertTrue(policy.artifactsToDelete(entries: entries, now: now).isEmpty)
    }

    // MARK: - 稳定性

    /// 同一秒写下的两个文件不能因为目录枚举顺序不同而得到不同答案：
    /// 名称是 tie-break，所以结果只取决于集合本身。
    func testSameTimestampGivesTheSameAnswerWhateverTheInputOrder() {
        let policy = ArtifactRetentionPolicy(keepMostRecent: 1, maximumAge: nil)
        let entries = [entry("a.json", ageDays: 0), entry("b.json", ageDays: 0), entry("c.json", ageDays: 0)]
        let forward = policy.artifactsToDelete(entries: entries, now: now)
        let backward = policy.artifactsToDelete(entries: entries.reversed(), now: now)
        XCTAssertEqual(names(forward), names(backward))
        XCTAssertEqual(names(forward), ["a.json", "b.json"], "名称大的视为更新，留下 c.json")
    }
}
