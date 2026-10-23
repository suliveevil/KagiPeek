import XCTest
@testable import KagiPeekCore

/// Combo lookup and the live-test verdict.
///
/// Both answer the same question — who gets this combo? — one from what the scan read and
/// one from a real keypress. Their tests live together because the second exists to cover
/// the cases where the first can only guess.
final class ComboLookupTests: XCTestCase {

    private var cmdShift4: KeyChord { .combo([.command, .shift], KeyToken("4")) }

    private var items: [BindingItem] {
        [
            BindingItem(chord: cmdShift4, title: "Screenshot", group: ["File"], source: .menu, appBundleID: "com.apple.Safari"),
            BindingItem(
                chord: .combo([.command], KeyToken("n")),
                title: "New Window",
                group: ["File"],
                source: .menu,
                appBundleID: "com.apple.Safari"
            ),
            BindingItem(
                chord: .combo([.option, .command], KeyToken("t")),
                title: "Rule",
                group: ["Karabiner-Elements"],
                source: .configFile,
                configTool: .karabiner
            )
        ]
    }

    // MARK: - Parsing

    func testParsesSpelledOutCombos() {
        XCTAssertEqual(ComboQuery.chord(from: "cmd shift 4"), cmdShift4)
        XCTAssertEqual(ComboQuery.chord(from: "opt cmd t"), KeyChord.combo([.option, .command], KeyToken("t")))
    }

    func testParsesGlyphsAndPluses() {
        XCTAssertEqual(ComboQuery.chord(from: "⌘⇧4"), cmdShift4)
        XCTAssertEqual(ComboQuery.chord(from: "cmd+shift+4"), cmdShift4)
    }

    func testRefusesQueriesThatAreNotACombo() {
        // Without the modifier rule, "safari" would be read as a combo and the search would
        // stop being a search.
        XCTAssertNil(ComboQuery.chord(from: "safari"))
        XCTAssertNil(ComboQuery.chord(from: "t"))
        // Without the every-token rule this would become ⌘Safari.
        XCTAssertNil(ComboQuery.chord(from: "cmd safari"))
        XCTAssertNil(ComboQuery.chord(from: ""))
    }

    func testAcceptsSpelledOutKeyNames() {
        XCTAssertEqual(ComboQuery.chord(from: "cmd escape"), KeyChord.combo([.command], KeyToken("esc")))
        XCTAssertEqual(ComboQuery.chord(from: "cmd left arrow"), KeyChord.combo([.command], KeyToken("left")))
    }

    // MARK: - Lookup

    func testSingleOwnerIsStillAnAnswer() {
        guard case .claimed(_, let owners)? = ComboLookup.answer(forQuery: "cmd shift 4", in: items) else {
            return XCTFail("expected a claimed answer")
        }
        XCTAssertEqual(owners.count, 1)
        XCTAssertEqual(owners.first?.title, "Screenshot")
    }

    func testAnUnclaimedComboSaysSo() {
        guard case .free? = ComboLookup.answer(forQuery: "cmd shift 9", in: items) else {
            return XCTFail("expected a free answer")
        }
    }

    func testAPlainTextQueryIsNotALookup() {
        XCTAssertNil(ComboLookup.answer(forQuery: "screenshot", in: items))
    }

    func testLookupAgreesWithTheConflictDetector() {
        // Both group on the chord's cache key, so they can never disagree about ownership.
        let chord = KeyChord.combo([.option, .command], KeyToken("t"))
        XCTAssertEqual(ComboLookup.owners(of: chord, in: items).count, 1)
        XCTAssertTrue(ConflictDetector.conflicts(in: items).contains { $0.chordKey == chord.cacheKey } == false)
    }

    // MARK: - Live test verdicts

    private func observation(
        chord: KeyChord,
        reachedTail: Bool,
        activatedName: String? = nil,
        activatedBundleID: String? = nil,
        frontmostName: String? = nil,
        frontmostBundleID: String? = nil
    ) -> LiveTestObservation {
        LiveTestObservation(
            chord: chord,
            reachedTail: reachedTail,
            activatedAppName: activatedName,
            activatedBundleID: activatedBundleID,
            frontmostAppName: frontmostName,
            frontmostBundleID: frontmostBundleID
        )
    }

    func testKeySwallowedWithOneCandidateNamesIt() {
        let verdict = LiveTestVerdict.evaluate(
            observation: observation(chord: cmdShift4, reachedTail: false),
            expectedChord: cmdShift4,
            items: items
        )
        guard case .swallowedByTap(let candidates) = verdict else {
            return XCTFail("expected swallowedByTap, got \(verdict)")
        }
        // Nothing in `items` hooks the event tap layer, so the honest answer is "something
        // we cannot read" rather than naming an innocent tool.
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(verdict.tone, .informative)
    }

    func testKeyReachingTheTailAndAnAppThatClaimsIt() {
        let verdict = LiveTestVerdict.evaluate(
            observation: observation(
                chord: cmdShift4,
                reachedTail: true,
                activatedName: "Safari",
                activatedBundleID: "com.apple.Safari",
                frontmostName: "Safari",
                frontmostBundleID: "com.apple.Safari"
            ),
            expectedChord: cmdShift4,
            items: items
        )
        guard case .reachedApp(let itemID, let ownerName, let cameToFront) = verdict else {
            return XCTFail("expected reachedApp, got \(verdict)")
        }
        XCTAssertEqual(itemID, items[0].id)
        XCTAssertTrue(cameToFront)
        XCTAssertEqual(verdict.tone, .confirmed)
        // The owner name comes from the app, not from the item, which carries no name.
        XCTAssertEqual(ownerName, "com.apple.Safari")
    }

    func testNothingSeenWhenTheWindowClosesEmpty() {
        let verdict = LiveTestVerdict.evaluate(observation: nil, expectedChord: cmdShift4, items: items)
        XCTAssertEqual(verdict, .nothingSeen)
        XCTAssertEqual(verdict.tone, .inconclusive)
    }

    func testARewrittenKeyIsReportedAsRewritten() {
        let verdict = LiveTestVerdict.evaluate(
            observation: observation(chord: .combo([.command], KeyToken("4")), reachedTail: true),
            expectedChord: cmdShift4,
            items: items
        )
        guard case .rewritten(let expected, let observed) = verdict else {
            return XCTFail("expected rewritten, got \(verdict)")
        }
        // Rendered in canonical modifier order: control, option, shift, command.
        XCTAssertEqual(expected, "⇧⌘4")
        XCTAssertEqual(observed, "⌘4")
    }

    func testSurvivingEveryTapWithoutAWinnerIsInconclusive() {
        let verdict = LiveTestVerdict.evaluate(
            observation: observation(chord: cmdShift4, reachedTail: true),
            expectedChord: cmdShift4,
            items: items
        )
        guard case .survivedUnclaimed = verdict else {
            return XCTFail("expected survivedUnclaimed, got \(verdict)")
        }
        XCTAssertEqual(verdict.tone, .inconclusive)
    }

    func testAnAppNoOneRecordedIsReportedAsUnregistered() {
        let verdict = LiveTestVerdict.evaluate(
            observation: observation(
                chord: cmdShift4,
                reachedTail: true,
                activatedName: "Raycast",
                activatedBundleID: "com.raycast.macos",
                frontmostName: "Safari",
                frontmostBundleID: "com.apple.Safari"
            ),
            expectedChord: cmdShift4,
            items: items
        )
        guard case .unregisteredApp(let name) = verdict else {
            return XCTFail("expected unregisteredApp, got \(verdict)")
        }
        XCTAssertEqual(name, "Raycast")
    }
}
