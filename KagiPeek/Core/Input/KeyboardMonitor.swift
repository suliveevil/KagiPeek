import AppKit
import CoreGraphics
import os

enum KeyEventKind {
    case flagsChanged
    case keyDown
    case keyUp
    case interruption
}

struct KeyEvent {
    let kind: KeyEventKind
    let modifiers: ModifierSet
    /// nil when the event carries no mappable key (pure modifier change, or an exotic key).
    let key: KeyToken?
    let keyCode: UInt16
    let isRepeat: Bool
    let happenedAt: Date
    /// Typed text when the event carries it (the panel reads it while it owns the keys).
    var characters: String? = nil
}

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
/// The run-loop source lives on the main run loop, so callbacks arrive on the main thread.
final class KeyboardMonitor {
    var onEvent: ((KeyEvent) -> Void)?
    /// Called on the main thread for every key-down; return true to consume the event.
    var shouldSwallow: ((KeyEvent) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isRunning = false
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

    /// Called on the main thread for a press the tap swallowed; close the surface here.
    var onOutsideMousePress: (() -> Void)?

    func start() throws {
        guard tap == nil else { return }
        guard PermissionCenter.hasAccessibility else { throw KeyboardMonitorError.accessibilityDenied }

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
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
            // The tap exists but nothing ever drains it: every shortcut in the session is
            // dead, and there is no error path to say so.
            Diag.error(.tap, "run-loop source creation failed: the tap will never deliver events")
        }
        CGEvent.tapEnable(tap: created, enable: true)
        isRunning = true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        isRunning = false
    }

    var isActive: Bool { isRunning }

    // MARK: - Callback

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
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
                || (shouldSwallow?(keyEvent) ?? false)
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
                || (shouldSwallow?(keyEvent) ?? false)
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
            AppLog.input.notice("event tap disabled by the system; re-enabling")
            Diag.warning(.tap, "event tap disabled by the system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); re-enabling")
            emit(KeyEvent(kind: .interruption, modifiers: [], key: nil, keyCode: 0, isRepeat: false, happenedAt: Date()))
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// A press inside the front app's window but outside the surface: close the surface and
    /// eat the click.
    private func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let bounds = swallowOutside
        lock.unlock()
        guard let bounds else { return Unmanaged.passUnretained(event) }
        let point = event.location
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
        onOutsideMousePress?()
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

    private func emit(_ event: KeyEvent) {
        onEvent?(event)
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
