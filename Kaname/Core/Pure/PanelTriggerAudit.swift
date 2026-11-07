import Foundation

/// Answers one question about every row the panel can list: is there *any* way for the user
/// to execute this command?
///
/// There are two independent paths, and the answer is the union of them, not either one:
///
/// - **Shortcut** — the user presses the chord. The last key has to survive the filter queue
///   and reach the key router. This is the half that caught ⌥⌘M (a system row the router had
///   not been given) and Safari's ⌥⌘F (whose last key the filter claimed as a search token).
/// - **Activation** — the user clicks the row, presses the run key, or uses a Shift-hint
///   glyph. This path never goes through the filter or the router: it presses the menu item's
///   Accessibility element, or replays the chord straight into the front app. It is why a
///   command *with no shortcut at all* is perfectly executable, and why a row whose chord is
///   swallowed by the filter is still usable.
///
/// Marking a row "cannot be executed" because its chord cannot be pressed was a false
/// positive: the click path was never consulted. A row is now unreachable only when both
/// paths are closed. The intermediate verdict — chord blocked, click fine — is kept too, so
/// the self-check still exposes routing bugs without calling an executable row broken.
///
/// Both halves are pure. Nothing here sends a key, presses a menu item or touches the event
/// tap: the simulated `KeyEvent` is only ever handed to pure functions, and the activation
/// half replays the panel's own decision table rather than performing it.
nonisolated enum PanelTriggerAudit {
    /// Why a chord's last press cannot reach the front app. A blocker is only half a verdict.
    enum ShortcutBlocker: String, CaseIterable, Sendable {
        /// The row has no shortcut. Not a defect: these rows are executed by activation.
        case noChord
        /// The filter queue turned the key into a search token instead of a stroke.
        case claimedByFilter
        /// The panel used the key for one of its own actions (search, paging, Escape, …).
        case capturedByPanelKey
        /// The chord was offered to composition and matched nothing.
        case unresolvedByRouter
        /// The key has no virtual key code, so a press cannot be simulated or replayed.
        case unmappableKey
    }

    /// Why activating the row does not run the command.
    enum ActivationBlocker: String, CaseIterable, Sendable {
        /// The app's menu item is disabled: `activateCatalogItem` refuses before any press.
        case disabledItem
        /// A restricted system action or a config-tool row never runs, by policy.
        case refusedByPolicy
        /// No Accessibility element to press and no chord to replay.
        case noExecutionTarget
    }

    /// The per-row answer the leading status dot draws. Three states, three colours.
    /// A command with no shortcut is not "degraded": there is no chord to block, so a
    /// clickable one is plain green. Likewise a row whose chord works but whose click is
    /// refused stays green — it can still be executed — with the refusal named on hover.
    enum Status: String, CaseIterable, Sendable {
        /// At least one path runs the command and no chord is blocked. Green.
        case executable
        /// A chord exists but the pipeline blocks it; clicking still runs the row. Yellow.
        case shortcutBlocked
        /// Neither path runs the command. Red.
        case unreachable
    }

    struct Verdict: Equatable, Sendable {
        let rowID: String
        let status: Status
        /// Nil when the chord reaches the front app.
        let shortcutBlocker: ShortcutBlocker?
        /// Nil when clicking the row runs the command.
        let activationBlocker: ActivationBlocker?
    }

    struct Result: Equatable, Sendable {
        /// One verdict per audited item, in the same order. Empty when the setting is off.
        var verdicts: [Verdict] = []

        var unreachable: [Verdict] { verdicts.filter { $0.status == .unreachable } }
        var unreachableRowIDs: Set<String> { Set(unreachable.map(\.rowID)) }

        func verdict(forRowID id: String) -> Verdict? {
            verdicts.first { $0.rowID == id }
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
        /// Row ids carrying a live Accessibility element in the current snapshot. Clicking
        /// one of these presses the menu item directly, shortcut or no shortcut.
        var pressableRowIDs: Set<String> = []
        /// Whether Accessibility is trusted. Without it there is no element to press, so a
        /// chord-less row has only its (empty) shortcut to fall back on.
        var hasAccessibility = true
        /// A snapshot restored from the disk cache has no elements but can re-walk a menu
        /// path when it still knows the app's pid.
        var canResolveMenuPath = true
    }

    /// - Parameters:
    ///   - items: every shortcut the panel could list, not only the current page. A row that
    ///     is filtered out today is still one the user may see after the next press, so its
    ///     reachability belongs in the same answer.
    static func audit(items: [BindingItem], context: Context) -> Result {
        Result(verdicts: items.map { verdict(for: $0, context: context) })
    }

    private static func verdict(for item: BindingItem, context: Context) -> Verdict {
        let shortcut = shortcutBlocker(for: item, context: context)
        let activation = activationBlocker(for: item, context: context)
        // `.noChord` is a property of the command, not a path that failed. Counting it as
        // a blocked shortcut would turn every shortcut-less menu item amber even though it
        // runs perfectly well when clicked.
        let chordIsBlocked = shortcut.map { $0 != .noChord } ?? false
        let aPathWorks = shortcut == nil || activation == nil
        let status: Status = !aPathWorks
            ? .unreachable
            : (chordIsBlocked ? .shortcutBlocked : .executable)
        return Verdict(
            rowID: item.id,
            status: status,
            shortcutBlocker: shortcut,
            activationBlocker: activation
        )
    }

    // MARK: - Path one: pressing the chord

    private static func shortcutBlocker(
        for item: BindingItem,
        context: Context
    ) -> ShortcutBlocker? {
        // No chord means there is no press to simulate. That is a property of the command,
        // not a failure of the pipeline; activation decides whether the row is executable.
        guard !item.chord.isEmpty else { return .noChord }

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

    // MARK: - Path two: activating the row

    /// Mirrors `PanelSession.performPanelRow` → `PanelRowActionPlan` → `RowRunner.run`, but
    /// as a decision only. The same table decides whether a click runs, the same disabled
    /// guard refuses a press, and the same two effects (AX press, chord replay) count as a
    /// target. Keeping those three in one pure place is what stops the audit from inventing
    /// an execution path the engine does not have — or denying one it does.
    private static func activationBlocker(
        for item: BindingItem,
        context: Context
    ) -> ActivationBlocker? {
        let outcome = PanelRowActionPlan.outcome(
            request: .click,
            restriction: RestrictedActionPolicy.restriction(for: item),
            source: item.source,
            hasChord: !item.chord.isEmpty
        )
        // A config-tool row copies its shortcut, and a restricted action shows a notice.
        // Neither reaches `RowRunner`.
        guard outcome == .run else { return .refusedByPolicy }

        // `activateCatalogItem` refuses a disabled menu item before it claims the run slot.
        // System hotkeys go through `runSystemHotkey`, which has no such guard.
        if item.source != .system, !item.isEnabled { return .disabledItem }

        switch item.source {
        case .system:
            // A system row has no element to press: `runSystemHotkey` replays its chord.
            guard !item.chord.isEmpty else { return .noExecutionTarget }
        case .configFile:
            // Already refused by the plan above; kept explicit so a future plan change
            // cannot quietly turn a config row into an executable one here.
            return .refusedByPolicy
        default:
            // `RowRunner.run` presses the element when it can resolve one, and only falls
            // back to replaying the chord when it cannot. A chord-less command is therefore
            // executable exactly when its menu item can be pressed.
            let canPress = context.hasAccessibility && (
                context.pressableRowIDs.contains(item.id)
                    || (context.canResolveMenuPath && item.axPath != nil)
            )
            guard canPress || !item.chord.isEmpty else { return .noExecutionTarget }
        }
        return nil
    }
}
