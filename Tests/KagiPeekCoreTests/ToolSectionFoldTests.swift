import XCTest
@testable import KagiPeekCore

/// The fold rule, tested where it lives: which cards show their rows, and what a filter does
/// to them while it stands.
final class ToolSectionFoldTests: XCTestCase {
    /// Each tool is its own card: opening one must not open the others.
    func testEveryToolIsItsOwnCard() {
        let expanded: Set<ConfigTool> = [.alfred]
        XCTAssertTrue(ToolSectionFold.isExpanded(tool: .alfred, expanded: expanded, narrowing: false))
        for tool in ConfigTool.allCases where tool != .alfred {
            XCTAssertFalse(
                ToolSectionFold.isExpanded(tool: tool, expanded: expanded, narrowing: false),
                "\(tool) must stay folded while only Alfred is open"
            )
        }
    }

    /// Nothing open is the session's starting point.
    func testEveryToolStartsFolded() {
        for tool in ConfigTool.allCases {
            XCTAssertFalse(ToolSectionFold.isExpanded(tool: tool, expanded: [], narrowing: false))
        }
    }

    /// A filter opens every card, so a match can never be listed but unreachable.
    func testNarrowingOpensEveryCard() {
        for tool in ConfigTool.allCases {
            XCTAssertTrue(ToolSectionFold.isExpanded(tool: tool, expanded: [], narrowing: true))
        }
        // And it does not erase a choice the user made in either direction.
        XCTAssertTrue(ToolSectionFold.isExpanded(tool: .alfred, expanded: [], narrowing: true))
        XCTAssertTrue(ToolSectionFold.isExpanded(tool: .skhd, expanded: [.skhd], narrowing: true))
    }

    /// Clearing the filter brings the user's own cards back, unchanged.
    func testClearingTheFilterRestoresTheUsersCards() {
        let expanded: Set<ConfigTool> = [.alfred, .skhd]
        for tool in ConfigTool.allCases {
            XCTAssertTrue(ToolSectionFold.isExpanded(tool: tool, expanded: expanded, narrowing: true))
        }
        XCTAssertTrue(ToolSectionFold.isExpanded(tool: .alfred, expanded: expanded, narrowing: false))
        XCTAssertTrue(ToolSectionFold.isExpanded(tool: .skhd, expanded: expanded, narrowing: false))
        for tool in ConfigTool.allCases where tool != .alfred && tool != .skhd {
            XCTAssertFalse(ToolSectionFold.isExpanded(tool: tool, expanded: expanded, narrowing: false))
        }
    }

    /// The window budget counts only the rows of cards that are open — except under a
    /// filter, where every card is open for the duration.
    func testVisibleRowCountFollowsTheFold() {
        let counts: [ConfigTool: Int] = [.alfred: 4, .karabiner: 3, .keyboardMaestro: 2]
        XCTAssertEqual(
            ToolSectionFold.visibleRowCount(toolCounts: counts, expanded: [], narrowing: false),
            0
        )
        XCTAssertEqual(
            ToolSectionFold.visibleRowCount(toolCounts: counts, expanded: [.alfred], narrowing: false),
            4
        )
        XCTAssertEqual(
            ToolSectionFold.visibleRowCount(toolCounts: counts, expanded: [.alfred, .karabiner], narrowing: false),
            7
        )
        XCTAssertEqual(
            ToolSectionFold.visibleRowCount(toolCounts: counts, expanded: [], narrowing: true),
            9
        )
    }
}
