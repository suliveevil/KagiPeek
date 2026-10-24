import Foundation

/// The state a live shortcut test can be in.
///
/// Moved out of `ShortcutTester` so the session machine (and the XCTest suite) can see it
/// without importing AppKit.
enum ShortcutTestState: Equatable, Sendable {
    case idle
    /// Cannot test right now, with the reason in user-facing words.
    case unavailable(String)
    case listening(secondsRemaining: Int)
    /// The observation, or nil when the window closed without a keypress.
    case finished(LiveTestObservation?)

    /// True when the session cannot test right now (with the reason in `unavailable`'s
    /// payload); the glue uses this to decide whether to continue setting the test up.
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// The live shortcut test as a pure event machine.
///
/// `ShortcutTester` (the AppKit side) owns the real event taps, the workspace and the
/// sleep-based timers; everything it *decides* lives here: when a press counts, whether it
/// reached the tail of the tap chain, which activation belongs to it, what the observation
/// is, and how the state machine transitions. That lets the orchestration be exercised
/// without a keyboard — the two halves meet only at the events below (`keyAtHead`,
/// `keyAtTail`, `appActivated`, `tick`, `settle`).
struct ShortcutTestSession {

    /// How long to listen before giving up. Long enough to switch apps and press something
    /// deliberately, short enough that a forgotten test expires on its own.
    static let listenWindow = 15

    /// How long to wait after the key arrives at the head tap before deciding what happened.
    /// It covers two things at once: the tail tap fires within a millisecond or two if the
    /// key survived, and an app that reacts to a hotkey takes a beat to actually come to the
    /// front.
    static let settleNanoseconds: UInt64 = 600_000_000

    /// How stale an unclaimed tail sighting can be and still belong to the press now
    /// arriving at the head. The two are microseconds apart in practice; this is wide enough
    /// to never matter and narrow enough that an unrelated press of the same combo seconds
    /// earlier can never be mistaken for it.
    static let tailPairingNanoseconds: UInt64 = 50_000_000

    private(set) var state: ShortcutTestState = .idle

    /// The combo the current state belongs to, so a stale result from another row never
    /// shows up under the one now selected.
    private(set) var testedChord: KeyChord?

    /// A press is being settled: the settle window is open and `settle()` will turn it into
    /// an observation.
    var hasPendingPress: Bool { pendingPress != nil }

    private var expectedChord: KeyChord = .empty
    private var pendingPress: PendingPress?
    private var earlyTail: (chord: KeyChord, at: UInt64)?

    private struct PendingPress {
        let chord: KeyChord
        let frontmostAppName: String?
        let frontmostBundleID: String?
        var reachedTail = false
        var activatedAppName: String?
        var activatedBundleID: String?
    }

    // MARK: - Session control

    /// Opens a listening window for `chord`, or lands on `.unavailable` when the
    /// accessibility permission is missing (the reason string is the AppKit-free half of
    /// what `ShortcutTester` used to decide).
    mutating func begin(chord: KeyChord, permissionGranted: Bool) {
        testedChord = chord
        expectedChord = .empty
        pendingPress = nil
        earlyTail = nil
        guard permissionGranted else {
            state = .unavailable(L10n.string(.testUnavailableNoPermission, language: .english))
            return
        }
        expectedChord = chord
        state = .listening(secondsRemaining: Self.listenWindow)
    }

    /// The event-tap layer refused to install the head/tail pair.
    mutating func abortTapsUnavailable() {
        state = .unavailable(L10n.string(.testUnavailableNoTap, language: .english))
    }

    mutating func cancel() {
        state = .idle
        testedChord = nil
        expectedChord = .empty
        pendingPress = nil
        earlyTail = nil
    }

    /// One countdown second passed. `remaining == 0` closes the window without an
    /// observation; a non-listening session ignores the tick.
    mutating func tick(remaining: Int) {
        guard case .listening = state else { return }
        if remaining <= 0 {
            finish(with: nil)
        } else {
            state = .listening(secondsRemaining: remaining)
        }
    }

    // MARK: - Observations

    /// The key arrived at the head of the tap chain, ahead of every other listener.
    ///
    /// Only modifier-combinations are interesting — a bare letter is a keystroke, not a
    /// shortcut — and only when no press is already being settled. A tail sighting that got
    /// here first (`earlyTail`) is paired here if it is recent enough to belong to this
    /// press.
    mutating func keyAtHead(
        chord: KeyChord,
        hasModifier: Bool,
        frontmostAppName: String?,
        frontmostBundleID: String?,
        now: UInt64
    ) {
        guard case .listening = state, pendingPress == nil else { return }
        guard hasModifier else { return }

        var press = PendingPress(
            chord: chord,
            frontmostAppName: frontmostAppName,
            frontmostBundleID: frontmostBundleID
        )
        if let earlyTail, earlyTail.chord.cacheKey == chord.cacheKey {
            let elapsed = now - earlyTail.at
            if elapsed < Self.tailPairingNanoseconds { press.reachedTail = true }
        }
        earlyTail = nil
        pendingPress = press
    }

    /// The key arrived at the tail of the tap chain, behind everyone else. It proves the
    /// press survived the event-tap layer; when it arrives before the head sighting it is
    /// buffered briefly (a run loop makes no promise about the order it drains sources) in
    /// case the head is right behind.
    mutating func keyAtTail(chord: KeyChord, now: UInt64) {
        guard case .listening = state else { return }

        guard var press = pendingPress else {
            earlyTail = (chord, now)
            return
        }
        guard press.chord.cacheKey == chord.cacheKey else { return }
        press.reachedTail = true
        pendingPress = press
    }

    /// An app came to the front. Only activations that follow the press count: handing focus
    /// back at the start of the test raises one too, and it means nothing. The app that was
    /// already frontmost coming back is just focus settling, not a reaction to the shortcut.
    mutating func appActivated(bundleID: String?, name: String?, selfBundleID: String?) {
        guard var press = pendingPress, press.activatedAppName == nil else { return }
        guard let bundleID, bundleID != selfBundleID else { return }
        guard bundleID != press.frontmostBundleID else { return }

        press.activatedAppName = name ?? bundleID
        press.activatedBundleID = bundleID
        pendingPress = press
    }

    /// The settle window after a press closed: the press becomes the observation (or the
    /// session stays where it is when no press is pending, e.g. after a `cancel()`).
    mutating func settle() {
        guard let press = pendingPress else { return }
        finish(with: LiveTestObservation(
            chord: press.chord,
            reachedTail: press.reachedTail,
            activatedAppName: press.activatedAppName,
            activatedBundleID: press.activatedBundleID,
            frontmostAppName: press.frontmostAppName,
            frontmostBundleID: press.frontmostBundleID
        ))
    }

    /// The verdict for a finished test of `chord`, or nil when no test of this combo has
    /// produced one.
    func verdict(
        for chord: KeyChord,
        items: [BindingItem],
        ownerNameForBundleID: (String) -> String? = { _ in nil }
    ) -> LiveTestVerdict? {
        guard testedChord == chord, case .finished(let observation) = state else { return nil }
        return LiveTestVerdict.evaluate(
            observation: observation,
            expectedChord: chord,
            items: items,
            ownerNameForBundleID: ownerNameForBundleID
        )
    }

    // MARK: - Internals

    private mutating func finish(with observation: LiveTestObservation?) {
        pendingPress = nil
        earlyTail = nil
        state = .finished(observation)
    }
}
