import Foundation

/// Whether a visible panel still belongs to the app in front.
///
/// The panel is persistent while the user stays with one app: no idle timer, no auto-hide.
/// But its rows were read from the menu bar of the app it was opened over. Once that app is
/// no longer in front — a desktop switch, a full-screen app, Mission Control — those rows
/// are stale, and the window follows the user because it joins every Space. Worse, the
/// engine is still `.active`, so its tap keeps eating keys on the new Space: the next
/// trigger press takes the *close* branch of `togglePinnedPanel()` and the user has to
/// press twice to get a panel again.
///
/// The answer is about the **current** frontmost app, never the app named in a workspace
/// notification. Notifications arrive late and out of order, and Kaname itself causes some
/// of them (the search palette hands focus back before reopening the panel). Reading the
/// live menu-bar owner on the following run loop is what makes those hand-offs harmless.
nonisolated enum FocusDismissPolicy {
    struct Context: Equatable, Sendable {
        var panelVisible: Bool
        /// The app this panel was opened over; nil outside a panel session.
        var ownerPID: pid_t?
        /// The app currently owning the menu bar; nil while macOS has not settled.
        var currentPID: pid_t?
        /// Kaname itself is frontmost during its own focus hand-offs. That is a transition,
        /// not the user leaving the app the panel belongs to.
        var currentIsSelf: Bool
        var isPreviewing: Bool
    }

    static func shouldDismiss(_ context: Context) -> Bool {
        guard context.panelVisible, !context.isPreviewing else { return false }
        // No recorded owner means there is nothing to compare against. Refusing to close
        // is the safe answer: an unexplained signal must not kill a working panel.
        guard let owner = context.ownerPID, owner > 0 else { return false }
        // A transient self-frontmost (or unknown) reading is a hand-off in flight, not a
        // switch away. Closing here is exactly the "returning from search closes the panel
        // that was just opened" regression.
        guard !context.currentIsSelf, let current = context.currentPID, current > 0 else { return false }
        return current != owner
    }
}

/// One focus-change episode produces at most one catalog rescan.
///
/// A single desktop switch can deliver `didDeactivate`, `didActivate` and
/// `activeSpaceDidChange` within a few hundred milliseconds. The first pair used to run a
/// non-forced scan for the new app, and the Space observer a forced one right after it —
/// two AX walks of the same menu bar. This gate merges the requests inside one episode and
/// keeps the strongest parameters any caller asked for: a forced scan that tolerates an
/// empty result wins over a plain one.
///
/// The window itself is `SpaceRescanGate`'s: the same pid inside 0.75 s is one episode, a
/// different pid starts a new one immediately. Once the episode's scan has run, later
/// signals from that same episode are ignored rather than scheduled again.
nonisolated struct FocusRescanGate: Sendable {
    struct Request: Equatable, Sendable {
        var force: Bool
        var preserveOnEmpty: Bool

        func merged(with other: Request) -> Request {
            Request(
                force: force || other.force,
                preserveOnEmpty: preserveOnEmpty || other.preserveOnEmpty
            )
        }
    }

    private var window = SpaceRescanGate(interval: 0.75)
    private var pending: Request?
    private var episodeDidRun = false

    /// - Returns: the merged request the engine should schedule (its single delayed work
    ///   item is cancelled and re-armed with this value), or nil when the episode has
    ///   already been scanned and this signal must not cause a second walk.
    mutating func absorb(_ request: Request, pid: pid_t, at date: Date) -> Request? {
        if window.shouldScan(pid: pid, at: date) {
            pending = request
            episodeDidRun = false
            return request
        }
        guard !episodeDidRun else { return nil }
        let merged = (pending ?? request).merged(with: request)
        pending = merged
        return merged
    }

    /// The request the debounce fires with, which also ends the episode.
    mutating func take() -> Request? {
        let request = pending
        pending = nil
        episodeDidRun = request != nil
        return request
    }
}
