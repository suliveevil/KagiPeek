@testable import KagiPeekCore
import XCTest

/// Characterizes the live-shortcut-test orchestration that used to live inside
/// `ShortcutTester` (AppKit): when a press counts, how the head/tail pair is matched, which
/// activation belongs to the press, and how the window closes. The state machine is pure, so
/// every branch is pinned without a keyboard.
final class ShortcutTestSessionTests: XCTestCase {

    // MARK: - Helpers

    private func combo(_ token: KeyToken, _ mods: ModifierSet = []) -> KeyChord {
        KeyChord.combo(mods, token)
    }

    private let cmdA = KeyChord.combo(.command, KeyToken("a"))
    private let cmdB = KeyChord.combo(.command, KeyToken("b"))
    private let plainA = KeyChord.combo([], KeyToken("a"))

    // MARK: - Session control

    func testBeginWithoutPermissionIsUnavailableWithReason() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: false)
        XCTAssertEqual(session.testedChord, cmdA)
        guard case .unavailable(let reason) = session.state else {
            return XCTFail("expected unavailable, got \(session.state)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(session.state.isUnavailable)
    }

    func testBeginWithPermissionStartsListeningAtFullWindow() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        XCTAssertEqual(session.state, .listening(secondsRemaining: ShortcutTestSession.listenWindow))
        XCTAssertEqual(session.testedChord, cmdA)
        XCTAssertFalse(session.state.isUnavailable)
    }

    func testAbortTapsUnavailableKeepsChord() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.abortTapsUnavailable()
        guard case .unavailable = session.state else {
            return XCTFail("expected unavailable, got \(session.state)")
        }
        XCTAssertEqual(session.testedChord, cmdA)
    }

    func testTicksCountDownAndZeroClosesWithoutObservation() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.tick(remaining: 14)
        XCTAssertEqual(session.state, .listening(secondsRemaining: 14))
        session.tick(remaining: 0)
        XCTAssertEqual(session.state, .finished(nil))
    }

    func testTickIgnoredWhenNotListening() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: false)
        session.tick(remaining: 5)
        guard case .unavailable = session.state else {
            return XCTFail("expected unavailable, got \(session.state)")
        }
    }

    func testCancelReturnsToIdleAndForgetsChord() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "A", frontmostBundleID: "a", now: 0)
        session.cancel()
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.testedChord)
        XCTAssertFalse(session.hasPendingPress)
    }

    // MARK: - Head/tail pairing

    func testHeadWithoutModifierIsIgnored() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtHead(chord: plainA, hasModifier: false, frontmostAppName: "A", frontmostBundleID: "a", now: 0)
        XCTAssertFalse(session.hasPendingPress)
        XCTAssertEqual(session.state, .listening(secondsRemaining: ShortcutTestSession.listenWindow))
    }

    func testHeadOutsideListeningIsIgnored() {
        var session = ShortcutTestSession()
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "A", frontmostBundleID: "a", now: 0)
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.hasPendingPress)
    }

    func testSecondHeadWhileSettlingIsIgnored() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "A", frontmostBundleID: "a", now: 0)
        session.keyAtHead(chord: cmdB, hasModifier: true, frontmostAppName: "A", frontmostBundleID: "a", now: 1)
        session.settle()
        guard case .finished(let observation) = session.state else {
            return XCTFail("expected finished, got \(session.state)")
        }
        XCTAssertEqual(observation?.chord, cmdA, "the first press must win; the second head is ignored")
        XCTAssertFalse(observation?.reachedTail ?? true)
    }

    func testTailPairsWithPendingPress() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "A", frontmostBundleID: "a", now: 100)
        session.keyAtTail(chord: cmdA, now: 100)
        session.settle()
        guard case .finished(let observation) = session.state else {
            return XCTFail("expected finished, got \(session.state)")
        }
        XCTAssertEqual(observation?.reachedTail, true)
    }

    func testTailForDifferentChordDoesNotPair() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "A", frontmostBundleID: "a", now: 100)
        session.keyAtTail(chord: cmdB, now: 100)
        session.settle()
        guard case .finished(let observation) = session.state else {
            return XCTFail("expected finished, got \(session.state)")
        }
        XCTAssertEqual(observation?.reachedTail, false)
    }

    // MARK: - Early tail (out-of-order run loop)

    func testEarlyTailPairsWithHeadWithinWindow() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        // The tail got here first, microseconds before the head.
        session.keyAtTail(chord: cmdA, now: 1_000)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "A", frontmostBundleID: "a", now: 1_001)
        session.settle()
        guard case .finished(let observation) = session.state else {
            return XCTFail("expected finished, got \(session.state)")
        }
        XCTAssertEqual(observation?.reachedTail, true, "a tail sighting just before the head belongs to this press")
    }

    func testStaleEarlyTailDoesNotPair() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        // A press of the same combo long ago must never be mistaken for this one.
        session.keyAtTail(chord: cmdA, now: 1_000)
        session.keyAtHead(
            chord: cmdA,
            hasModifier: true,
            frontmostAppName: "A",
            frontmostBundleID: "a",
            now: 1_000 + ShortcutTestSession.tailPairingNanoseconds + 1
        )
        session.settle()
        guard case .finished(let observation) = session.state else {
            return XCTFail("expected finished, got \(session.state)")
        }
        XCTAssertEqual(observation?.reachedTail, false)
    }

    func testEarlyTailForDifferentChordIsDiscardedAtHead() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtTail(chord: cmdB, now: 1_000)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "A", frontmostBundleID: "a", now: 1_001)
        session.settle()
        guard case .finished(let observation) = session.state else {
            return XCTFail("expected finished, got \(session.state)")
        }
        XCTAssertEqual(observation?.reachedTail, false)
    }

    // MARK: - Activation attribution

    func testActivationAfterPressIsRecorded() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "Other", frontmostBundleID: "other", now: 0)
        session.appActivated(bundleID: "reactor", name: "Reactor", selfBundleID: "kagipeek")
        session.settle()
        guard case .finished(let observation) = session.state else {
            return XCTFail("expected finished, got \(session.state)")
        }
        XCTAssertEqual(observation?.activatedBundleID, "reactor")
        XCTAssertEqual(observation?.activatedAppName, "Reactor")
        XCTAssertEqual(observation?.frontmostBundleID, "other")
    }

    func testSelfActivationIsIgnored() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "Other", frontmostBundleID: "other", now: 0)
        session.appActivated(bundleID: "kagipeek", name: "KagiPeek", selfBundleID: "kagipeek")
        session.settle()
        guard case .finished(let observation) = session.state else {
            return XCTFail("expected finished, got \(session.state)")
        }
        XCTAssertNil(observation?.activatedBundleID, "KagiPeek coming back to the front is focus settling")
    }

    func testReturnOfFrontmostAppIsIgnored() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "Other", frontmostBundleID: "other", now: 0)
        session.appActivated(bundleID: "other", name: "Other", selfBundleID: "kagipeek")
        session.settle()
        guard case .finished(let observation) = session.state else {
            return XCTFail("expected finished, got \(session.state)")
        }
        XCTAssertNil(observation?.activatedBundleID)
    }

    func testActivationBeforePressIsIgnored() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        // An activation without a pending press (e.g. stepAside at the start) means nothing.
        session.appActivated(bundleID: "reactor", name: "Reactor", selfBundleID: "kagipeek")
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "Other", frontmostBundleID: "other", now: 0)
        session.appActivated(bundleID: "reactor", name: "Reactor", selfBundleID: "kagipeek")
        session.settle()
        guard case .finished(let observation) = session.state else {
            return XCTFail("expected finished, got \(session.state)")
        }
        XCTAssertEqual(observation?.activatedBundleID, "reactor")
    }

    func testSettleWithoutPressDoesNothing() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.settle()
        XCTAssertEqual(session.state, .listening(secondsRemaining: ShortcutTestSession.listenWindow))
    }

    // MARK: - Verdicts

    func testVerdictNilForOtherChord() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.tick(remaining: 0)
        XCTAssertNotNil(session.verdict(for: cmdA, items: []))
        XCTAssertNil(session.verdict(for: cmdB, items: []), "a verdict belongs to the tested chord only")
    }

    func testVerdictNilUnlessFinished() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        XCTAssertNil(session.verdict(for: cmdA, items: []))
        session.tick(remaining: 0)
        XCTAssertEqual(session.verdict(for: cmdA, items: []), .nothingSeen)
    }

    func testVerdictSurvivedWhenTailReachedAndNoActivation() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "App", frontmostBundleID: "app", now: 0)
        session.keyAtTail(chord: cmdA, now: 0)
        session.settle()
        XCTAssertEqual(session.verdict(for: cmdA, items: []), .survivedUnclaimed(ruledOut: []))
    }

    func testVerdictSwallowedWhenTailNeverReached() {
        var session = ShortcutTestSession()
        session.begin(chord: cmdA, permissionGranted: true)
        session.keyAtHead(chord: cmdA, hasModifier: true, frontmostAppName: "App", frontmostBundleID: "app", now: 0)
        session.settle()
        XCTAssertEqual(session.verdict(for: cmdA, items: []), .swallowedByTap(candidates: []))
    }
}
