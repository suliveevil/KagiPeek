import Foundation

/// Which of the configured global hotkeys a key-down matched.
///
/// The order is load-bearing: `panelHotkey` is the first question asked, then the search
/// palette's, then the panel/switcher one — the engine used to ask them in exactly this
/// order inline, and two hotkeys sharing a chord answer to the first.
enum HotkeyChoice: Equatable {
    case panel
    case search
    case switcher
}

/// What the engine must *do* with a key-down, as data.
///
/// `ShortcutEngine.handleKeyDown` used to walk every branch of the key pipeline inline —
/// hotkeys first, then the panel's own keys (Escape, `/`, navigation, paging, the row keys,
/// ⌫), then chord composition — so the whole routing was only reachable through AppKit and
/// untestable. The walk is pure: it reads the event, the phase, the settings, the panel and
/// the catalog and returns one decision. The engine executes the side effects; the router
/// makes the choice.
enum KeyDownAction: Equatable {
    /// A configured global hotkey matched; toggle the named surface.
    case hotkey(HotkeyChoice)
    /// Nothing to do: the panel is idle, the press is a repeat of a row key, or the event
    /// carried no key token.
    case none
    /// A key arrived while the panel was armed: cancel the arm and drop the prefix.
    case cancelArm
    /// Escape while the panel is active: dismiss it.
    case dismiss
    /// `/` alone while the panel is active: swap the list for the search palette.
    case showSearch
    /// A navigation key moved the selection by the delta (1 or -1).
    case moveSelection(Int)
    /// A page key moved the page by the delta.
    case page(Int)
    /// The run/copy key on a non-repeating press: act on the selected row.
    case performRow(RowAction)
    /// ⌫ while ticks are composed: undo the last tick.
    case undoLatched
    /// ⌫ with no ticks but a prefix: climb one level.
    case goUpLevel
    /// The press *is* the shortcut: the front app performs it.
    case passThrough(item: BindingItem, probe: KeyChord)
    /// The stroke was assembled from a latched tick: replay the composed chord.
    case replayComposed(item: BindingItem, probe: KeyChord)
    /// The stroke opened a deeper prefix level.
    case descend(probe: KeyChord)
    /// The stroke matched nothing: keep the ticks, narrow by the physical modifiers.
    case noMatch(heldModifiers: ModifierSet)
}

/// Decides what a key-down means, with no side effects.
///
/// Mirrors the order the engine walked inline, so routing and execution cannot drift:
/// hotkeys are asked first (they answer in any phase), then the phase decides whether the
/// panel is listening, and inside `.active` the panel's own keys are consumed before a
/// stroke is composed.
enum KeyEventRouter {
    /// - Parameters:
    ///   - panel: the current panel snapshot; its *held* modifiers and latched order are
    ///     read, which is the narrowing set the event is measured against.
    ///   - pending: what the panel is contributing to a stroke (held + latched), read only
    ///     by chord composition.
    ///   - items: the catalog the stroke is resolved against.
    static func route(
        keyCode: UInt16,
        key: KeyToken?,
        modifiers: ModifierSet,
        isRepeat: Bool,
        phase: EnginePhase,
        settings: AppSettingsSnapshot,
        panel: PanelState,
        prefix: KeyChord,
        pending: PendingModifiers,
        items: [BindingItem]
    ) -> KeyDownAction {
        if let choice = hotkey(
            keyCode: keyCode,
            key: key,
            modifiers: modifiers,
            settings: settings
        ) {
            return .hotkey(choice)
        }

        switch phase {
        case .idle:
            return .none
        case .armed:
            // A key pressed while a trigger was arming cancels the arm: the user is typing,
            // not about to open the panel.
            return .cancelArm
        case .active:
            // Escape is matched on the key code and before the token guard: it must work
            // even when the tap decoded no character for it, which is exactly what a
            // virtual keyboard does when Caps Lock is remapped to Esc.
            if keyCode == KeyCode.escape {
                return .dismiss
            }
            guard let key else { return .none }

            // `/` is the panel's one text entry: it swaps the list for the search palette,
            // which is where typing belongs.
            if keyCode == KeyCode.slash, modifiers.isEmpty {
                return .showSearch
            }

            // While the list is narrowed the user is holding modifiers, so every event
            // carries them. They are not part of the key the user meant — they are the
            // filter — so they are stripped before the key is identified. Without this,
            // ↓ does not move the selection and ⌃N is not a navigation key while ⌘ is down.
            let pressed = modifiers.subtracting(panel.heldModifiers)

            if let direction = NavigationKey.direction(keyCode: keyCode, modifiers: pressed) {
                switch direction {
                case .up: return .moveSelection(-1)
                case .down: return .moveSelection(1)
                case .left: return .page(-1)
                case .right: return .page(1)
                }
            }

            if let step = NavigationKey.pageStep(keyCode: keyCode, modifiers: pressed) {
                return .page(step)
            }

            // A held key repeats: moving through the list with ↓ is useful, running the
            // same shortcut ten times in a row is not.
            if let action = RowKeyRouter.action(
                for: keyCode,
                modifiers: modifiers,
                held: panel.heldModifiers,
                run: settings.runRowKey,
                copy: settings.copyRowKey
            ) {
                return isRepeat ? .none : .performRow(action)
            }

            if modifiers.isEmpty, key == .backspace {
                // ⌫ undoes a tick before it pops a level: the tick is the newer, more
                // visible thing the user did, so it is the first thing to be undone.
                if !panel.latchedOrder.isEmpty { return .undoLatched }
                if !prefix.isEmpty { return .goUpLevel }
                return .none
            }

            if isRepeat { return .none }

            let resolution = ChordComposition.resolve(
                prefix: prefix,
                physical: modifiers,
                pending: pending,
                key: key,
                in: items
            )
            switch resolution.outcome {
            case .complete(let item):
                // A composed stroke means the tap swallowed the physical key, so the panel
                // owes the app the assembled chord; an uncomposed one already *is* the
                // shortcut and the front app performs it.
                if resolution.composed {
                    return .replayComposed(item: item, probe: resolution.probe)
                }
                return .passThrough(item: item, probe: resolution.probe)
            case .descend:
                return .descend(probe: resolution.probe)
            case .noMatch:
                return .noMatch(heldModifiers: modifiers)
            }
        }
    }

    /// The first configured hotkey the event matches, in the order the engine applies them.
    static func hotkey(
        keyCode: UInt16,
        key: KeyToken?,
        modifiers: ModifierSet,
        settings: AppSettingsSnapshot
    ) -> HotkeyChoice? {
        if HotkeyMatcher.matches(
            keyCode: keyCode,
            modifiers: modifiers,
            key: key,
            spec: settings.panelHotkey
        ) {
            return .panel
        }
        if HotkeyMatcher.matches(
            keyCode: keyCode,
            modifiers: modifiers,
            key: key,
            spec: settings.searchHotkey
        ) {
            return .search
        }
        if HotkeyMatcher.matches(
            keyCode: keyCode,
            modifiers: modifiers,
            key: key,
            spec: settings.switchHotkey
        ) {
            return .switcher
        }
        return nil
    }
}
