import Foundation

/// What the drag guide is telling the user right now.
///
/// Modelled on the state machine LobeHub's desktop permission guide runs
/// (`feat/macos-permission-drag-guide`): the panel is not a static hint, it reports the
/// four ways the drag flow goes wrong instead of pretending it is still waiting. Every
/// phase below is a state the user can actually be in — nothing here is a spinner.
enum PermissionGuidePhase: String, Equatable, Sendable {
    /// The panel is up and the icon is waiting to be dragged into the list.
    case dragging
    /// A password / Touch ID prompt is up, or the drag has been made: the grant is in flight.
    case waiting
    /// The grant landed; the panel shows it for a moment before closing.
    case granted
    /// System Settings went away before the grant landed.
    case settingsClosed
    /// The user navigated to another page of System Settings.
    case leftPane
    /// The password / Touch ID prompt was dismissed without a grant.
    case cancelled
}

/// The things the outside world can do to the guide.
enum PermissionGuideEvent: Equatable, Sendable {
    /// A System Settings window came back (or appeared for the first time).
    case settingsAppeared
    /// No System Settings window is on screen any more.
    case settingsLost
    /// The front page of System Settings is the privacy page the list lives on.
    case paneMatched
    /// System Settings is showing a different page.
    case paneLeft
    /// A password / Touch ID prompt is up over the Settings window.
    case sheetShown
    /// That prompt went away without the grant landing.
    case sheetDismissed
    /// The permission check now reports granted.
    case granted
}

/// The one button the panel offers, when the phase needs the user to do something that is
/// not dragging.
enum PermissionGuideAction: Equatable, Sendable {
    /// Reopen System Settings on the permission's own pane.
    case openSettings
    /// Go back to the privacy page the list lives on.
    case goBack
}

/// Pure transitions and copy for the guide. Kept out of the controller so the four
/// recovery branches are unit-testable without a live System Settings window — which is
/// exactly the part that is impossible to exercise by hand.
enum PermissionGuideState {
    /// The next phase for `phase` when `event` happens.
    ///
    /// `granted` wins everywhere: a grant that lands while the panel is showing a recovery
    /// message still means the flow succeeded, and saying otherwise would strand the user
    /// on an instruction they no longer need.
    static func next(_ phase: PermissionGuidePhase, on event: PermissionGuideEvent) -> PermissionGuidePhase {
        if event == .granted { return .granted }
        guard phase != .granted else { return .granted }

        switch event {
        case .settingsLost:
            // A prompt disappearing takes the Settings window list with it on some
            // configurations; the lost window is the more actionable message.
            return .settingsClosed
        case .paneLeft:
            return .leftPane
        case .sheetShown:
            return .waiting
        case .sheetDismissed:
            // Only a prompt the user cancelled is news. A dismissal that was actually the
            // grant arriving is handled by `granted` above.
            return phase == .waiting ? .cancelled : phase
        case .settingsAppeared, .paneMatched:
            return recoveryTarget(from: phase)
        case .granted:
            return .granted
        }
    }

    /// Coming back to a live Settings window on the right page clears every "you are in the
    /// wrong place" message, and refuses to invent progress the user has not made: a
    /// cancelled drag stays cancelled until they drag again, because macOS gives no signal
    /// for "the icon moved" before the prompt appears.
    private static func recoveryTarget(from phase: PermissionGuidePhase) -> PermissionGuidePhase {
        switch phase {
        case .settingsClosed, .leftPane: return .dragging
        case .dragging, .waiting, .cancelled, .granted: return phase
        }
    }

    /// The button the phase needs, if any.
    static func action(for phase: PermissionGuidePhase) -> PermissionGuideAction? {
        switch phase {
        case .settingsClosed: return .openSettings
        case .leftPane: return .goBack
        case .dragging, .waiting, .granted, .cancelled: return nil
        }
    }

    /// The headline inside the panel: the permission's own name while everything is on
    /// track, and the problem itself once it is not.
    static func headlineKey(for phase: PermissionGuidePhase, permissionTitle: L10nKey) -> L10nKey {
        switch phase {
        case .dragging: return permissionTitle
        case .waiting: return .permissionGuideWaiting
        case .granted: return .permissionGuideGranted
        case .settingsClosed: return .permissionGuideSettingsClosed
        case .leftPane: return .permissionGuideLeftPane
        case .cancelled: return .permissionGuideCancelled
        }
    }

    /// The instruction under the headline. While the flow is healthy this is the drag
    /// instruction plus the stale-entry hint; while it is not, it is the recovery hint, so
    /// the panel never asks for a drag it cannot receive.
    static func detailKey(for phase: PermissionGuidePhase) -> L10nKey {
        switch phase {
        case .dragging: return .permissionGuideDrag
        case .waiting: return .permissionGuideWaitingHint
        case .granted: return .permissionGuideGrantedHint
        case .settingsClosed: return .permissionGuideSettingsClosedHint
        case .leftPane: return .permissionGuideLeftPaneHint
        case .cancelled: return .permissionGuideCancelledHint
        }
    }

    /// The label on the phase's button.
    static func actionKey(for action: PermissionGuideAction) -> L10nKey {
        switch action {
        case .openSettings: return .permissionGuideOpenSettings
        case .goBack: return .permissionGuideGoBack
        }
    }

    /// Whether the icon is worth showing as a drag source. A closed Settings window has no
    /// list to drop into, and offering the drag there is what made the old flow feel broken.
    static func showsDragSource(_ phase: PermissionGuidePhase) -> Bool {
        switch phase {
        case .dragging, .waiting, .cancelled: return true
        case .settingsClosed, .leftPane, .granted: return false
        }
    }
}
