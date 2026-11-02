import AppKit
import CoreGraphics
import os

/// A global hotkey that the tap should consume instead of forwarding to the front app.
struct SwallowRule: Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: ModifierSet
    /// Hyper-key tolerance: accept a superset of the recorded modifiers.
    var tolerant: Bool
}

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
/// callback on the main run loop, any main-thread wedge — KagiPeek's or the system's —
/// left the tap enabled in front of a callback that could not run, and every key and click
/// in the session waited out the tap's timeout. Three of the four episodes ended in a
/// power-button reset. On its own thread the callback keeps running no matter what the
/// main thread is doing, the swallow decision is answered from a published snapshot
/// (`ComposedSwallowState`) instead of a synchronous main-actor call, and events are
/// handed to the engine asynchronously — a wedged main thread can delay the panel by a
/// hop, but it can no longer delay the input stream at all.
final class KeyboardMonitor {
    /// Called on the **main** thread (via an async hop) for every event; the engine owns
    /// the panel behaviour that follows.
    var onEvent: ((KeyEvent) -> Void)?

    /// Why a tap that the system disabled is being taken down instead of put back.
    enum TeardownReason: String {
        /// The process no longer holds Accessibility, so the tap can never be re-armed.
        case permissionLost
        /// It was disabled repeatedly with nothing getting through in between.
        case unresponsive
    }

    /// Fired after `stop()` was called from inside the tap callback, so the owner can say so.
    var onTeardown: ((TeardownReason) -> Void)?

    /// Whether the process still holds Accessibility. Injected so the trust branch can be
    /// driven without touching TCC.
    var hasAccessibility: () -> Bool = { PermissionCenter.hasAccessibility }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isRunning = false
    /// The thread the tap drains on; owned by `start()`, never joined synchronously.
    private var tapThread: Thread?
    /// The run loop the tap source is scheduled on — the tap thread's own, never main's.
    private var tapRunLoop: CFRunLoop?
    private let lock = NSLock()
    private var swallowRules: [SwallowRule] = []
    private var capturedIdentifiers: Set<UInt32> = []
    private var capturedKeyCodes: Set<UInt16> = []
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

    static func identifier(keyCode: UInt16, modifiers: ModifierSet) -> UInt32 {
        UInt32(keyCode) << 8 | UInt32(truncatingIfNeeded: modifiers.rawValue & 0xFF)
    }

    /// Whether the engine currently needs characters. Decoding runs on the event-tap thread
    /// for every key press in the session, so it is only on while a surface is reading keys
    /// or a binding is being recorded.
    func updateDecodesKeyEvents(_ value: Bool) {
        lock.lock()
        decodesKeyEvents = value
        lock.unlock()
    }

    private var needsCharacters: Bool {
        lock.lock()
        defer { lock.unlock() }
        return decodesKeyEvents
    }

    func updateSwallowRules(_ rules: [SwallowRule]) {
        lock.lock()
        swallowRules = rules
        lock.unlock()
    }

    /// The engine's picture of the composed-stroke state, published after every change that
    /// affects the swallow decision. The tap thread reads it instead of calling the engine:
    /// the engine keeps the main actor, the input path keeps its own thread.
    func updateComposedSwallowState(_ state: ComposedSwallowState) {
        lock.lock()
        composedSwallowState = state
        lock.unlock()
    }

    private var composedSwallowState = ComposedSwallowState()

    /// Keys the panel is currently using for navigation (↑↓←→↵Esc). They are consumed
    /// while the panel is pinned so the front app does not also react to them.
    func updateCapturedKeys(_ identifiers: Set<UInt32>) {
        lock.lock()
        capturedIdentifiers = identifiers
        lock.unlock()
    }

    /// Keys consumed regardless of modifiers (used for Esc).
    func updateCapturedKeyCodes(_ keyCodes: Set<UInt16>) {
        lock.lock()
        capturedKeyCodes = keyCodes
        lock.unlock()
    }

    /// Arms the click that dismisses a surface: pressing inside `appWindowFrame` but outside
    /// `panelFrame` closes the surface and is swallowed, so the app behind it never sees it.
    ///
    /// Pass nil to disarm. Clicks anywhere else — the menu bar, the Dock, the desktop,
    /// another app's window — are always passed through: those are the user reaching for
    /// something else, and eating them would make the panel feel like it had frozen the
    /// screen.
    func updateOutsideMouseSwallow(panelFrame: CGRect?, appWindowFrame: CGRect?) {
        lock.lock()
        if let panelFrame, let appWindowFrame {
            swallowOutside = (Self.screenRect(panelFrame), Self.screenRect(appWindowFrame))
        } else {
            swallowOutside = nil
            swallowedMouseButton = nil
        }
        lock.unlock()
    }

    private static func screenRect(_ rect: CGRect) -> ScreenRect {
        ScreenRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    /// Called on the tap thread for a press the tap swallowed; the monitor hops it to the
    /// main thread before invoking, so the owner never sees a foreign queue.
    var onOutsideMousePress: (() -> Void)?

    func start() throws {
        guard tap == nil else { return }
        guard PermissionCenter.hasAccessibility else { throw KeyboardMonitorError.accessibilityDenied }

        pendingReEnable?.cancel()
        pendingReEnable = nil

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

        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        guard source != nil else {
            // The tap exists but nothing ever drains it: every shortcut in the session is
            // dead, and there is no error path to say so.
            Diag.error(.tap, "run-loop source creation failed: the tap will never deliver events")
            throw KeyboardMonitorError.tapCreationFailed
        }
        enableTap(created)
        isRunning = true

        lock.lock()
        watchdog.reset()
        tapDetachedByWatchdog = false
        lock.unlock()
        startWatchdog()

        // The tap's run loop is this thread's own — the point of the whole refactor. The
        // source is added here, on the thread that drains it, as CFRunLoopAddSource
        // requires; nothing about the tap depends on the main thread after this.
        let thread = Thread { [weak self] in self?.tapThreadMain() }
        thread.name = "KagiPeek event tap"
        tapThread = thread
        thread.start()
    }

    /// Body of the dedicated tap thread. Blocks until `stop()` calls `CFRunLoopStop`.
    private func tapThreadMain() {
        let runLoop = CFRunLoopGetCurrent()
        lock.lock()
        // A stop() that raced the launch leaves nothing to schedule: the loop below exits
        // immediately and the thread dies.
        guard isRunning, let source else {
            tapRunLoop = nil
            lock.unlock()
            return
        }
        health.reset()
        tapRunLoop = runLoop
        lock.unlock()

        CFRunLoopAddSource(runLoop, source, CFRunLoopMode.defaultMode)
        CFRunLoopRun()
        CFRunLoopRemoveSource(runLoop, source, CFRunLoopMode.defaultMode)

        lock.lock()
        tapRunLoop = nil
        lock.unlock()
    }

    func stop() {
        stopWatchdog()
        pendingReEnable?.cancel()
        pendingReEnable = nil
        lock.lock()
        let tapPort = tap
        let runLoop = tapRunLoop
        tap = nil
        source = nil
        isRunning = false
        health.reset()
        lastEnableAt = nil
        lock.unlock()
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
    private func handleDisable(reason: String) {
        lock.lock()
        let tapPort = tap
        let running = isRunning
        let waitingOutPause = pendingReEnable != nil
        lock.unlock()
        guard running, let tapPort else { return }
        // Already waiting out a pause: the tap is off and further notifications describe the
        // same failure, not a new one.
        guard !waitingOutPause else { return }

        let trusted = hasAccessibility()
        lock.lock()
        let recovery = health.recordDisable(trusted: trusted)
        let attempt = health.consecutiveDisables
        lock.unlock()

        lock.lock()
        let stoodFor = lastEnableAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        lock.unlock()
        let detail = "event tap disabled by the system (\(reason)); "
            + "attempt \(attempt), trusted=\(trusted), "
            + "enabled=\(CGEvent.tapIsEnabled(tap: tapPort)), "
            + "stood_ms=\(stoodFor.map(String.init) ?? "?")"
        AppLog.input.notice("event tap disabled by the system")
        Diag.warning(.tap, detail + " — " + Self.describe(recovery))

        // The panel releases whatever it was holding: keys pressed during the stall are gone.
        emit(KeyEvent(kind: .interruption, modifiers: [], key: nil, keyCode: 0, isRepeat: false, happenedAt: Date()))

        switch recovery {
        case let .reEnable(delay):
            // The watchdog detached the tap because the tap thread is wedged: putting it
            // back from here would re-create the freeze the watchdog just ended.
            lock.lock()
            let detached = tapDetachedByWatchdog
            lock.unlock()
            guard !detached else { return }

            guard delay > 0 else {
                enableTap(tapPort)
                return
            }
            // The pause is served on the tap's own run loop: a wedged main thread must not
            // be able to hold a dead tap installed — or to keep it removed, which is the
            // harmless direction, but the tap's recovery belongs to the tap's thread.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.pendingReEnable = nil
                let stillRunning = self.isRunning
                self.lock.unlock()
                guard stillRunning else { return }
                self.enableTap(tapPort)
            }
            lock.lock()
            pendingReEnable = work
            let runLoop = tapRunLoop
            lock.unlock()
            if let runLoop {
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak work] in
                    work?.perform()
                }
                CFRunLoopWakeUp(runLoop)
                // Safety net: if the run loop never drains the block, the work item is
                // cancelled with the tap and cannot leak.
                DispatchQueue.global().asyncAfter(deadline: .now() + delay + 5) { [weak work] in
                    work?.cancel()
                }
            }

        case .tearDown:
            let why: TeardownReason = trusted ? .unresponsive : .permissionLost
            stop()
            Diag.error(.tap, "event tap torn down (\(why.rawValue)): " + detail)
            let handler = onTeardown
            DispatchQueue.main.async {
                handler?(why)
            }
        }
    }

    /// Turns the tap on and remembers when, so the next disable can say how long it stood.
    private func enableTap(_ tapPort: CFMachPort) {
        lock.lock()
        lastEnableAt = Date()
        lock.unlock()
        CGEvent.tapEnable(tap: tapPort, enable: true)
    }

    private static func describe(_ recovery: TapRecovery) -> String {
        switch recovery {
        case let .reEnable(delay): return "re-enabling in \(delay)s"
        case .tearDown: return "giving up"
        }
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
        lock.lock()
        pingAcknowledged = false
        tapDetachedByWatchdog = false
        lock.unlock()
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
        lock.lock()
        let acknowledged = pingAcknowledged
        pingAcknowledged = false
        let tapPort = tap
        let running = isRunning
        let watchedLoop = tapRunLoop
        lock.unlock()

        guard running, let tapPort, let watchedLoop else { return }

        // A no-op on the tap's run loop: if it has not run by the next tick, the thread
        // draining the callback has been unresponsive for an interval.
        CFRunLoopPerformBlock(watchedLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pingAcknowledged = true
            self.lock.unlock()
        }
        CFRunLoopWakeUp(watchedLoop)

        // The state lives under the shared lock: start()/stop() reset it from the main
        // thread while this queue may be mid-tick.
        lock.lock()
        var watchdog = self.watchdog
        lock.unlock()

        let action = watchdog.tick(mainAcknowledged: acknowledged)

        lock.lock()
        self.watchdog = watchdog
        lock.unlock()

        switch action {
        case .none:
            break

        case .detachTap:
            lock.lock()
            tapDetachedByWatchdog = true
            lock.unlock()
            // From outside the wedged thread: a disabled tap is harmless, so this is what
            // frees the input stream.
            CGEvent.tapEnable(tap: tapPort, enable: false)
            Diag.error(.tap, "input watchdog: tap thread unresponsive for \(watchdog.unresponsiveTicks) ticks with the tap enabled — detaching the tap to free the input stream")

        case .reattachTap:
            lock.lock()
            tapDetachedByWatchdog = false
            lock.unlock()
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
            lock.lock()
            health.recordEvent()
            lock.unlock()
        }
        switch type {
        case .flagsChanged:
            emit(KeyEvent(
                kind: .flagsChanged,
                modifiers: ModifierSet.from(cgEventFlags: event.flags),
                key: nil,
                keyCode: 0,
                isRepeat: false,
                happenedAt: Date()
            ))
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = ModifierSet.from(cgEventFlags: event.flags)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let unicode = needsCharacters ? Self.unicodeString(from: event) : nil
            let keyEvent = KeyEvent(
                kind: .keyDown,
                modifiers: modifiers,
                key: unicode.flatMap { KeyMapper.token(keyCode: keyCode, unicode: $0, modifiers: modifiers) },
                keyCode: keyCode,
                isRepeat: isRepeat,
                happenedAt: Date(),
                characters: unicode
            )
            // A repeat of a captured key has to be consumed too: letting it through would
            // move the panel selection and scroll the front app at the same time.
            let consume = shouldSwallow(keyCode: keyCode, modifiers: modifiers)
                || shouldSwallowComposed(keyEvent)
            if consume { recordSwallowedKeyDown(keyCode) }
            emit(keyEvent)
            return consume ? nil : Unmanaged.passUnretained(event)

        case .keyUp:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = ModifierSet.from(cgEventFlags: event.flags)
            let unicode = needsCharacters ? Self.unicodeString(from: event) : nil
            let keyEvent = KeyEvent(
                kind: .keyUp,
                modifiers: modifiers,
                key: unicode.flatMap { KeyMapper.token(keyCode: keyCode, unicode: $0, modifiers: modifiers) },
                keyCode: keyCode,
                isRepeat: false,
                happenedAt: Date()
            )
            // Consumed on release as well: swallowing the press but not the release would
            // leave the front app holding a key that never came up. The press is remembered
            // by key code because the modifiers may have changed under it.
            let releaseOfSwallowedPress = takeSwallowedKeyDown(keyCode)
            if shouldSwallow(keyCode: keyCode, modifiers: modifiers)
                || shouldSwallowComposed(keyEvent)
                || releaseOfSwallowedPress {
                emit(keyEvent)
                return nil
            }
            emit(keyEvent)
            return Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return handleMouseDown(event)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return handleMouseUp(event)

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            handleDisable(reason: type == .tapDisabledByTimeout ? "timeout" : "user input")
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// A press inside the front app's window but outside the surface: close the surface and
    /// eat the click.
    private func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let point = event.location
        let bounds = swallowOutside
        lock.unlock()
        guard let bounds else { return Unmanaged.passUnretained(event) }
        guard OutsideClickPolicy.shouldSwallow(
            point: (x: point.x, y: point.y),
            panel: bounds.panel,
            app: bounds.app
        ) else {
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        swallowedMouseButton = event.getIntegerValueField(.mouseEventButtonNumber)
        lock.unlock()
        // The dismissal belongs to the engine on the main actor; the swallow above already
        // happened, so the hop costs nothing but ordering.
        let handler = onOutsideMousePress
        DispatchQueue.main.async {
            handler?()
        }
        return nil
    }

    private func handleMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let button = swallowedMouseButton
        lock.unlock()
        guard let button else { return Unmanaged.passUnretained(event) }
        guard button == event.getIntegerValueField(.mouseEventButtonNumber) else {
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        swallowedMouseButton = nil
        lock.unlock()
        return nil
    }

    /// Remembers a consumed key-down so its release is consumed as well.
    private func recordSwallowedKeyDown(_ keyCode: UInt16) {
        lock.lock()
        swallowedKeyDownCode = keyCode
        lock.unlock()
    }

    /// Whether this key-up is the release of a key-down the tap ate, clearing the memory.
    ///
    /// Key code only: the modifiers can differ between the two events, and a physical key
    /// cannot be pressed twice without being released in between, so the code is enough.
    private func takeSwallowedKeyDown(_ keyCode: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard swallowedKeyDownCode == keyCode else { return false }
        swallowedKeyDownCode = nil
        return true
    }

    private func shouldSwallow(keyCode: UInt16, modifiers: ModifierSet) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // `capturedKeyCodes` is a separate channel (Esc regardless of modifiers); leaving it
        // out of this guard would silently disable it whenever the other two sets are empty.
        guard !swallowRules.isEmpty || !capturedIdentifiers.isEmpty || !capturedKeyCodes.isEmpty else {
            return false
        }
        if capturedKeyCodes.contains(keyCode) { return true }
        let identifier = Self.identifier(keyCode: keyCode, modifiers: modifiers)
        if capturedIdentifiers.contains(identifier) { return true }
        for rule in swallowRules {
            guard rule.keyCode == keyCode else { continue }
            if rule.modifiers == modifiers { return true }
            if rule.tolerant, modifiers.isSuperset(of: rule.modifiers) { return true }
        }
        return false
    }

    /// The composed-stroke half of the decision, answered on the tap thread from the
    /// snapshot the engine publishes. Never calls the engine: a synchronous main-actor call
    /// here is what let a wedged main thread freeze the whole keyboard.
    private func shouldSwallowComposed(_ event: KeyEvent) -> Bool {
        lock.lock()
        let state = composedSwallowState
        lock.unlock()
        return ComposedSwallow.decide(state, event: event)
    }

    private func emit(_ event: KeyEvent) {
        // An async hop onto the main queue, never a synchronous call: the tap thread must
        // not wait for the main thread, and the serial queue preserves event order.
        let handler = onEvent
        DispatchQueue.main.async {
            handler?(event)
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
