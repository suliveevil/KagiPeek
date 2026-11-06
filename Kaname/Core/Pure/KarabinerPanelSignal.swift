import Foundation

/// The one-bit message Kaname sends to Karabiner-Elements while the panel is up.
///
/// Karabiner sits below the session event tap: it grabs the physical keyboard, rewrites the
/// event at its own virtual keyboard, and everything above it — Kaname included — can only
/// see the rewritten result. A rule that fires on the trigger key (`left_command` with
/// `to_if_alone` is the common one) therefore keeps running while the panel is open, and the
/// panel receives the rule's output — a lone tap arrives as the rule's shortcut instead of a
/// modifier press, so ⌘ stops narrowing the list.
///
/// Nothing at this layer can tell Karabiner to stop. What it *can* do is say when the panel
/// is up, through the one channel Karabiner reads from the outside: a variable. A rule carrying
/// `conditions: [{"type": "variable_unless", "name": "kaname_panel", "value": 1}]` applies only
/// while the panel is closed — `variable_if` would be the inverse, and would keep the rule
/// *on* exactly while the panel is up — so the key reaches the panel as the user meant it.
///
/// This type owns only the decision and the wording; writing the variable is
/// `KarabinerBridge`'s job.
nonisolated enum KarabinerPanelSignal {
    /// The variable a rule tests. Deliberately one plain word: Karabiner matches variable
    /// names literally, and a dotted or prefixed name is one more thing a hand-written rule
    /// can get wrong.
    static let variableName = "kaname_panel"

    /// The `--set-variables` payload: one variable, one number.
    static func payload(panelIsVisible: Bool) -> String {
        let value = panelIsVisible ? 1 : 0
        return "{\"\(variableName)\":\(value)}"
    }

    /// Whether the variable should read 1 right now.
    ///
    /// Off means 0 even while the panel is visible: a switch that is off must not leave a
    /// stale 1 behind, or the user's rule would stay suppressed for as long as the app runs
    /// and the setting would look like it did nothing.
    static func desiredState(panelIsVisible: Bool, isEnabled: Bool) -> Bool {
        panelIsVisible && isEnabled
    }
}
