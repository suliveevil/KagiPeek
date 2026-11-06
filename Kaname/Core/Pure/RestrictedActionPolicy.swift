import Foundation

/// The system actions Kaname shows but never runs.
///
/// Seven chords across six user-facing actions: log out and force log out are separate.
/// They affect the whole machine, not the front app: a menu press would put the Mac to
/// sleep, restart it, or end the session. The panel therefore keeps them discoverable and
/// copyable and refuses the run path entirely, with no second confirmation: the safest
/// answer is that the action is not offered.
nonisolated enum RestrictedAction: String, CaseIterable, Sendable {
    case sleep
    case restart
    case shutdown
    case lockScreen
    case logOut
    case forceLogOut
    case forceQuit
}

/// Whether a binding may be run.
nonisolated enum Restriction: Equatable, Sendable {
    case allowed
    case restricted(RestrictedAction)

    var isRestricted: Bool {
        if case .restricted = self { return true }
        return false
    }

    var action: RestrictedAction? {
        if case let .restricted(action) = self { return action }
        return nil
    }
}

/// The chord whitelist that decides which bindings are restricted.
///
/// Matching is by chord and not by title, because titles are localized and because the same
/// action appears twice with different names: the Apple menu's "Sleep" and the system
/// hotkey list both carry ⌥⌘Power, and neither row should be allowed to run it.
///
/// The whitelist is chords rather than Carbon symbolic-hotkey IDs because
/// `SystemHotkeyReader` deliberately drops the ID: it turns each registered hotkey into a
/// plain `BindingItem`, and one chord therefore identifies the action in both the system
/// section and the menu section. A title or an ID would have to be maintained twice and
/// would disagree across languages and macOS versions.
nonisolated enum RestrictedActionPolicy {
    private struct Rule: Sendable {
        let action: RestrictedAction
        let modifiers: ModifierSet
        let key: KeyToken
        /// Other spellings of the same physical key (layout robustness).
        let alternates: [KeyToken]

        func matches(_ step: KeyStep) -> Bool {
            guard step.modifiers == modifiers, let pressed = step.key else { return false }
            if pressed == key || alternates.contains(pressed) { return true }
            // The chord parser may have attached the alternate spelling to the item instead
            // of to the rule; accept that direction as well.
            return step.alternates.contains(key)
        }
    }

    /// ANSI Power key. `Kaname/Core/Pure/KeyMapper.swift` maps virtual key 0x7F to the
    /// `"power"` token for exactly this whitelist.
    private static let power = KeyToken("power")

    private static let rules: [Rule] = [
        Rule(action: .sleep, modifiers: [.option, .command], key: power, alternates: []),
        Rule(action: .restart, modifiers: [.control, .command], key: power, alternates: []),
        Rule(action: .shutdown, modifiers: [.control, .option, .command], key: power, alternates: []),
        Rule(action: .lockScreen, modifiers: [.control, .command], key: KeyToken("q"), alternates: []),
        Rule(action: .logOut, modifiers: [.shift, .command], key: KeyToken("q"), alternates: []),
        Rule(action: .forceLogOut, modifiers: [.option, .shift, .command], key: KeyToken("q"), alternates: []),
        Rule(action: .forceQuit, modifiers: [.option, .command], key: KeyToken("esc"), alternates: [])
    ]

    /// - Note: ⌘Q is deliberately absent. Quitting the front app is an ordinary menu
    ///   command the panel exists to run; only the session-level actions are restricted.
    static func restriction(for item: BindingItem) -> Restriction {
        // A config-tool row has its own "shown only, never run" rule; classifying it as a
        // restricted system action would blur the two reasons in the UI and in the HUD.
        if item.source == .configFile { return .allowed }
        return restriction(for: item.chord)
    }

    static func restriction(for chord: KeyChord) -> Restriction {
        // Every restricted action is a single stroke. A multi-step chord that merely starts
        // with one of these prefixes is a different shortcut and stays runnable.
        guard chord.steps.count == 1, let step = chord.steps.first else { return .allowed }
        for rule in rules where rule.matches(step) {
            return .restricted(rule.action)
        }
        return .allowed
    }
}

// MARK: - Row action planning

/// What a row activation was asked to do.
nonisolated enum PanelRowRequest: Equatable, Sendable {
    /// A pointer click on the row.
    case click
    /// The run key (Space) or an Accessibility activation.
    case execute
    case copyShortcut
    case copyMenuItem
}

/// What the panel should actually do, after source and restriction have been considered.
nonisolated enum PanelRowOutcome: Equatable, Sendable {
    case run
    case copyShortcut
    case copyMenuItem
    case noticeUnsupportedSource
    case noticeRestricted
    case noticeNothingToCopy
}

/// One decision table for every surface that can activate a row.
///
/// The panel, the palette and the defensive guard inside `RowRunner` all ask this same
/// question, so a config row cannot be run from one surface and merely copied from another.
nonisolated enum PanelRowActionPlan {
    static func outcome(
        request: PanelRowRequest,
        restriction: Restriction,
        source: BindingSource,
        hasChord: Bool
    ) -> PanelRowOutcome {
        // A row read from a tool's config file has no execution path at all. A click still
        // copies the shortcut (the user's answer for "click should not run"); when there is
        // no chord it says so instead of silently doing nothing.
        if source == .configFile {
            switch request {
            case .click, .copyShortcut:
                return hasChord ? .copyShortcut : .noticeNothingToCopy
            case .execute:
                return .noticeUnsupportedSource
            case .copyMenuItem:
                return .copyMenuItem
            }
        }
        // A restricted action never runs, and every way of asking says the same thing: the
        // click used to copy silently while the run key explained, so the same row read as
        // "nothing happened" on one surface and "not available" on another. The copy itself
        // happens in `RowRunner.refuseRestricted`, which picks the chord or the menu path.
        if restriction.isRestricted {
            switch request {
            case .click, .execute:
                return .noticeRestricted
            case .copyShortcut:
                return hasChord ? .copyShortcut : .noticeNothingToCopy
            case .copyMenuItem:
                return .copyMenuItem
            }
        }
        switch request {
        case .click, .execute:
            return .run
        case .copyShortcut:
            // Copying a shortcut-less command still has an answer: its menu path.
            return hasChord ? .copyShortcut : .copyMenuItem
        case .copyMenuItem:
            return .copyMenuItem
        }
    }
}
