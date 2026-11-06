import Foundation

/// Answers one question about every shortcut the panel can list: if the user pressed this
/// chord right now, would Kaname's key pipeline let it reach the front app?
///
/// This is not a check of the shortcut's definition. A chord can be perfectly valid —
/// ⌥⌘M is a real system hotkey, ⌥⌘F is a real Safari menu item — and still be unreachable
/// because the filter queue claimed its last key as a search token, or because the router
/// was given a narrower catalog than the list on screen. Both happened, and both left a row
/// the user could see but could not trigger. The audit replays that last press through the
/// same pure decisions the engine uses, so a disagreement between "what is shown" and
/// "what can run" becomes visible instead of arriving one bug report at a time.
///
/// It never sends a key, never presses a menu item and never touches the event tap: the
/// simulated `KeyEvent` is only ever handed to pure functions.
nonisolated enum PanelTriggerAudit {
    enum Reason: String, CaseIterable, Sendable {
        /// The filter queue turned the key into a search token instead of a stroke.
        case claimedByFilter
        /// The panel used the key for one of its own actions (search, paging, Escape, …).
        case capturedByPanelKey
        /// The chord was offered to composition and matched nothing.
        case unresolvedByRouter
        /// The key has no virtual key code, so a press cannot be simulated or replayed.
        case unmappableKey
    }

    struct Finding: Equatable, Sendable {
        let rowID: String
        let reason: Reason
    }

    struct Result: Equatable, Sendable {
        var findings: [Finding] = []

        var unreachableRowIDs: Set<String> { Set(findings.map(\.rowID)) }

        func reason(forRowID id: String) -> Reason? {
            findings.first { $0.rowID == id }?.reason
        }
    }

    /// The session state the simulated press is judged against.
    struct Context {
        var phase: EnginePhase
        var settings: AppSettingsSnapshot
        var panel: PanelState
        var prefix: KeyChord
        var pending: PendingModifiers
        var triggerPending: Bool
        /// The exact catalog the key router will consult. Passing the panel's own list here
        /// would hide the second half of the ⌥⌘M bug: that row came from `systemBindings`,
        /// which the router had not been given. The caller supplies what the engine uses.
        var routingItems: [BindingItem]
    }

    /// - Parameters:
    ///   - items: every shortcut the panel could list, not only the current page. A row that
    ///     is filtered out today is still one the user may see after the next press, so its
    ///     reachability belongs in the same answer.
    static func audit(items: [BindingItem], context: Context) -> Result {
        var findings: [Finding] = []
        for item in items {
            if let reason = reason(for: item, context: context) {
                findings.append(Finding(rowID: item.id, reason: reason))
            }
        }
        return Result(findings: findings)
    }

    private static func reason(for item: BindingItem, context: Context) -> Reason? {
        // A chord is triggered by its last key-bearing step. Multi-stroke chords (⌘K ⌘C)
        // are judged on that final press with the current prefix already in the context;
        // a step with no key is a held-modifier state, not a press.
        guard let step = item.chord.steps.last(where: { !$0.isModifierOnly }),
              let key = step.key,
              let keyCode = KeyMapper.keyCode(for: key)
        else { return .unmappableKey }

        let event = KeyEvent(
            kind: .keyDown,
            modifiers: step.modifiers,
            key: key,
            keyCode: keyCode,
            isRepeat: false,
            happenedAt: Date(),
            characters: key.raw
        )

        let filterDecision = PanelFilterPlan.decision(
            for: event,
            filter: context.panel.filter,
            phase: context.phase,
            shiftHintActive: context.panel.shiftHintActive,
            triggerPending: context.triggerPending,
            triggerKey: context.settings.triggerKey
        )
        if filterDecision != .none { return .claimedByFilter }

        let action = KeyEventRouter.route(
            event,
            in: RoutingContext(
                phase: context.phase,
                settings: context.settings,
                panel: context.panel,
                prefix: context.prefix,
                pending: context.pending,
                items: context.routingItems
            )
        )
        switch action {
        case .passThrough, .replayComposed, .descend, .performRow:
            // The press either is the shortcut, is replayed for the app, opens a deeper
            // level, or runs the selected row. All four mean the user can trigger it.
            return nil
        case .noMatch:
            return .unresolvedByRouter
        default:
            return .capturedByPanelKey
        }
    }
}
