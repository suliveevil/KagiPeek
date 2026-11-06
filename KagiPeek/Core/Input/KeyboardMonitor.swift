import AppKit
import CoreGraphics
import os
// DispatchWorkItem / DispatchQueue's `Sendable` annotations still lag the Swift 6 SDK;
// without this the compiler reports them as non-Sendable even where a `@Sendable` closure
// is the correct contract. It suppresses the import's legacy annotations, not our checks.
@preconcurrency import Dispatch

enum KeyboardMonitorError: LocalizedError {
    case accessibilityDenied
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied: return L10n.string(.errorNoAccessibility, language: .english)
        case .tapCreationFailed: return L10n.string(.errorEventTap, language: .english)
        }
    }
}

/// Global key tap.
///
/// The tap is *active* (not listen-only) so configured global hotkeys can be swallowed
/// instead of also reaching the front app. Everything else is passed through untouched.
///
/// The run-loop source lives on a **dedicated thread**, not the main run loop. This is the
/// root fix for a class of failures measured four times on macOS 27 (2026-11-02): with the
/// callback on the main run loop, any main-thread wedge — Kaname's or the system's —
/// left the tap enabled in front of a callback that could not run, and every key and click
/// in the session waited out the tap's timeout. Three of the four episodes ended in a
/// power-button reset. On its own thread the callback keeps running no matter what the
/// main thread is doing, the swallow decision is answered from a published snapshot
/// (`ComposedSwallowState`) instead of a synchronous main-actor call, and events are
/// handed to the engine asynchronously — a wedged main thread can delay the panel by a
/// hop, but it can no longer delay the input stream at all.
/// `@unchecked Sendable` is a contract this file already keeps: every mutable property below
/// is read and written only inside `withLock`, and the four callback properties are assigned
/// once before `start()` and only read (never written) afterwards, on the tap thread. The
/// lock is why sharing the instance between the main actor and the dedicated tap thread is
/// sound; the unchecked conformance is what tells Swift 6 that it is *our* invariant, since
/// a lock cannot be expressed in the type system. `nonisolated` is load-bearing too: the tap
/// callback runs on its own thread and must never be tied to the main actor.
nonisolated final class KeyboardMonitor: @unchecked Sendable {
    /// Called on the **main** thread (via an async hop) for every event; the engine owns
    /// the panel behaviour that follows.
    var onEvent: (@Sendable (KeyEvent) -> Void)?

    /// Why a tap that the system disabled is being taken down instead of put back.
    enum TeardownReason: String {
        /// The process no longer holds Accessibility, so the tap can never be re-armed.
        case permissionLost
        /// It was disabled repeatedly with nothing getting through in between.
        case unresponsive
    }

    /// Fired after `stop()` was called from inside the tap callback, so the owner can say so.
    var onTeardown: (@Sendable (TeardownReason) -> Void)?

    /// Whether the process still holds Accessibility. Injected so the trust branch can be
    /// driven without touching TCC.
    var hasAccessibility: @Sendable () -> Bool = { PermissionCenter.hasAccessibility }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isRunning = false
    /// The thread the tap drains on; owned by `start()`, never joined synchronously.
    private var tapThread: Thread?
    /// The run loop the tap source is scheduled on — the tap thread's own, never main's.
    private var tapRunLoop: CFRunLoop?
    private let lock = NSLock()
    /// The keystrokes this tap owns: the user's global hotkeys, the panel's navigation keys
    /// and Escape. One value instead of three parallel collections, so the decision and the
    /// data it reads cannot drift apart — see `KeySwallowRules`, where it is tested.
    private var swallowRules = KeySwallowRules()
    /// Physical modifier keys whose `flagsChanged` events are swallowed: the trigger key's
    /// press and release while the gesture is live. Shift and Caps Lock are never in here.
    private var modifierSwallowKeyCodes: Set<UInt16> = []
    private var decodesKeyEvents = false
    /// While a surface owns the pointer, the rects a click has to fall between for the tap to
    /// eat it: inside the front app's window — that is where a stray click changes the
    /// insertion point or the selection — but outside the surface itself.
    private var swallowOutside: (panel: ScreenRect, app: ScreenRect)?
    /// The button whose press was swallowed, so its release is swallowed too: a release
    /// without a press is its own kind of surprise for the app that receives it.
    private var swallowedMouseButton: Int64?
    /// The key code of a key-down this tap consumed, so its release is consumed too.
    ///
    /// Matching on the press is not enough: the modifiers can change between the two events
    /// (⌘ released before the key it modified), which is exactly when the identifier stops
    /// matching and the front app is left holding a key that never came up. A composed
    /// stroke makes this certain — the panel dismisses itself on the key-down, so by the
    /// release there is no tick left to recognise and the event would slip through.
    private var swallowedKeyDownCode: UInt16?

    /// How many times the tap has been put back without an event getting through in between.
    private var health = TapHealth()
    /// A re-enable that is waiting out its backoff, so a burst of disables does not pile up
    /// attempts and burn the whole budget in one stalled second. Scheduled on the tap run
    /// loop — a wedged main thread must not be able to keep a dead tap installed.
    private var pendingReEnable: DispatchWorkItem? = nil
    /// Whether a re-enable is on the books. Kept in step with `pendingReEnable` under the
    /// same lock, including the paths where the work item is cancelled or never scheduled.
    private var recoveryGate = TapRecoveryGate()

    // MARK: Input watchdog

    /// The failure no in-tap counter can see: a disable notification is delivered through
    /// the callback itself, so a wedged main thread silences `TapHealth` exactly when it
    /// matters — tap enabled, callback unable to run, input stream frozen, log empty.
    /// Since the tap got its own thread, the watched thread is the tap thread, not main.
    /// See `InputWatchdog`.
    private var watchdog = InputWatchdog()
    private var watchdogTimer: DispatchSourceTimer?
    /// Whether the ping issued at the previous watchdog tick has been answered; written on
    /// the tap thread, read on the watchdog queue.
    private var pingAcknowledged = false
    /// Mirrors `watchdog.tapDetached` under `lock`, so the callback (tap thread) can see
    /// what the watchdog queue decided without touching its state.
    private var tapDetachedByWatchdog = false
    /// When the tap was last turned on, so a disable can report how long it survived. The
    /// distinction matters: a timeout a second after the re-enable means the events never
    /// reach the callback, a timeout a minute later is a new episode.
    private var lastEnableAt: Date?
    /// The engine's copy of the event stream, bounded and drained in batches.
    ///
    /// One `DispatchQueue.main.async` per event made the hand-over an unbounded queue: a main
    /// thread stuck for thirty seconds accumulated every keystroke typed during it and then
    /// replayed them all at once. See `InputMailbox` for why a drop here is safe.
    private var mailbox = InputMailbox()
    /// Whether a drain is already in flight. Set when the mailbox asks for one, cleared when
    /// the drain runs, so a burst costs one hop instead of one per event.
    private var drainScheduled = false

    /// Runs `body` with the lock held.
    ///
    /// One idiom for the shared state, because the file used to mix hand-written pairs with
    /// `defer` and a missed `unlock` on one path is a deadlock in the input stream — the
    /// worst place in this program to find out.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Whether the engine currently needs characters. Decoding runs on the event-tap thread
    /// for every key press in the session, so it is only on while a surface is reading keys
    /// or a binding is being recorded.
    func updateDecodesKeyEvents(_ value: Bool) {
        withLock { decodesKeyEvents = value }
    }

    private var needsCharacters: Bool {
        withLock { decodesKeyEvents }
    }

    func updateSwallowRules(_ rules: [SwallowRule]) {
        withLock { swallowRules.rules = rules }
    }

    /// Publishes the modifier keys the trigger gesture owns. The tap answers this on its own
    /// thread, so a cancelled hold cannot replay the press it already swallowed.
    func updateModifierSwallow(keyCodes: Set<UInt16>) {
        withLock { modifierSwallowKeyCodes = keyCodes }
    }

    /// The engine's picture of the composed-stroke state, published after every change that
    /// affects the swallow decision. The tap thread reads it instead of calling the engine:
    /// the engine keeps the main actor, the input path keeps its own thread.
    func updateComposedSwallowState(_ state: ComposedSwallowState) {
        withLock { composedSwallowState = state }
    }

    private var composedSwallowState = ComposedSwallowState()

    /// Keys the panel is currently using for navigation (↑↓←→↵Esc). They are consumed
    /// while the panel is pinned so the front app does not also react to them.
    func updateCapturedKeys(_ identifiers: Set<UInt32>) {
        withLock { swallowRules.capturedIdentifiers = identifiers }
    }

    /// Keys consumed regardless of modifiers (used for Esc).
    func updateCapturedKeyCodes(_ keyCodes: Set<UInt16>) {
        withLock { swallowRules.capturedKeyCodes = keyCodes }
    }

    /// Characters the panel is using as paging keys. A CJK layout types `；` where the ANSI
    /// code is the semicolon, so the character channel is what makes the pair work there.
    func updateCapturedCharacters(_ characters: Set<Character>) {
        withLock { swallowRules.capturedCharacters = characters }
    }

    /// Arms the click that dismisses a surface: pressing inside `appWindowFrame` but outside
    /// `panelFrame` closes the surface and is swallowed, so the app behind it never sees it.
    ///
    /// Pass nil to disarm. Clicks anywhere else — the menu bar, the Dock, the desktop,
    /// another app's window — are always passed through: those are the user reaching for
    /// something else, and eating them would make the panel feel like it had frozen the
    /// screen.
    func updateOutsideMouseSwallow(panelFrame: CGRect?, appWindowFrame: CGRect?) {
        withLock {
            if let panelFrame, let appWindowFrame {
                swallowOutside = (Self.screenRect(panelFrame), Self.screenRect(appWindowFrame))
            } else {
                swallowOutside = nil
                swallowedMouseButton = nil
            }
        }
    }

    private static func screenRect(_ rect: CGRect) -> ScreenRect {
        ScreenRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    /// Called on the tap thread for a press the tap swallowed; the monitor hops it to the
    /// main thread before invoking, so the owner never sees a foreign queue.
    var onOutsideMousePress: (@Sendable () -> Void)?

    func start() throws {
        guard tap == nil else { return }
        guard PermissionCenter.hasAccessibility else { throw KeyboardMonitorError.accessibilityDenied }

        withLock {
            pendingReEnable?.cancel()
            pendingReEnable = nil
            recoveryGate.finish()
        }

        // Assembled statement-by-statement: one long `|` chain — even with typed bases —
        // exceeds the type-check budget of Xcode 16.4 (the CI toolchain), while the
        // split form compiles quickly everywhere.
        let eventTypes: [CGEventType] = [
            .flagsChanged, .keyDown, .keyUp,
            // The mouse is here for one reason: the click that dismisses the panel must not
            // also reach the app behind it. Everything else is passed straight through.
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .tapDisabledByTimeout, .tapDisabledByUserInput
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, eventType in
            partial | (CGEventMask(1) << CGEventMask(eventType.rawValue))
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw KeyboardMonitorError.tapCreationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            // The tap exists but nothing ever drains it: every shortcut in the session is
            // dead, and there is no error path to say so. Roll the half-built tap back so
            // the next `start()` sees `tap == nil` and can retry instead of silently
            // returning because a dead port was left installed.
            Diag.error(.tap, "run-loop source creation failed: the tap will never deliver events")
            CGEvent.tapEnable(tap: created, enable: false)
            CFMachPortInvalidate(created)
            throw KeyboardMonitorError.tapCreationFailed
        }
        tap = created
        self.source = source
        enableTap(created)
        isRunning = true

        withLock {
            watchdog.reset()
            tapDetachedByWatchdog = false
        }
        startWatchdog()

        // The tap's run loop is this thread's own — the point of the whole refactor. The
        // source is added here, on the thread that drains it, as CFRunLoopAddSource
        // requires; nothing about the tap depends on the main thread after this.
        let thread = Thread { [weak self] in self?.tapThreadMain() }
        thread.name = "Kaname event tap"
        tapThread = thread
        thread.start()
    }

    /// Body of the dedicated tap thread. Blocks until `stop()` calls `CFRunLoopStop`.
    private func tapThreadMain() {
        let runLoop = CFRunLoopGetCurrent()
        // A stop() that raced the launch leaves nothing to schedule: the loop below exits
        // immediately and the thread dies.
        let source = withLock { () -> CFRunLoopSource? in
            guard isRunning, let source else {
                tapRunLoop = nil
                return nil
            }
            health.reset()
            tapRunLoop = runLoop
            return source
        }
        guard let source else { return }

        CFRunLoopAddSource(runLoop, source, CFRunLoopMode.defaultMode)
        CFRunLoopRun()
        CFRunLoopRemoveSource(runLoop, source, CFRunLoopMode.defaultMode)

        withLock { tapRunLoop = nil }
    }

    func stop() {
        stopWatchdog()
        withLock {
            pendingReEnable?.cancel()
            pendingReEnable = nil
            recoveryGate.finish()
        }
        let (tapPort, runLoop) = withLock { () -> (CFMachPort?, CFRunLoop?) in
            let ports = (tap, tapRunLoop)
            tap = nil
            source = nil
            isRunning = false
            health.reset()
            lastEnableAt = nil
            mailbox.reset()
            drainScheduled = false
            return ports
        }
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    var isActive: Bool { isRunning }

    // MARK: - Recovery

    /// The system disabled the tap. Put it back — but never in a loop that costs the user
    /// their keyboard.
    ///
    /// A disabled tap is harmless: the next event goes straight to the front app. A tap that
    /// is re-enabled in front of a callback that still cannot run is not — every event then
    /// waits out the tap's timeout first. So the pause is the fix, and giving up is the last
    /// resort that keeps input moving at the price of this session's shortcuts.
    ///
    /// Runs on the tap thread: disable notifications arrive through the callback, which now
    /// lives off main — so the recovery keeps working while the main thread is wedged.
    private func handleDisable(trigger: TapDiagnostics.Trigger) {
        guard let tapPort = withLock({ tap }), withLock({ isRunning }) else { return }
        // Already waiting out a pause: the tap is off and further notifications describe the
        // same failure, not a new one. The gate is cleared on every exit path of the pending
        // work item, so a failed recovery cannot lock this out for the rest of the session.
        guard withLock({ recoveryGate.shouldHandleDisable(isRunning: isRunning) }) else { return }

        let trusted = hasAccessibility()
        let recovery = withLock { health.recordDisable(trusted: trusted) }
        let report = TapDiagnostics(
            trigger: trigger,
            attempt: withLock { health.consecutiveDisables },
            trusted: trusted,
            enabled: CGEvent.tapIsEnabled(tap: tapPort),
            stoodForMilliseconds: withLock {
                lastEnableAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            },
            recovery: recovery
        )
        Diag.warning(.tap, report.line)

        // The panel releases whatever it was holding: keys pressed during the stall are gone.
        emit(KeyEvent(kind: .interruption, modifiers: [], key: nil, keyCode: 0, isRepeat: false, happenedAt: Date()))

        switch recovery {
        case let .reEnable(delay):
            // The watchdog detached the tap because the tap thread is wedged: putting it
            // back from here would re-create the freeze the watchdog just ended.
            guard !withLock({ tapDetachedByWatchdog }) else { return }
            if delay > 0 {
                scheduleReEnable(tapPort, after: delay)
            } else {
                enableTap(tapPort)
            }

        case .tearDown:
            let why: TeardownReason = trusted ? .unresponsive : .permissionLost
            stop()
            Diag.error(.tap, "event tap torn down (\(why.rawValue)): " + report.detail)
            let handler = onTeardown
            DispatchQueue.main.async {
                handler?(why)
            }
        }
    }

    /// Waits out the pause on the tap's own run loop.
    ///
    /// A wedged main thread must not be able to hold a dead tap installed — the tap's
    /// recovery belongs to the tap's thread, the same one that answers its events. The safety
    /// net cancels the work item if the run loop never drains it, so a stopped tap cannot
    /// leave a pending re-enable behind.
    private func scheduleReEnable(_ tapPort: CFMachPort, after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Every exit from this work item reopens the gate, including the early return
            // when the monitor was stopped while the pause was pending.
            defer {
                withLock {
                    self.pendingReEnable = nil
                    self.recoveryGate.finish()
                }
            }
            guard withLock({ self.isRunning }) else { return }
            self.enableTap(tapPort)
        }
        let runLoop = withLock { () -> CFRunLoop? in
            pendingReEnable = work
            recoveryGate.schedule()
            return tapRunLoop
        }
        guard let runLoop else {
            // No run loop to drain the work item: leaving the gate closed would drop every
            // later disable notification until relaunch. Clear both before returning.
            withLock {
                work.cancel()
                pendingReEnable = nil
                recoveryGate.finish()
            }
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak work] in
            work?.perform()
        }
        CFRunLoopWakeUp(runLoop)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay + 5) { [weak self, weak work] in
            guard let self, let work, work.isCancelled == false else { return }
            work.cancel()
            // A cancelled work item never runs its `defer`, so clear the bookkeeping here.
            // Guarded by identity: this stale safety net must not clear a newer recovery.
            withLock {
                if self.pendingReEnable === work {
                    self.pendingReEnable = nil
                    self.recoveryGate.finish()
                }
            }
        }
    }

    /// Turns the tap on and remembers when, so the next disable can say how long it stood.
    private func enableTap(_ tapPort: CFMachPort) {
        let now = Date()
        withLock { lastEnableAt = now }
        CGEvent.tapEnable(tap: tapPort, enable: true)
    }

    // MARK: - Input watchdog

    private static let watchdogInterval: TimeInterval = 1.5

    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.voltline.kagipeek.tap-watchdog"))
        timer.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        withLock {
            pingAcknowledged = false
            tapDetachedByWatchdog = false
        }
    }

    /// Runs on the watchdog queue. Pings the tap thread once per interval; the answer to
    /// the *previous* ping decides what this tick does.
    ///
    /// The watched thread is the one the callback lives on, not main: since the refactor,
    /// main can no longer stall the input path, but the tap's own thread can still wedge —
    /// and the system's timeout-disable is what keeps input alive then, so the watchdog's
    /// job is to make the detachment permanent instead of letting `handleDisable` put a
    /// wedged tap straight back.
    private func watchdogTick() {
        let (acknowledged, tapPort, running, watchedLoop) = withLock {
            let snapshot = (pingAcknowledged, tap, isRunning, tapRunLoop)
            pingAcknowledged = false
            return snapshot
        }

        guard running, let tapPort, let watchedLoop else { return }

        // A no-op on the tap's run loop: if it has not run by the next tick, the thread
        // draining the callback has been unresponsive for an interval.
        CFRunLoopPerformBlock(watchedLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            self.withLock { self.pingAcknowledged = true }
        }
        CFRunLoopWakeUp(watchedLoop)

        // The state lives under the shared lock: start()/stop() reset it from the main
        // thread while this queue may be mid-tick.
        let (action, ticks) = withLock { () -> (InputWatchdog.Action, Int) in
            var watchdog = self.watchdog
            let action = watchdog.tick(acknowledged: acknowledged)
            self.watchdog = watchdog
            return (action, watchdog.unresponsiveTicks)
        }

        switch action {
        case .none:
            break

        case .detachTap:
            withLock { tapDetachedByWatchdog = true }
            // From outside the wedged thread: a disabled tap is harmless, so this is what
            // frees the input stream.
            CGEvent.tapEnable(tap: tapPort, enable: false)
            Diag.error(.tap, "input watchdog: tap thread unresponsive for \(ticks) ticks with the tap enabled — detaching the tap to free the input stream")

        case .reattachTap:
            withLock { tapDetachedByWatchdog = false }
            CFRunLoopPerformBlock(watchedLoop, CFRunLoopMode.defaultMode.rawValue) {
                CGEvent.tapEnable(tap: tapPort, enable: true)
            }
            CFRunLoopWakeUp(watchedLoop)
            Diag.info(.tap, "input watchdog: tap thread recovered — tap re-enabled")
        }
    }

    // MARK: - Callback

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type != .tapDisabledByTimeout, type != .tapDisabledByUserInput {
            // This event got through, which is the only proof that matters: whatever went
            // wrong before, the tap is answering now. (Locked because stop() also resets
            // the health from the main thread.)
            withLock { health.recordEvent() }
        }
        switch type {
        case .flagsChanged:
            // The key code is what tells left from right (55/54 ⌘, 58/61 ⌥, 59/62 ⌃), so it
            // cannot stay the placeholder 0: the trigger gesture reads it.
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            emit(KeyEvent(
                kind: .flagsChanged,
                modifiers: ModifierSet.from(cgEventFlags: event.flags),
                key: nil,
                keyCode: keyCode,
                isRepeat: false,
                happenedAt: Date()
            ))
            // Never eat a modifier while a popup menu is up: Dock's "Force Quit" only
            // shows up while Option is held over the item, so swallowing it would break
            // the menu instead of merely suppressing Kaname.
            let armed = withLock { modifierSwallowKeyCodes.contains(keyCode) }
            let consume = armed && !PopupGate.menuPresent()
            return consume ? nil : Unmanaged.passUnretained(event)

        case .keyDown:
            let (keyCode, keyEvent) = describe(event, kind: .keyDown)
            // A repeat of a captured key has to be consumed too: letting it through would
            // move the panel selection and scroll the front app at the same time.
            let consume = shouldSwallow(
                keyCode: keyCode,
                modifiers: keyEvent.modifiers,
                characters: keyEvent.characters
            ) || shouldSwallowComposed(keyEvent)
            if consume { recordSwallowedKeyDown(keyCode) }
            emit(keyEvent)
            return consume ? nil : Unmanaged.passUnretained(event)

        case .keyUp:
            let (keyCode, keyEvent) = describe(event, kind: .keyUp)
            // Consumed on release as well: swallowing the press but not the release would
            // leave the front app holding a key that never came up. The press is remembered
            // by key code because the modifiers may have changed under it.
            let releaseOfSwallowedPress = takeSwallowedKeyDown(keyCode)
            let consume = shouldSwallow(
                keyCode: keyCode,
                modifiers: keyEvent.modifiers,
                characters: keyEvent.characters
            ) || shouldSwallowComposed(keyEvent) || releaseOfSwallowedPress
            emit(keyEvent)
            return consume ? nil : Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return handleMouseDown(event)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return handleMouseUp(event)

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            handleDisable(trigger: type == .tapDisabledByTimeout ? .timeout : .userInput)
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Reads the fields the engine cares about out of the raw event.
    ///
    /// `keyDown` and `keyUp` used to repeat this fourteen-line block verbatim, and the copies
    /// had already drifted: only one carried the typed characters, and only one read the
    /// autorepeat flag. Neither difference was a decision — they were both accidents of
    /// which one was written second, which is the argument for building it in one place.
    ///
    /// The typed characters are attached to a press only: a release cannot type.
    private func describe(_ event: CGEvent, kind: KeyEventKind) -> (keyCode: UInt16, event: KeyEvent) {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = ModifierSet.from(cgEventFlags: event.flags)
        let unicode = needsCharacters ? Self.unicodeString(from: event) : nil
        let isPress = kind == .keyDown
        let keyEvent = KeyEvent(
            kind: kind,
            modifiers: modifiers,
            key: unicode.flatMap { KeyMapper.token(keyCode: keyCode, unicode: $0, modifiers: modifiers) },
            keyCode: keyCode,
            isRepeat: isPress && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            happenedAt: Date(),
            characters: isPress ? unicode : nil
        )
        return (keyCode, keyEvent)
    }

    /// A press inside the front app's window but outside the surface: close the surface and
    /// eat the click.
    private func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let point = event.location
        let bounds = withLock { swallowOutside }
        guard let bounds else { return Unmanaged.passUnretained(event) }
        guard OutsideClickPolicy.shouldSwallow(
            point: (x: point.x, y: point.y),
            panel: bounds.panel,
            app: bounds.app
        ) else {
            return Unmanaged.passUnretained(event)
        }
        withLock { swallowedMouseButton = event.getIntegerValueField(.mouseEventButtonNumber) }
        // The dismissal belongs to the engine on the main actor; the swallow above already
        // happened, so the hop costs nothing but ordering.
        let handler = onOutsideMousePress
        DispatchQueue.main.async {
            handler?()
        }
        return nil
    }

    private func handleMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let button = withLock({ swallowedMouseButton }) else {
            return Unmanaged.passUnretained(event)
        }
        guard button == event.getIntegerValueField(.mouseEventButtonNumber) else {
            return Unmanaged.passUnretained(event)
        }
        withLock { swallowedMouseButton = nil }
        return nil
    }

    /// Remembers a consumed key-down so its release is consumed as well.
    private func recordSwallowedKeyDown(_ keyCode: UInt16) {
        withLock { swallowedKeyDownCode = keyCode }
    }

    /// Whether this key-up is the release of a key-down the tap ate, clearing the memory.
    ///
    /// Key code only: the modifiers can differ between the two events, and a physical key
    /// cannot be pressed twice without being released in between, so the code is enough.
    private func takeSwallowedKeyDown(_ keyCode: UInt16) -> Bool {
        withLock {
            guard swallowedKeyDownCode == keyCode else { return false }
            swallowedKeyDownCode = nil
            return true
        }
    }

    /// The plain half of the decision — hotkeys, navigation keys, Escape. The answer lives
    /// in `KeySwallowRules`, which is a value type and therefore testable; this method only
    /// supplies the current rules under the lock.
    private func shouldSwallow(
        keyCode: UInt16,
        modifiers: ModifierSet,
        characters: String?
    ) -> Bool {
        withLock {
            swallowRules.shouldSwallow(
                keyCode: keyCode,
                modifiers: modifiers,
                characters: characters
            )
        }
    }

    /// The composed-stroke half of the decision, answered on the tap thread from the
    /// snapshot the engine publishes. Never calls the engine: a synchronous main-actor call
    /// here is what let a wedged main thread freeze the whole keyboard.
    private func shouldSwallowComposed(_ event: KeyEvent) -> Bool {
        ComposedSwallow.decide(withLock { composedSwallowState }, event: event)
    }

    /// Hands one event to the engine, through the bounded mailbox.
    ///
    /// Never synchronous: the tap thread must not wait for the main thread. Never one hop per
    /// event either — the whole queued batch goes over on a single hop, which is what keeps a
    /// wedged main thread from turning into a replay.
    private func emit(_ event: KeyEvent) {
        let needsDrain = withLock { () -> Bool in
            let wantsDrain = mailbox.post(event)
            guard wantsDrain, !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        guard needsDrain else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainMailbox()
        }
    }

    /// Runs on the main thread: delivers everything queued, in order, then releases the debt a
    /// drop left behind (a single `.interruption`, appended last by the mailbox).
    private func drainMailbox() {
        let (batch, dropped) = withLock { () -> ([KeyEvent], Int) in
            let result = mailbox.drain()
            drainScheduled = false
            return result
        }
        if dropped > 0 {
            Diag.warning(
                .tap,
                "input backlog overflowed: dropped \(dropped) event(s), told the engine to resync"
            )
        }
        guard let handler = onEvent else { return }
        for event in batch {
            handler(event)
        }
    }

    // MARK: - Decoding

    static func unicodeString(from event: CGEvent) -> String? {
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: units, count: length)
    }
}
