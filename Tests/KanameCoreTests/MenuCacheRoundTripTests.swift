import XCTest
@testable import KanameCore

/// 磁盘缓存把整行 BindingItem（含 KeyChord 的 steps/alternates）编成 JSON 存盘。
/// Chord 的 Codable 合成若丢字段，恢复出来的行就会显示错误的快捷键——而缓存命中时
/// 没有任何扫描能纠正它。钉住往返保真。
final class MenuCacheRoundTripTests: XCTestCase {
    func testBindingItemSurvivesJSONRoundTrip() {
        let items = [
            BindingItem(
                chord: .combo([.command, .shift], "3"),
                title: "Screenshot",
                group: ["System"],
                source: .menu,
                appBundleID: "com.apple.Safari",
                axPath: "0,0,1"
            ),
            // 无快捷键行：缓存里数量最多的就是它们，空 chord 必须原样回来。
            BindingItem(
                chord: .empty,
                title: "Zoom",
                group: ["Window"],
                source: .menu,
                appBundleID: "com.apple.Safari",
                axPath: "7,0,2"
            ),
            // alternates 是同一按键的别名，丢了会让布局鲁棒性静默失效。
            BindingItem(
                chord: .combo([.option], "left", alternates: ["leftArrow"]),
                title: "Back",
                group: ["History"],
                source: .menu,
                appBundleID: "com.apple.Safari",
                axPath: "2,1,0"
            )
        ]
        let data = try! JSONEncoder().encode(items)
        let decoded = try! JSONDecoder().decode([BindingItem].self, from: data)
        XCTAssertEqual(decoded, items)
        // id 与 usageKey 是扫描时算出来的：往返后必须逐字节相同，
        // 否则点击、执行、收藏会在缓存命中后全部对不上行。
        XCTAssertEqual(decoded.map(\.id), items.map(\.id))
        XCTAssertEqual(decoded.map(\.usageKey), items.map(\.usageKey))
    }
}
