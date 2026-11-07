import XCTest
@testable import KanameCore

/// A filter queue that spells a whole chord is a shortcut typed one key at a time, not a
/// query. The final bare letter is swallowed by the tap, so the front app never receives it;
/// the row has to be run by the panel instead of merely being selected — but only once the
/// narrowed panel has converged on that single row. While other rows are still on screen the
/// same keystroke remains a way to search.
final class FilterChordCompletionTests: XCTestCase {
    private func item(
        _ chord: KeyChord,
        _ title: String = "T",
        isEnabled: Bool = true,
        source: BindingSource = .menu
    ) -> BindingItem {
        BindingItem(
            chord: chord,
            title: title,
            group: ["Edit"],
            isEnabled: isEnabled,
            source: source
        )
    }

    private func filter(_ modifiers: ModifierSet..., letters: [Character] = ["h"]) -> PanelFilter {
        PanelFilter(tokens: modifiers.map { .modifier($0) } + letters.map { .letter($0) })
    }

    /// Most cases describe a panel whose filter left exactly the items under test. The
    /// explicit overrides are the point of the new gate: a long result list, a folded card,
    /// or a page that happens to hold one row must all stay a query.
    private func rowID(
        _ filter: PanelFilter,
        _ items: [BindingItem],
        remaining: [String]? = nil,
        remainingCount: Int? = nil
    ) -> String? {
        let drawn = remaining ?? items.map(\.id)
        return FilterChordCompletion.rowID(
            filter: filter,
            items: items,
            remainingRowIDs: drawn,
            remainingRowCount: remainingCount ?? drawn.count
        )
    }

    // MARK: - The GitHub Desktop case

    /// ⌥ ⌘ narrow, then a bare `h`: the queue now spells ⌥⌘H ("Hide Others"), and it is
    /// the only row left, so it runs on the key-down.
    func testModifierTokensPlusLetterCompletesTheChord() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        XCTAssertEqual(rowID(filter(.option, .command), [hideOthers]), hideOthers.id)
    }

    /// Token order is a queue, not a chord spelling: the same set still means ⌥⌘H.
    func testModifierTokenOrderDoesNotMatter() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        XCTAssertEqual(rowID(filter(.command, .option), [hideOthers]), hideOthers.id)
    }

    /// A system hotkey has no menu element to click; it still has to run when its chord is
    /// spelled in the queue (the row runner replays the chord into the front app).
    func testSystemHotkeyCompletesToo() {
        let minimizeAll = item(
            .combo([.option, .command], KeyToken("m")),
            "Minimize All",
            source: .system
        )
        XCTAssertEqual(
            rowID(filter(.option, .command, letters: ["m"]), [minimizeAll]),
            minimizeAll.id
        )
    }

    /// Two menu items can claim the same chord. With only one of them left, that one runs;
    /// while both are still on screen nothing runs — no catalog-order guess, no selection
    /// lookup that could disagree with the drawn row.
    func testSharedChordRunsOnlyTheSurvivingRow() {
        let first = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        let second = item(.combo([.option, .command], KeyToken("h")), "Hide Others Again", source: .system)
        XCTAssertEqual(
            rowID(filter(.option, .command), [first, second], remaining: [second.id]),
            second.id
        )
        XCTAssertNil(rowID(filter(.option, .command), [first, second]))
    }

    // MARK: - The single-row gate

    /// The reason for the gate: ⌥ ⌘ `h` may still be a search over several rows that mention
    /// H. Auto-running one of them would take the choice away from the user.
    func testSeveralSurvivingRowsStayAQuery() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        let history = item(.combo([.command], KeyToken("y")), "Show History")
        XCTAssertNil(rowID(filter(.option, .command), [hideOthers, history]))
    }

    /// A long result list split over pages can draw exactly one row on its last page. The
    /// total, not the page, is what says whether the user pointed at a single command.
    func testLastPageOfLongResultsDoesNotRun() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        XCTAssertNil(
            rowID(
                filter(.option, .command),
                [hideOthers],
                remaining: [hideOthers.id],
                remainingCount: 12
            )
        )
    }

    /// A single surviving row hidden inside a folded tool card is not a row the user can
    /// see or point at, so it must not be run from behind the fold.
    func testCountOfOneWithNoDrawnRowDoesNotRun() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        XCTAssertNil(
            rowID(
                filter(.option, .command),
                [hideOthers],
                remaining: [],
                remainingCount: 1
            )
        )
    }

    /// A disagreeing snapshot (one drawn row, a larger total) is not an unambiguous
    /// address; the safe answer is to keep filtering.
    func testCountAndDrawnRowsMustAgree() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        let other = item(.combo([.command], KeyToken("y")), "Show History")
        XCTAssertNil(
            rowID(
                filter(.option, .command),
                [hideOthers, other],
                remaining: [hideOthers.id, other.id],
                remainingCount: 1
            )
        )
    }

    /// The lone surviving row has to be the exact chord match, not merely a row that the
    /// same query found.
    func testSingleSurvivingRowThatIsNotTheMatchDoesNotRun() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        let chordless = item(.empty, "No Shortcut")
        XCTAssertNil(
            rowID(
                filter(.option, .command),
                [hideOthers, chordless],
                remaining: [chordless.id]
            )
        )
    }

    // MARK: - Queries are not chords

    func testEmptyFilterNeverRunsAnything() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        XCTAssertNil(rowID(PanelFilter(), [hideOthers]))
    }

    func testBareLetterWithoutModifiersIsAQuery() {
        let plain = item(.combo([], KeyToken("h")), "Bare H")
        XCTAssertNil(rowID(PanelFilter(tokens: [.letter("h")]), [plain]))
    }

    func testTwoLettersRemainASearch() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        XCTAssertNil(rowID(filter(.option, .command, letters: ["h", "h"]), [hideOthers]))
    }

    /// A modifier token alone is a narrowing, not a pressed key: nothing runs until a letter
    /// finishes the chord.
    func testModifiersAloneNeverRun() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        XCTAssertNil(
            rowID(
                PanelFilter(tokens: [.modifier(.option), .modifier(.command)]),
                [hideOthers]
            )
        )
    }

    func testDifferentModifiersDoNotMatch() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        XCTAssertNil(rowID(filter(.command), [hideOthers]))
        XCTAssertNil(rowID(filter(.option, .command, .control), [hideOthers]))
    }

    func testDifferentLetterDoesNotMatch() {
        let hideOthers = item(.combo([.option, .command], KeyToken("h")), "Hide Others")
        XCTAssertNil(rowID(filter(.option, .command, letters: ["j"]), [hideOthers]))
    }

    /// A chord that only starts with the probe needs another stroke. Auto-running it would
    /// skip the level below and make the second stroke unreachable.
    func testPrefixOfALongerChordDoesNotRun() {
        let twoStroke = item(
            KeyChord([
                .combo([.command], KeyToken("k")),
                .combo([.command], KeyToken("c"))
            ]),
            "Chord"
        )
        XCTAssertNil(rowID(filter(.command, letters: ["k"]), [twoStroke]))
    }

    /// A row with no chord at all cannot be spelled by the queue.
    func testChordlessRowDoesNotRun() {
        let chordless = item(.empty, "No Shortcut")
        XCTAssertNil(rowID(filter(.option, .command), [chordless]))
    }

    // MARK: - Rows the panel refuses to run

    func testDisabledRowDoesNotRun() {
        let disabled = item(
            .combo([.option, .command], KeyToken("h")),
            "Hide Others",
            isEnabled: false
        )
        XCTAssertNil(rowID(filter(.option, .command), [disabled]))
    }

    /// ⌃⌘Q is Lock Screen: the panel shows it but never runs it, on any surface.
    func testRestrictedRowDoesNotRun() {
        let lock = item(.combo([.control, .command], KeyToken("q")), "Lock Screen")
        XCTAssertNil(rowID(filter(.control, .command, letters: ["q"]), [lock]))
    }

    func testConfigToolRowDoesNotRun() {
        let tool = item(
            .combo([.option, .command], KeyToken("h")),
            "Tool Command",
            source: .configFile
        )
        XCTAssertNil(rowID(filter(.option, .command), [tool]))
    }

    func testUnknownChordDoesNotRun() {
        XCTAssertNil(
            rowID(filter(.option, .command), [], remaining: ["ghost"], remainingCount: 1)
        )
    }
}
