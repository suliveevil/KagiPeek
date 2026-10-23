import AppKit
import CoreGraphics
import Foundation
import os

/// Watches one real keypress and reports what happened to it.
///
/// The scan can only read what tools wrote down, so the winner it names is an educated
/// guess. This is the other half of the answer: press the key and see.
///
/// The trick is listening twice. macOS keeps event taps in an ordered chain, and a tap that
/// claims a key stops it dead. So one listener goes in at the head of that chain, ahead of
/// everyone, and another at the tail, behind everyone all. If the head hears the key and the
/// tail never does, some other app's tap ate it in between. That is a fact rather than an
/// inference, and it is the one thing config files can never tell us.
///
/// Both taps are listen-only. KagiPeek must never be able to change or swallow a key while
/// it is supposed to be watching one, and a passive tap also cannot break the shortcut it
/// is measuring.
@MainActor
final class ShortcutTester {

    enum State: Equatable {
        case idle
        /// Cannot test right now, with the reason in user-facing words.
        case unavailable(String)
        case listening(secondsRemaining: Int)
        /// The observation, or nil when the window closed without a keypress.
        case finished(LiveTestObservation?)
    }

    /// How long to listen before giving up. Long enough to switch apps and press something
    /// deliberately, short enough that a forgotten test expires on its own.
    static let listenWindow = 15

    /// How long to wait after the key arrives at the head tap before deciding what happened.
    /// It covers two things at once: the tail tap fires within a millisecond or two if the
    /// key survived, and an app that reacts to a hotkey takes a beat to actually come to the
    /// front.
    private static let settleNanoseconds: UInt64 = 600_000_000

    /// How stale an unclaimed tail sighting can be and still belong to the press now
    /// arriving at the head. The two are microseconds apart in practice; this is wide enough
    /// to never matter and narrow enough that an unrelated press of the same combo seconds
    /// earlier can never be mistaken for it.
    private static let tailPairingNanoseconds: UInt64 = 50_000_000

    private(set) var state: State = .idle

    /// The combo the current state belongs to, so a stale result from another row never
    /// shows up under the one now selected.
    private(set) var testedChord: KeyChord?

    /// The app to hand focus back to while the test runs. KagiPeek being frontmost would
    /// poison the result: menu shortcuts fire for whoever is in front, and that must not
    /// be us.
    private let appToRestore: () -> NSRunningApplication?

    /// Told when listening starts and stops, so the engine can suspend its own swallowing
    /// and let the key through untouched.
    private let onListeningChanged: (Bool) -> Void

    private var headTap: CFMachPort?
    private var tailTap: CFMachPort?
    private var runLoopSources: [CFRunLoopSource] = []
    private var activationObserver: NSObjectProtocol?
    private var countdownTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    private var expectedChord: KeyChord = .empty
    private var pendingPress: PendingPress?

    private struct PendingPress {
        let chord: KeyChord
        let frontmostAppName: String?
        let frontmostBundleID: String?
        var reachedTail = false
        var activatedAppName: String?
        var activatedBundleID: String?
    }

    /// A tail sighting that arrived before its head sighting did.
    ///
    /// The two taps are separate run loop sources, and a run loop makes no promise about
    /// the order it drains sources signalled in the same pass. Getting this backwards would
    /// report the key as swallowed by an event tap when nothing touched it — the one claim
    /// this feature must not get wrong — so the tail is allowed to arrive first and wait.
    private var earlyTail: (chord: KeyChord, at: UInt64)?

    init(
        appToRestore: @escaping () -> NSRunningApplication?,
        onListeningChanged: @escaping (Bool) -> Void
    ) {
        self.appToRestore = appToRestore
        self.onListeningChanged = onListeningChanged
    }

    // MARK: - Running a test

    func start(for chord: KeyChord) {
        teardown()
        testedChord = chord

        guard PermissionCenter.hasAccessibility else {
            state = .unavailable(L10n.string(.testUnavailableNoPermission, language: .english))
            return
        }
        guard installTaps() else {
            state = .unavailable(L10n.string(.testUnavailableNoTap, language: .english))
            return
        }

        expectedChord = chord
        pendingPress = nil
        state = .listening(secondsRemaining: Self.listenWindow)
        onListeningChanged(true)
        watchForActivation()
        stepAside()
        startCountdown()
        AppLog.input.notice("listening for a live shortcut test")
    }

    func cancel() {
        teardown()
        state = .idle
        testedChord = nil
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

    // MARK: - Flow

    private func stepAside() {
        appToRestore()?.activate()
    }

    private func startCountdown() {
        countdownTask = Task { [weak self] in
            for remaining in stride(from: Self.listenWindow - 1, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard case .listening = state else { return }
                if remaining == 0 {
                    finish(with: nil)
                } else {
                    state = .listening(secondsRemaining: remaining)
                }
            }
        }
    }

    private func finish(with observation: LiveTestObservation?) {
        teardown()
        state = .finished(observation)
    }

    private func teardown() {
        countdownTask?.cancel()
        countdownTask = nil
        settleTask?.cancel()
        settleTask = nil
        pendingPress = nil
        earlyTail = nil

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }

        removeTaps()

        // Only ever a resume: this runs at the end of a test, never at the start.
        onListeningChanged(false)
    }

    // MARK: - Observing

    fileprivate func observeAtHead(chord: KeyChord, hasModifier: Bool) {
        guard case .listening = state, pendingPress == nil else { return }
        // A bare letter is a keystroke, not a shortcut. Without this filter a stray keypress
        // while switching apps would end the test on the wrong combo.
        guard hasModifier else { return }

        var press = PendingPress(
            chord: chord,
            frontmostAppName: NSWorkspace.shared.frontmostApplication?.localizedName,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        // The tail may have got here first. If it did, this press already has its answer and
        // the settle delay is only waiting on an app activation.
        if let earlyTail, earlyTail.chord.cacheKey == chord.cacheKey {
            let elapsed = DispatchTime.now().uptimeNanoseconds - earlyTail.at
            if elapsed < Self.tailPairingNanoseconds { press.reachedTail = true }
        }
        earlyTail = nil
        pendingPress = press

        countdownTask?.cancel()
        countdownTask = nil

        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.settleNanoseconds)
            guard !Task.isCancelled, let self, let press = pendingPress else { return }
            finish(with: LiveTestObservation(
                chord: press.chord,
                reachedTail: press.reachedTail,
                activatedAppName: press.activatedAppName,
                activatedBundleID: press.activatedBundleID,
                frontmostAppName: press.frontmostAppName,
                frontmostBundleID: press.frontmostBundleID
            ))
        }
    }

    fileprivate func observeAtTail(chord: KeyChord) {
        guard case .listening = state else { return }

        guard var press = pendingPress else {
            // No head sighting yet: either a key we are not interested in, or the run loop
            // handed us the two sources out of order. Hold it briefly in case the head is
            // right behind.
            earlyTail = (chord, DispatchTime.now().uptimeNanoseconds)
            return
        }
        guard press.chord.cacheKey == chord.cacheKey else { return }
        press.reachedTail = true
        pendingPress = press
    }

    fileprivate func reenableTaps() {
        for tap in [headTap, tailTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        AppLog.input.debug("re-enabled a test tap macOS had disabled")
    }

    private func watchForActivation() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Delivered on the main queue, which is a queue guarantee rather than an actor
            // one, so hop explicitly.
            MainActor.assumeIsolated { self?.appActivated(notification) }
        }
    }

    private func appActivated(_ notification: Notification) {
        // Only activations that follow the press count. Handing focus back at the start of
        // the test raises one of these too, and it means nothing.
        guard var press = pendingPress, press.activatedAppName == nil else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        // The app the user was already in coming back to the front is just focus settling,
        // not an app reacting to the shortcut.
        guard app.bundleIdentifier != press.frontmostBundleID else { return }

        press.activatedAppName = app.localizedName ?? app.bundleIdentifier
        press.activatedBundleID = app.bundleIdentifier
        pendingPress = press
    }

    // MARK: - Taps

    private func installTaps() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        // Unretained is safe because the tester outlives every tap it creates: teardown
        // always runs before this object goes away.
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let head = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: headTapCallback,
            userInfo: context
        ), let tail = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: tailTapCallback,
            userInfo: context
        ) else {
            // One of the two may have been created; clear up rather than leave a
            // half-installed pair listening with nothing to report to.
            removeTaps()
            return false
        }

        headTap = head
        tailTap = tail

        for tap in [head, tail] {
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { continue }
            // The main run loop on purpose: it puts the callbacks on the main thread, which
            // is what lets them talk to this main-actor type directly.
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSources.append(source)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return true
    }

    private func removeTaps() {
        for source in runLoopSources {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSources.removeAll()

        for tap in [headTap, tailTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        headTap = nil
        tailTap = nil
    }
}

// MARK: - Tap callbacks

private nonisolated func headTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    handleTapEvent(type: type, event: event, userInfo: userInfo, atHead: true)
}

private nonisolated func tailTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    handleTapEvent(type: type, event: event, userInfo: userInfo, atHead: false)
}

private nonisolated func handleTapEvent(
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?,
    atHead: Bool
) -> Unmanaged<CGEvent>? {
    // Always hand the event straight back. This tap observes and nothing more.
    let passthrough = Unmanaged.passUnretained(event)
    guard let userInfo else { return passthrough }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            Unmanaged<ShortcutTester>.fromOpaque(userInfo).takeUnretainedValue().reenableTaps()
        }
        return passthrough
    }

    guard type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return passthrough }

    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = KeyboardMonitor.modifiers(from: event.flags)
    guard let token = KeyMapper.token(forKeyCode: keyCode) else { return passthrough }
    let chord = KeyChord.combo(modifiers, token)

    MainActor.assumeIsolated {
        let tester = Unmanaged<ShortcutTester>.fromOpaque(userInfo).takeUnretainedValue()
        if atHead {
            tester.observeAtHead(chord: chord, hasModifier: !modifiers.isEmpty)
        } else {
            tester.observeAtTail(chord: chord)
        }
    }

    return passthrough
}
