import XCTest
@testable import KagiPeekCore

// 统计页的展开列表要把「只有键」的使用记录还原成「快捷键 + 命令 + 次数」。
// 记录里没有标题，所以 join 与缺失时的诚实呈现都需要钉住。

final class UsageBreakdownTests: XCTestCase {
    private func item(_ title: String, chord: KeyChord, bundle: String?) -> BindingItem {
        BindingItem(chord: chord, title: title, group: ["File"], source: .menu, appBundleID: bundle)
    }

    private let copy = KeyChord.combo([.command], KeyToken("c"))

    func testJoinsTitlesByUsageKey() {
        let item = item("Copy", chord: copy, bundle: "com.example.Editor")
        let records = [item.usageKey: UsageRecord(count: 7, lastUsed: Date())]
        let entries = UsageBreakdown.entries(
            for: "com.example.Editor",
            records: records,
            known: [item]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "Copy")
        XCTAssertEqual(entries.first?.chord, copy)
        XCTAssertEqual(entries.first?.presses, 7)
    }

    func testUnknownCommandKeepsItsCountAndRecoversTheChord() {
        // 这个 App 这次没被扫描：记录里只有 owner|chord。次数是真的，标题只能缺席，
        // 但快捷键应当从 usage key 里还原出来，而不是显示成空白。
        let key = "com.example.Ghost|\(copy.cacheKey)"
        let entries = UsageBreakdown.entries(
            for: "com.example.Ghost",
            records: [key: UsageRecord(count: 3, lastUsed: Date())],
            known: []
        )
        XCTAssertEqual(entries.first?.presses, 3)
        XCTAssertNil(entries.first?.title)
        XCTAssertEqual(entries.first?.chord, copy)
    }

    func testOnlyTheRequestedAppIsIncluded() {
        let mine = item("Copy", chord: copy, bundle: "com.example.Editor")
        let other = item("Paste", chord: .combo([.command], KeyToken("v")), bundle: "com.example.Other")
        let entries = UsageBreakdown.entries(
            for: "com.example.Editor",
            records: [
                mine.usageKey: UsageRecord(count: 1, lastUsed: Date()),
                other.usageKey: UsageRecord(count: 9, lastUsed: Date())
            ],
            known: [mine, other]
        )
        XCTAssertEqual(entries.map(\.title), ["Copy"])
    }

    func testSortedByPressesDescending() {
        let a = item("Copy", chord: copy, bundle: "com.example.Editor")
        let b = item("Paste", chord: .combo([.command], KeyToken("v")), bundle: "com.example.Editor")
        let c = item("Cut", chord: .combo([.command], KeyToken("x")), bundle: "com.example.Editor")
        let entries = UsageBreakdown.entries(
            for: "com.example.Editor",
            records: [
                a.usageKey: UsageRecord(count: 2, lastUsed: Date()),
                b.usageKey: UsageRecord(count: 9, lastUsed: Date()),
                c.usageKey: UsageRecord(count: 5, lastUsed: Date())
            ],
            known: [a, b, c]
        )
        XCTAssertEqual(entries.map(\.title), ["Paste", "Cut", "Copy"])
    }

    /// 无快捷键的命令用菜单路径做 key，没有键可以展示 —— 显示为「无快捷键」，不是空白。
    func testShortcutlessCommandHasNoChord() {
        let key = "com.example.Editor|path:0,1,3"
        let entries = UsageBreakdown.entries(
            for: "com.example.Editor",
            records: [key: UsageRecord(count: 4, lastUsed: Date())],
            known: []
        )
        XCTAssertNil(entries.first?.chord)
        XCTAssertTrue(entries.first?.isShortcutless ?? false)
    }

    // MARK: - cacheKey 还原

    func testChordRoundTripsThroughItsCacheKey() {
        XCTAssertEqual(KeyChord.from(cacheKey: copy.cacheKey), copy)
        let multi = KeyChord.combo([.control, .option], KeyToken("k"))
            .appending(modifiers: [.command], key: KeyToken("c"))
        XCTAssertEqual(KeyChord.from(cacheKey: multi.cacheKey), multi)
    }

    func testSlashKeyInMultiStepChordRoundTripsThroughItsCacheKey() {
        let chord = KeyChord.combo([.command], KeyToken("/"))
            .appending(modifiers: [.option], key: KeyToken("c"))
        XCTAssertEqual(KeyChord.from(cacheKey: chord.cacheKey), chord)
    }

    func testHyphenKeyRoundTripsWithoutCollidingWithModifierOnlyIdentity() {
        let chord = KeyChord.combo([.command], KeyToken("-"))
        let modifiersOnly = KeyChord.modifiers([.command])
        XCTAssertNotEqual(chord.cacheKey, modifiersOnly.cacheKey)
        XCTAssertEqual(KeyChord.from(cacheKey: chord.cacheKey), chord)
    }

    func testLegacyCacheKeysRemainReadable() {
        XCTAssertEqual(KeyChord.from(cacheKey: "8:c"), copy)
        XCTAssertNil(KeyChord.from(cacheKey: "8:-"))
    }

    func testPathKeysAreNotChords() {
        XCTAssertNil(KeyChord.from(cacheKey: "path:0,1,3"))
        XCTAssertNil(KeyChord.from(cacheKey: ""))
        XCTAssertNil(KeyChord.from(cacheKey: "garbage"))
    }
}
