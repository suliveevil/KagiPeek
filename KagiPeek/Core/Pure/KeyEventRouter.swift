import Foundation

/// Which of the configured global hotkeys a key-down matched.
///
/// The order is load-bearing: `panelHotkey` is the first question asked, then the search
/// palette's, then the panel/switcher one — the engine used to ask them in exactly this
/// order inline, and two hotkeys sharing a chord answer to the first.
nonisolated enum HotkeyChoice: Equatable {
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
nonisolated enum KeyDownAction: Equatable {
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

/// Everything a key-down is decided against, apart from the event itself.
///
/// The engine reads all six of these off its own state; the router takes them as one value
/// because four functions in this file want the same six, which is the test a parameter
/// object has to pass to be worth its own type. It lives here rather than next to the
/// engine's state so the router keeps depending inward: it must not learn the type the
/// engine stores its state in.
nonisolated struct RoutingContext {
    let phase: EnginePhase
    let settings: AppSettingsSnapshot
    /// The current panel snapshot; its *held* modifiers and latched order are read, which
    /// is the narrowing set the event is measured against.
    let panel: PanelState
    let prefix: KeyChord
    /// What the panel is contributing to a stroke (held + latched), read only by chord
    /// composition.
    let pending: PendingModifiers
    /// The catalog the stroke is resolved against.
    let items: [BindingItem]
}

/// Decides what a key-down means, with no side effects.
///
/// Mirrors the order the engine walked inline, so routing and execution cannot drift:
/// hotkeys are asked first (they answer in any phase), then the phase decides whether the
/// panel is listening, and inside `.active` the panel's own keys are consumed before a
/// stroke is composed.
///
/// Only the identity fields of `event` are read — `kind`, `happenedAt` and `characters`
/// play no part in the decision.
nonisolated enum KeyEventRouter {
    static func route(_ event: KeyEvent, in context: RoutingContext) -> KeyDownAction {
        if let choice = hotkey(event, settings: context.settings) {
            return .hotkey(choice)
        }

        switch context.phase {
        case .idle:
            return .none
        case .armed:
            // A key pressed while a trigger was arming cancels the arm: the user is typing,
            // not about to open the panel.
            return .cancelArm
        case .active:
            return routeActiveKey(event, in: context)
        }
    }

    /// What the panel made of a key it was asked about.
    ///
    /// Deliberately not `KeyDownAction?`: `KeyDownAction` has a `none` case of its own, so
    /// inside an Optional-returning function a bare `.none` compiles as `Optional.none` —
    /// "the panel makes no claim" — when the author meant "the panel consumed this key and
    /// the answer is: do nothing". It compiles, it runs, and it has no warning unless the
    /// value sits in a ternary. That is exactly how the first cut of this split turned a
    /// terminal ⌫ into a fall-through, so the two meanings get two cases they cannot be
    /// mistaken for each other in.
    private enum OwnedKey {
        /// The panel consumed the key; this is what it means.
        case action(KeyDownAction)
        /// The panel makes no claim on this key: it belongs to a stroke.
        case notOurs
    }

    /// The keys the panel claims for itself, then the stroke whatever is left composes.
    ///
    /// Every question below is terminal: the first one that answers wins and the rest are
    /// never asked. That is what keeps this in the order the engine walked it in.
    private static func routeActiveKey(
        _ event: KeyEvent,
        in context: RoutingContext
    ) -> KeyDownAction {
        // Escape is matched on the key code and before the token guard: it must work even
        // when the tap decoded no character for it, which is exactly what a virtual
        // keyboard does when Caps Lock is remapped to Esc.
        if event.keyCode == KeyCode.escape {
            return .dismiss
        }
        guard let key = event.key else { return .none }

        switch ownedKey(event, key: key, in: context) {
        case .action(let action):
            return action
        case .notOurs:
            break
        }

        // A repeat that got this far is a shortcut key being held down. Composing it again
        // would replay the same stroke on every tick of the key repeat.
        if event.isRepeat { return .none }

        return composedStroke(event, key: key, in: context)
    }

    /// The panel's own keys: `/`, navigation, paging, the row keys and ⌫.
    ///
    /// `.notOurs` is the common answer — most keys are strokes, not panel keys.
    private static func ownedKey(
        _ event: KeyEvent,
        key: KeyToken,
        in context: RoutingContext
    ) -> OwnedKey {
        // `/` is the panel's one text entry: it swaps the list for the search palette,
        // which is where typing belongs.
        if NavigationKey.isSlash(
            keyCode: event.keyCode,
            modifiers: event.modifiers,
            characters: event.characters
        ) {
            return .action(.showSearch)
        }

        // Tab is the other door between the same two surfaces, so switching costs one key
        // whether the user remembers `/` or only the tab they press everywhere else. Each
        // opening is a fresh search — nothing typed last time is carried over.
        if event.keyCode == KeyCode.tab, event.modifiers.isEmpty {
            return .action(.showSearch)
        }

        // While the list is narrowed the user is holding modifiers, so every event carries
        // them. They are not part of the key the user meant — they are the filter — so they
        // are stripped before the key is identified. Without this, ↓ does not move the
        // selection and ⌃N is not a navigation key while ⌘ is down.
        let pressed = event.modifiers.subtracting(context.panel.heldModifiers)

        if let direction = NavigationKey.direction(keyCode: event.keyCode, modifiers: pressed) {
            switch direction {
            case .up: return .action(.moveSelection(-1))
            case .down: return .action(.moveSelection(1))
            case .left: return .action(.page(-1))
            case .right: return .action(.page(1))
            }
        }

        if let step = PagingKeyPlan.step(
            pairs: context.settings.pagingPairs,
            keyCode: event.keyCode,
            modifiers: pressed,
            characters: event.characters
        ) {
            return .action(.page(step))
        }

        // A held key repeats: moving through the list with ↓ is useful, running the same
        // shortcut ten times in a row is not.
        if let action = RowKeyRouter.action(
            for: event.keyCode,
            modifiers: event.modifiers,
            held: context.panel.heldModifiers,
            run: context.settings.runRowKey,
            copy: context.settings.copyRowKey
        ) {
            return .action(event.isRepeat ? .none : .performRow(action))
        }

        if event.modifiers.isEmpty, key == .backspace {
            // ⌫ undoes a tick before it pops a level: the tick is the newer, more visible
            // thing the user did, so it is the first thing to be undone. With nothing left
            // to undo the key is spent, and it has to be spent *here* rather than fall
            // through: there is no stroke for chord composition to build.
            if !context.panel.latchedOrder.isEmpty { return .action(.undoLatched) }
            if !context.prefix.isEmpty { return .action(.goUpLevel) }
            return .action(.none)
        }

        return .notOurs
    }

    /// The last question: does this key complete, descend or miss a shortcut in the catalog?
    private static func composedStroke(
        _ event: KeyEvent,
        key: KeyToken,
        in context: RoutingContext
    ) -> KeyDownAction {
        let resolution = ChordComposition.resolve(
            prefix: context.prefix,
            physical: event.modifiers,
            pending: context.pending,
            key: key,
            in: context.items
        )
        switch resolution.outcome {
        case .complete(let item):
            // A composed stroke means the tap swallowed the physical key, so the panel owes
            // the app the assembled chord; an uncomposed one already *is* the shortcut and
            // the front app performs it.
            if resolution.composed {
                return .replayComposed(item: item, probe: resolution.probe)
            }
            return .passThrough(item: item, probe: resolution.probe)
        case .descend:
            return .descend(probe: resolution.probe)
        case .noMatch:
            return .noMatch(heldModifiers: event.modifiers)
        }
    }

    /// The first configured hotkey the event matches, in the order the engine applies them.
    /// The whole hotkey path is off when its switch is off: the keys then reach the front app
    /// untouched, which is what makes "both triggers off" behave like the old pause.
    static func hotkey(_ event: KeyEvent, settings: AppSettingsSnapshot) -> HotkeyChoice? {
        guard settings.hotkeyTriggerEnabled else { return nil }
        if HotkeyMatcher.matches(
            keyCode: event.keyCode,
            modifiers: event.modifiers,
            key: event.key,
            spec: settings.panelHotkey
        ) {
            return .panel
        }
        if HotkeyMatcher.matches(
            keyCode: event.keyCode,
            modifiers: event.modifiers,
            key: event.key,
            spec: settings.searchHotkey
        ) {
            return .search
        }
        if HotkeyMatcher.matches(
            keyCode: event.keyCode,
            modifiers: event.modifiers,
            key: event.key,
            spec: settings.switchHotkey
        ) {
            return .switcher
        }
        return nil
    }
}
