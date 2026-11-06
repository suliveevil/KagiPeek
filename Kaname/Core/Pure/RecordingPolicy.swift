import Foundation

/// What the active shortcut should do when it fires. Shared by the engine (which executes
/// the side effect) and `EngineState` (which remembers the recording target).
nonisolated enum HotkeyTarget: Hashable, Sendable {
    case panel
    case search
    case switcher
    case runRow
    case copyRow
}

/// What a recording event means, as data.
///
/// Every event that arrives while a binding is being recorded is swallowed: the recorder
/// owns the keyboard until it has an answer or the user cancels. The difference the policy
/// makes is whether the swallow also ends the recording and, when it does, which spec it
/// writes.
nonisolated enum RecordingDecision: Equatable, Sendable {
    /// Swallow the event and keep recording.
    case consume
    /// Swallow the event and stop recording without writing anything.
    case cancel
    /// Swallow the event, write this binding, and stop recording.
    case assign(HotkeySpec)
}

/// The recording rules, as one pure decision.
///
/// They used to be a five-by-five double switch inside `ShortcutEngine.handleRecording`,
/// reachable only by clicking through the settings window: a global hotkey needs ⌘/⌥/⌃,
/// a row key may be a bare Return or Space but never another bare character, and Esc cancels.
/// Moving the rules here makes the whole table testable without an event tap.
nonisolated enum RecordingPolicy {
    /// A row key is read while the panel owns the keyboard, so Esc and the arrows are the
    /// panel's own navigation and stay reserved.
    static let reservedRowKeyCodes: Set<UInt16> = Set([KeyCode.escape] + KeyCode.arrows)

    static func decision(for event: KeyEvent, target: HotkeyTarget) -> RecordingDecision {
        switch event.kind {
        case .flagsChanged, .keyUp:
            // Modifier edges and releases belong to the recorder's bookkeeping, not to the
            // binding being written.
            return .consume
        case .interruption:
            return .cancel
        case .keyDown:
            // A held key would otherwise be recorded as the binding and then fire.
            if event.isRepeat { return .consume }
            if event.keyCode == KeyCode.escape, event.modifiers.isEmpty {
                return .cancel
            }
            guard accepted(event, target: target) else { return .consume }
            return .assign(HotkeySpec(keyCode: event.keyCode, modifiers: event.modifiers))
        }
    }

    /// Whether a key-down is a legal binding for this target.
    private static func accepted(_ event: KeyEvent, target: HotkeyTarget) -> Bool {
        switch target {
        case .runRow, .copyRow:
            guard !reservedRowKeyCodes.contains(event.keyCode) else { return false }
            let isCharacter = (event.key?.raw.count ?? 0) == 1
            let isBareSpace = event.keyCode == KeyCode.space || event.key?.raw == " "
            // A bare character would break chord entry and filtering; a bare Return, Space or
            // function key is fine because the panel is the only thing listening.
            return !event.modifiers.isEmpty || isBareSpace || !isCharacter
        case .panel, .search, .switcher:
            // A global hotkey needs a modifier, otherwise typing would trigger it.
            return event.modifiers.contains(.command)
                || event.modifiers.contains(.option)
                || event.modifiers.contains(.control)
        }
    }
}
