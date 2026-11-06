import XCTest
@testable import KanameCore

final class UsageSortingTests: XCTestCase {
    private let copy = KeyChord.combo([.command], KeyToken("c"))
    private let paste = KeyChord.combo([.command], KeyToken("v"))
    private let selectAll = KeyChord.combo([.command], KeyToken("a"))

    private func entry(
        owner: String,
        title: String?,
        chord: KeyChord?,
        presses: Int = 1
    ) -> UsageEntry {
        UsageEntry(
            usageKey: chord.map { "\(owner)|\($0.cacheKey)" } ?? "\(owner)|path:0,1",
            title: title,
            chord: chord,
            presses: presses,
            lastUsed: Date()
        )
    }

    private func appName(_ owner: String) -> String {
        switch owner {
        case "com.example.Editor": return "Editor"
        case "com.example.Notes": return "Notes"
        default: return owner
        }
    }

    private var rows: [UsageEntry] {
        [
            entry(owner: "com.example.Notes", title: "Paste", chord: paste),
            entry(owner: "com.example.Editor", title: "Select All", chord: selectAll),
            entry(owner: "com.example.Editor", title: "Copy", chord: copy),
            entry(owner: "com.example.Editor", title: nil, chord: nil)
        ]
    }

    func testShortcutOrderPutsTheChordlessRowLast() {
        let sorted = UsageSorting.entries(rows, by: .shortcut, appName: appName)
        XCTAssertEqual(sorted.map(\.title), ["Select All", "Copy", "Paste", nil])
    }

    func testAppOrderGroupsByDisplayNameThenShortcut() {
        let sorted = UsageSorting.entries(rows, by: .app, appName: appName)
        XCTAssertEqual(sorted.map(\.title), ["Select All", "Copy", nil, "Paste"])
    }

    func testDescriptionOrderSortsByTitleAndPutsMissingTitlesLast() {
        let sorted = UsageSorting.entries(rows, by: .description, appName: appName)
        XCTAssertEqual(sorted.map(\.title), ["Copy", "Paste", "Select All", nil])
    }

    /// 同一个 chord 在两个 App 里是两条记录；按快捷键排序时相邻，但不会被合并。
    func testSameChordInTwoOwnersStaysTwoRows() {
        let mine = entry(owner: "com.example.Editor", title: "Copy", chord: copy)
        let other = entry(owner: "com.example.Notes", title: "Copy", chord: copy)
        let sorted = UsageSorting.entries([other, mine], by: .shortcut, appName: appName)
        XCTAssertEqual(sorted.count, 2)
        XCTAssertEqual(sorted.map(\.usageKey), [mine.usageKey, other.usageKey])
    }
}
