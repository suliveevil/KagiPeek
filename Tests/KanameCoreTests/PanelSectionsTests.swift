import XCTest
@testable import KanameCore

// 面板现在有三个来源：前台 App 的命令、系统热键、配置工具（Keyboard Maestro / Alfred / …）。
// 三块永远按固定顺序拼接、不交错，所以这些测试钉住「顺序」「计数」「边界」和「不合并」。

final class PanelSectionsTests: XCTestCase {
    private func item(
        _ title: String,
        chord: KeyChord,
        source: BindingSource = .menu,
        bundle: String? = "com.example.App",
        tool: ConfigTool? = nil
    ) -> BindingItem {
        BindingItem(
            chord: chord,
            title: title,
            group: tool.map { [$0.displayName] } ?? ["File"],
            source: source,
            appBundleID: bundle,
            configTool: tool
        )
    }

    private func hit(_ title: String, chord: KeyChord, bundle: String? = "com.example.App") -> PrefixHit {
        let item = item(title, chord: chord, bundle: bundle)
        return PrefixHit(item: item, nextKey: chord.steps.first?.key, remainingSteps: 0, relation: .exact)
    }

    private func toolHit(_ title: String, chord: KeyChord, tool: ConfigTool) -> PrefixHit {
        let item = item(title, chord: chord, source: .configFile, bundle: nil, tool: tool)
        return PrefixHit(item: item, nextKey: nil, remainingSteps: 0, relation: .exact)
    }

    func testAppSectionComesEntirelyBeforeSystemSection() {
        let app = [hit("Copy", chord: .combo([.command], KeyToken("c")))]
        let system = PanelSections.hits(for: [
            item("Screenshot", chord: .combo([.command, .shift], KeyToken("3")), source: .system, bundle: nil)
        ])
        let entries = PanelSections.combine(app: app, system: system)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].section, .app)
        XCTAssertEqual(entries[1].section, .system)
        XCTAssertEqual(PanelSections.boundary(in: entries), 1)
    }

    func testOrderInsideEachSectionIsUntouched() {
        // combine 只做拼接：分区内的先后由 PanelOrdering 决定，这里不应该被重排。
        let app = [
            hit("Second", chord: .combo([.command], KeyToken("v"))),
            hit("First", chord: .combo([.command], KeyToken("c")))
        ]
        let system = PanelSections.hits(for: [
            item("B", chord: .combo([.command, .shift], KeyToken("b")), source: .system, bundle: nil),
            item("A", chord: .combo([.command, .shift], KeyToken("a")), source: .system, bundle: nil)
        ])
        let entries = PanelSections.combine(app: app, system: system)
        XCTAssertEqual(entries.map(\.hit.item.title), ["Second", "First", "B", "A"])
    }

    func testWithoutSystemRowsThereIsNoBoundary() {
        let entries = PanelSections.combine(
            app: [hit("Copy", chord: .combo([.command], KeyToken("c")))],
            system: []
        )
        XCTAssertNil(PanelSections.boundary(in: entries))
        XCTAssertEqual(entries.count, 1)
    }

    /// 系统热键是单键和弦，没有「下一键」可言；包装成行时不能造出一个假的 chevron。
    func testSystemHitsAreCompleteRows() {
        let hits = PanelSections.hits(for: [
            item("Screenshot", chord: .combo([.command, .shift], KeyToken("3")), source: .system, bundle: nil)
        ])
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits[0].nextKey)
        XCTAssertEqual(hits[0].remainingSteps, 0)
        XCTAssertTrue(hits[0].item.chord.isFinalStroke(after: .empty))
    }

    /// 三个来源的顺序是固定的：App → 系统 → 各工具（工具之间按传入顺序）。
    func testThreeSourceOrderIsAppSystemThenTools() {
        let app = [hit("Copy", chord: .combo([.command], KeyToken("c")))]
        let system = PanelSections.hits(for: [
            item("Screenshot", chord: .combo([.command, .shift], KeyToken("3")), source: .system, bundle: nil)
        ])
        let tools: [(ConfigTool, [PrefixHit])] = [
            (.alfred, [toolHit("Alfred Search", chord: .combo([.command], KeyToken("space")), tool: .alfred)]),
            (.skhd, [toolHit("Focus", chord: .combo([.option], KeyToken("h")), tool: .skhd)])
        ]
        let entries = PanelSections.combine(app: app, system: system, tool: tools)
        XCTAssertEqual(entries.map(\.section), [.app, .system, .tool(.alfred), .tool(.skhd)])
        XCTAssertEqual(PanelSections.boundary(in: entries), 1)
    }

    /// 30 个 App 行、20 个系统热键、12 个工具行：三段各算各的，工具绝不能并进 App 的计数。
    func testCountsKeepToolsSeparateFromApp() {
        let app = (0..<30).map { hit("App \($0)", chord: .combo([.command], KeyToken("a"))) }
        let system = PanelSections.hits(for: (0..<20).map {
            item("System \($0)", chord: .combo([.command, .shift], KeyToken("s")), source: .system, bundle: nil)
        })
        let tools: [(ConfigTool, [PrefixHit])] = [
            (.keyboardMaestro, (0..<7).map {
                toolHit("KM \($0)", chord: .combo([.control], KeyToken("k")), tool: .keyboardMaestro)
            }),
            (.hammerspoon, (0..<5).map {
                toolHit("HS \($0)", chord: .combo([.control], KeyToken("h")), tool: .hammerspoon)
            })
        ]
        let entries = PanelSections.combine(app: app, system: system, tool: tools)
        let counts = PanelSections.counts(in: entries)
        XCTAssertEqual(entries.count, 62)
        XCTAssertEqual(counts[.app], 30)
        XCTAssertEqual(counts[.system], 20)
        XCTAssertEqual(counts[.tool(.keyboardMaestro)], 7)
        XCTAssertEqual(counts[.tool(.hammerspoon)], 5)
        XCTAssertNil(counts[.tool(.alfred)])
    }

    /// App 区即使为空也占一张 card；工具区为空时不多算一张。
    func testEmptyToolSectionAddsNoHeading() {
        XCTAssertEqual(
            PanelSections.nonEmptySectionCount(appCount: 0, systemCount: 0, toolCount: 0),
            1
        )
        XCTAssertEqual(
            PanelSections.nonEmptySectionCount(appCount: 5, systemCount: 0, toolCount: 0),
            1
        )
        XCTAssertEqual(
            PanelSections.nonEmptySectionCount(appCount: 5, systemCount: 3, toolCount: 0),
            2
        )
        XCTAssertEqual(
            PanelSections.nonEmptySectionCount(appCount: 5, systemCount: 0, toolCount: 12),
            2
        )
        XCTAssertEqual(
            PanelSections.nonEmptySectionCount(appCount: 5, systemCount: 3, toolCount: 12),
            3
        )
    }

    /// 每个非空工具各占一张 card：3 个工具有行时是 app + system + 3，不是把工具当一个块。
    func testCardBudgetCountsEachToolCard() {
        let budget = PanelSections.cardAndHeadingBudget(
            systemCount: 3,
            toolCounts: [4, 0, 7],
            appHeading: true
        )
        XCTAssertEqual(budget.cards, 4)
        XCTAssertEqual(budget.headings, 4)
        XCTAssertEqual(
            PanelSections.cardAndHeadingBudget(systemCount: 0, toolCounts: [0, 0], appHeading: true).cards,
            1
        )
        // 和弦顺序里 app 卡由标题栏命名，不占 heading。
        XCTAssertEqual(
            PanelSections.cardAndHeadingBudget(systemCount: 2, toolCounts: [5], appHeading: false).headings,
            2
        )
    }

    /// 同一个和弦出现在两个来源：两行都保留，不合并。
    func testSameChordInTwoSourcesKeepsBothRows() {
        let chord = KeyChord.combo([.command], KeyToken("k"))
        let app = [hit("Show Palette", chord: chord)]
        let alfred = [toolHit("Alfred", chord: chord, tool: .alfred)]
        let entries = PanelSections.combine(app: app, system: [], tool: [(.alfred, alfred)])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.section), [.app, .tool(.alfred)])
        XCTAssertEqual(PanelSections.counts(in: entries)[.app], 1)
        XCTAssertEqual(PanelSections.counts(in: entries)[.tool(.alfred)], 1)
    }

    /// 系统区为空时，边界直接指向工具区，而不是停在一个不存在的标题上。
    func testBoundarySkipsEmptySystemAndPointsAtTool() {
        let app = [
            hit("Copy", chord: .combo([.command], KeyToken("c"))),
            hit("Paste", chord: .combo([.command], KeyToken("v")))
        ]
        let tools: [(ConfigTool, [PrefixHit])] = [
            (.alfred, [toolHit("Alfred Search", chord: .combo([.command], KeyToken("space")), tool: .alfred)])
        ]
        let entries = PanelSections.combine(app: app, system: [], tool: tools)
        XCTAssertEqual(PanelSections.boundary(in: entries), 2)
        XCTAssertEqual(entries[2].section, .tool(.alfred))
    }

    /// sectionOrder 只陈述来源顺序，不排序工具。
    func testSectionOrderIsAppSystemThenTools() {
        XCTAssertEqual(
            PanelSections.sectionOrder(tool: [.alfred, .skhd]),
            [.app, .system, .tool(.alfred), .tool(.skhd)]
        )
        XCTAssertEqual(PanelSections.sectionOrder(), [.app, .system])
    }

    /// 折叠时工具行不进入面板走的序列，但计数（也就是标题上的总数）仍包含它们；
    /// 展开后同一批行回到序列里。
    func testFoldedToolRowsLeaveTheSequenceButStayInTheCounts() {
        let app = [
            hit("Copy", chord: .combo([.command], KeyToken("c"))),
            hit("Paste", chord: .combo([.command], KeyToken("v")))
        ]
        let system = PanelSections.hits(for: [
            item("Screenshot", chord: .combo([.command, .shift], KeyToken("3")), source: .system, bundle: nil)
        ])
        let alfred = (0..<4).map {
            toolHit("Alfred \($0)", chord: .combo([.command], KeyToken("k")), tool: .alfred)
        }
        let entries = PanelSections.combine(app: app, system: system, tool: [(.alfred, alfred)])
        XCTAssertEqual(entries.count, 7)

        let folded = PanelSections.visible(entries, expandedTools: [], narrowing: false)
        XCTAssertEqual(folded.count, 3)
        XCTAssertFalse(folded.contains { entry in
            if case .tool = entry.section { return true }
            return false
        })
        // 折叠卡的「总数」来自整份列表，而不是序列。
        XCTAssertEqual(PanelSections.counts(in: entries)[.tool(.alfred)], 4)
        XCTAssertEqual(folded.count + (PanelSections.counts(in: entries)[.tool(.alfred)] ?? 0), entries.count)

        let expanded = PanelSections.visible(entries, expandedTools: [.alfred], narrowing: false)
        XCTAssertEqual(expanded.count, 7)
        XCTAssertEqual(expanded.map(\.section).last, PanelSectionID.tool(.alfred))

        // 有过滤条件时，折叠卡也让位于序列：匹配行不能被折叠挡住。
        let narrowed = PanelSections.visible(entries, expandedTools: [], narrowing: true)
        XCTAssertEqual(narrowed.count, entries.count)
    }

    /// 面板级显示开关关掉时，工具行整批不进面板：既没有卡，也不占行预算。
    func testHiddenConfigToolsContributeNoRowsOrCards() {
        let toolRows = [
            item(
                "Alfred Search",
                chord: .combo([.command], KeyToken("space")),
                source: .configFile,
                bundle: nil,
                tool: .alfred
            ),
            item(
                "Karabiner Hyper",
                chord: .combo([.command], KeyToken("k")),
                source: .configFile,
                bundle: nil,
                tool: .karabiner
            )
        ]
        XCTAssertEqual(PanelSections.configToolRows(toolRows, showing: true), toolRows)
        XCTAssertTrue(PanelSections.configToolRows(toolRows, showing: false).isEmpty)

        // 工具行数为空时，预算只剩 App 卡与系统卡；这张断言钉住「关掉不等于留空卡」。
        let shown = PanelSections.cardAndHeadingBudget(
            systemCount: 3,
            toolCounts: [1, 1],
            appHeading: true
        )
        XCTAssertEqual(shown.cards, 4)
        XCTAssertEqual(shown.headings, 4)
        let hidden = PanelSections.cardAndHeadingBudget(
            systemCount: 3,
            toolCounts: [],
            appHeading: true
        )
        XCTAssertEqual(hidden.cards, 2)
        XCTAssertEqual(hidden.headings, 2)
    }
}
