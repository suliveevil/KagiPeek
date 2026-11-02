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
///
/// All *decisions* live in `ShortcutTestSession` (see `Core/Pure`): when a press counts,
/// whether it reached the tail, which activation belongs to it, and how the state machine
/// transitions. This class is the AppKit half — the taps, the workspace, the timers — and
/// feeds the session the events it needs.
@MainActor
final class ShortcutTester {

    /// The state a test can be in, re-exported so the engine can type it without knowing
    /// where it lives.
    typealias State = ShortcutTestState

    /// How long to listen before giving up. Long enough to switch apps and press something
    /// deliberately, short enough that a forgotten test expires on its own.
    static let listenWindow = ShortcutTestSession.listenWindow

    var state: ShortcutTestState { machine.state }

    /// The combo the current state belongs to, so a stale result from another row never
    /// shows up under the one now selected.
    var testedChord: KeyChord? { machine.testedChord }

    /// The app to hand focus back to while the test runs. KagiPeek being frontmost would
    /// poison the result: menu shortcuts fire for whoever is in front, and that must not
    /// be us.
    private let appToRestore: () -> NSRunningApplication?

    /// Told when listening starts and stops, so the engine can suspend its own swallowing
    /// and let the key through untouched.
    private let onListeningChanged: (Bool) -> Void

    private var machine = ShortcutTestSession()

    private var headTap: CFMachPort?
    private var tailTap: CFMachPort?
    private var runLoopSources: [CFRunLoopSource] = []
    /// How many times a disabled test tap has been put back during the current test. Reset
    /// when a test installs its taps; see `reenableTaps`.
    private var testTapRetries = 0
    private var activationObserver: NSObjectProtocol?
    private var countdownTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

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
        machine.begin(chord: chord, permissionGranted: PermissionCenter.hasAccessibility)
        guard !machine.state.isUnavailable else { return }
        guard installTaps() else {
            machine.abortTapsUnavailable()
            return
        }

        onListeningChanged(true)
        watchForActivation()
        stepAside()
        startCountdown()
        Diag.info(.tap, "listening for a live shortcut test")
    }

    func cancel() {
        teardown()
        machine.cancel()
    }

    /// The verdict for a finished test of `chord`, or nil when no test of this combo has
    /// produced one.
    func verdict(
        for chord: KeyChord,
        items: [BindingItem],
        ownerNameForBundleID: (String) -> String? = { _ in nil }
    ) -> LiveTestVerdict? {
        machine.verdict(for: chord, items: items, ownerNameForBundleID: ownerNameForBundleID)
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
                guard case .listening = self.machine.state else { return }
                self.machine.tick(remaining: remaining)
                if case .finished = self.machine.state {
                    // The window closed without a press, or the settle beat us to it; the
                    // session is done, so tear the taps down.
                    self.teardown()
                }
            }
        }
    }

    private func teardown() {
        countdownTask?.cancel()
        countdownTask = nil
        settleTask?.cancel()
        settleTask = nil

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
        machine.keyAtHead(
            chord: chord,
            hasModifier: hasModifier,
            frontmostAppName: NSWorkspace.shared.frontmostApplication?.localizedName,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            now: DispatchTime.now().uptimeNanoseconds
        )
        guard machine.hasPendingPress else { return }

        // A press is being settled: stop the countdown (the settle replaces it) and give
        // the key a beat to reach the tail and any app activation to show up.
        countdownTask?.cancel()
        countdownTask = nil

        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ShortcutTestSession.settleNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.machine.settle()
            if case .finished = self.machine.state {
                self.teardown()
            }
        }
    }

    fileprivate func observeAtTail(chord: KeyChord) {
        machine.keyAtTail(chord: chord, now: DispatchTime.now().uptimeNanoseconds)
    }

    /// Puts a disabled test tap back — once.
    ///
    /// These are `listenOnly` taps, so they never hold an event and cannot freeze input the
    /// way the main tap could; the cost of putting one back is churn, not a stalled keyboard.
    /// That is exactly why it still needs a limit: a tap that keeps timing out is a tap whose
    /// callbacks are not running, and re-enabling it forever would keep asking the system for
    /// the same service. After one retry the taps are removed, the countdown finishes on its
    /// own, and the test reports the honest verdict — no press observed — instead of silently
    /// listening to nothing.
    fileprivate func reenableTaps() {
        testTapRetries += 1
        guard testTapRetries <= 1 else {
            Diag.error(.tap, "a test tap kept being disabled; removing it rather than retrying")
            removeTaps()
            return
        }
        for tap in [headTap, tailTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        Diag.debug(.tap, "re-enabled a test tap macOS had disabled")
    }

    private func watchForActivation() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // `queue: .main` is a queue guarantee; the main queue is the main actor's
            // executor, so the assertion below holds. It is asserted rather than hopped
            // because this runs once per app activation and the hop would reorder it behind
            // whatever else is queued. (The previous comment here said "hop explicitly",
            // which is the opposite of what the line does.)
            //
            // Only the two Sendable strings cross into the `assumeIsolated` closure. Under
            // Swift 6.2 that closure is `sending`, and a whole `Notification` is not
            // `Sendable` — passing it in is a region-isolation error. The values the state
            // machine actually needs are extracted here, on the delivering thread.
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier
            let name = app.localizedName
            MainActor.assumeIsolated { self?.appActivated(bundleID: bundleID, name: name) }
        }
    }

    private func appActivated(bundleID: String?, name: String?) {
        machine.appActivated(
            bundleID: bundleID,
            name: name,
            selfBundleID: Bundle.main.bundleIdentifier
        )
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
        testTapRetries = 0

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
        // Resolve the opaque pointer before crossing into the `sending` closure: a raw
        // `UnsafeMutableRawPointer` is not `Sendable`, but `ShortcutTester` is a
        // `@MainActor` class and therefore is. The tap owns this object for its whole life
        // (`passUnretained` at install), so the reference is valid for the hop.
        let tester = Unmanaged<ShortcutTester>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated {
            tester.reenableTaps()
        }
        return passthrough
    }

    guard type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return passthrough }

    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = ModifierSet.from(cgEventFlags: event.flags)
    guard let token = KeyMapper.token(forKeyCode: keyCode) else { return passthrough }
    let chord = KeyChord.combo(modifiers, token)

    let tester = Unmanaged<ShortcutTester>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated {
        if atHead {
            tester.observeAtHead(chord: chord, hasModifier: !modifiers.isEmpty)
        } else {
            tester.observeAtTail(chord: chord)
        }
    }

    return passthrough
}
