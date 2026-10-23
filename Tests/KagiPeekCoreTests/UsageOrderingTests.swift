import XCTest
@testable import KagiPeekCore

// 排序方式原本只管面板行序，统计页的两个列表写死「按次数降序」，
// 于是改下拉没有任何变化。这些测试钉住每种模式在统计列表里的含义。

final class UsageOrderingTests: XCTestCase {
    private func entry(_ title: String, _ chord: KeyChord?, presses: Int, daysAgo: Double) -> UsageEntry {
        UsageEntry(
            usageKey: "com.example.App|\(chord?.cacheKey ?? "path:\(title)")",
            title: title,
            chord: chord,
            presses: presses,
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400)
        )
    }

    private let cmdC = KeyChord.combo([.command], KeyToken("c"))
    private let cmdV = KeyChord.combo([.command], KeyToken("v"))
    private let cmdB = KeyChord.combo([.command], KeyToken("b"))

    // MARK: - Entries

    func testFrequencyOrdersByPresses() {
        let entries = [
            entry("Rare", cmdC, presses: 2, daysAgo: 1),
            entry("Often", cmdV, presses: 40, daysAgo: 1)
        ]
        let sorted = UsageOrdering.entries(entries, mode: .frequencyDesc)
        XCTAssertEqual(sorted.map(\.title), ["Often", "Rare"])
    }

    func testAlphabeticalOrdersByTitle() {
        let entries = [
            entry("Paste", cmdV, presses: 40, daysAgo: 1),
            entry("Copy", cmdC, presses: 2, daysAgo: 1)
        ]
        let sorted = UsageOrdering.entries(entries, mode: .alphabetical)
        XCTAssertEqual(sorted.map(\.title), ["Copy", "Paste"])
    }

    func testKeyOrderFollowsTheKeyboardAndPutsShortcutlessLast() {
        let entries = [
            entry("Copy", cmdC, presses: 5, daysAgo: 1),
            entry("Zoom", nil, presses: 9, daysAgo: 1),
            entry("Paste", cmdV, presses: 1, daysAgo: 1)
        ]
        let sorted = UsageOrdering.entries(entries, mode: .keyOrder)
        XCTAssertEqual(sorted.map(\.title), ["Copy", "Paste", "Zoom"])
    }

    /// 统计页的「按键顺序」必须和面板同一套规则：否则同一个快捷键在两个视图里落在不同位置。
    func testKeyOrderMatchesThePanelOrder() {
        let f2 = KeyChord.combo([], KeyToken("f2"))
        let g = KeyChord.combo([], KeyToken("g"))
        let entries = [
            entry("G", g, presses: 1, daysAgo: 1),
            entry("F2", f2, presses: 1, daysAgo: 1),
            entry("Copy", cmdC, presses: 1, daysAgo: 1)
        ]
        let sorted = UsageOrdering.entries(entries, mode: .keyOrder)
        // 无修饰键的行最前（F2、G 按单词比），带修饰键的行随后。
        XCTAssertEqual(sorted.map(\.title), ["F2", "G", "Copy"])
    }

    /// smart 用和面板一样的衰减：刚用过、用得多的排前面，历史总量不能压过近期活跃。
    func testSmartPrefersRecentAndFrequent() {
        let entries = [
            entry("OldHeavy", cmdC, presses: 200, daysAgo: 200),
            entry("RecentLight", cmdV, presses: 12, daysAgo: 1)
        ]
        let sorted = UsageOrdering.entries(entries, mode: .smart)
        XCTAssertEqual(sorted.map(\.title), ["RecentLight", "OldHeavy"])
    }

    func testFrequencyIgnoresRecency() {
        let entries = [
            entry("Rare", cmdC, presses: 1, daysAgo: 0.1),
            entry("Often", cmdV, presses: 30, daysAgo: 20)
        ]
        XCTAssertEqual(UsageOrdering.entries(entries, mode: .frequencyDesc).map(\.title), ["Often", "Rare"])
    }

    // MARK: - App groups

    private func app(_ bundleID: String, presses: Int, daysAgo: Double) -> AppUsageSummary {
        AppUsageSummary(
            bundleID: bundleID,
            presses: presses,
            shortcutCount: 1,
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400)
        )
    }

    func testAppsSortByFrequencyUnlessAskedOtherwise() {
        let apps = [
            app("com.example.Small", presses: 3, daysAgo: 1),
            app("com.example.Big", presses: 50, daysAgo: 1)
        ]
        XCTAssertEqual(
            UsageOrdering.apps(apps, mode: .frequencyDesc, name: { $0 }).map(\.bundleID),
            ["com.example.Big", "com.example.Small"]
        )
        XCTAssertEqual(
            UsageOrdering.apps(apps, mode: .alphabetical, name: { $0 }).map(\.bundleID),
            ["com.example.Big", "com.example.Small"]
        )
    }

    func testAppsAlphabeticalUsesDisplayNames() {
        let apps = [
            app("com.apple.Safari", presses: 10, daysAgo: 1),
            app("com.apple.dt.Xcode", presses: 20, daysAgo: 1)
        ]
        let names = ["com.apple.Safari": "Safari", "com.apple.dt.Xcode": "Xcode"]
        XCTAssertEqual(
            UsageOrdering.apps(apps, mode: .alphabetical, name: { names[$0] ?? $0 }).map(\.bundleID),
            ["com.apple.Safari", "com.apple.dt.Xcode"]
        )
    }
}
