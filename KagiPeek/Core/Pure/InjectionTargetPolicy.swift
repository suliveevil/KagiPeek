import Foundation

/// The app a replayed chord is meant for.
///
/// A panel row and a search result both belong to an app, and both are triggered after
/// Kaname took the keyboard — so the app has to be brought back to the front before the
/// key events are posted. This is the name that decision is made against.
nonisolated struct InjectionTarget: Equatable, Sendable {
    let processID: Int32
    let bundleID: String?

    init(processID: Int32, bundleID: String?) {
        self.processID = processID
        self.bundleID = bundleID
    }
}

/// How a replay ended. Anything but `.sent` means the chord did not go out as a whole;
/// `.cancelled` is the one case that can follow a partly posted multi-step chord.
nonisolated enum InjectionOutcome: Equatable, Sendable {
    case sent
    /// The chord had no key steps, so there was nothing to type.
    case emptyChord
    /// The target process is gone: the app quit or was relaunched since the scan.
    case targetMissing
    /// The target did not become the front app within the wait, so the chord was withheld.
    case targetNotFrontmost
    /// `CGEvent` creation failed; the chord could not be posted.
    case eventCreationFailed
    /// The replay was cancelled at one of its checkpoints.
    ///
    /// Unlike the cases above this is neither success nor failure: the engine stopped the
    /// hand-off (shutdown, or a newer replay replacing this one), so the caller must not
    /// report it as a command that failed. A multi-step chord can be cancelled between
    /// strokes, so "cancelled" promises only that no *further* key was posted.
    case cancelled
}

/// Whether the app in front is the one the chord was built for.
nonisolated enum InjectionTargetVerdict: Equatable, Sendable {
    case send
    case noFrontmostApp
    case wrongApp
    case notActive
}

/// The decision `ShortcutInjector` makes before posting: a chord replayed into the wrong
/// app is worse than no chord at all, because it does something unpredictable in another
/// window and looks like the command ran.
nonisolated enum InjectionTargetPolicy {
    /// A target matches the front app when the process ids agree — a relaunch is a different
    /// process even when the bundle id is the same — and, when both sides know it, the bundle
    /// id agrees too.
    static func matches(
        target: InjectionTarget,
        frontmostBundleID: String?,
        frontmostPID: Int32?
    ) -> Bool {
        guard let frontmostPID, frontmostPID == target.processID else { return false }
        if let expected = target.bundleID, let actual = frontmostBundleID {
            return expected == actual
        }
        return true
    }

    static func verdict(
        target: InjectionTarget,
        frontmostBundleID: String?,
        frontmostPID: Int32?,
        isActive: Bool
    ) -> InjectionTargetVerdict {
        guard isActive else { return .notActive }
        guard frontmostPID != nil else { return .noFrontmostApp }
        return matches(
            target: target,
            frontmostBundleID: frontmostBundleID,
            frontmostPID: frontmostPID
        ) ? .send : .wrongApp
    }
}

/// The front app as it looked at one instant. Captured around the activation delay so the
/// two checks compare the same facts instead of re-reading the world at decision time.
nonisolated struct FrontmostState: Equatable, Sendable {
    let bundleID: String?
    let processID: Int32?
    let isActive: Bool
}

/// The two checks around the activation delay.
///
/// The first check happens after activation and before the wait. The second happens after
/// the wait and immediately before the first key. A target that was correct before the wait
/// but moved during it must receive none of the chord: posting the first step into the
/// wrong app is the failure this ordering exists to prevent.
nonisolated enum InjectionTimeline {
    static func verdict(target: InjectionTarget, frontmost: FrontmostState) -> InjectionTargetVerdict {
        InjectionTargetPolicy.verdict(
            target: target,
            frontmostBundleID: frontmost.bundleID,
            frontmostPID: frontmost.processID,
            isActive: frontmost.isActive
        )
    }

    /// `nil` means the chord may be posted. Any checkpoint that did not clear withholds all
    /// keys, including a target that changed between the two checks.
    static func outcome(
        beforeDelay: InjectionTargetVerdict,
        afterDelay: InjectionTargetVerdict
    ) -> InjectionOutcome? {
        guard beforeDelay == .send, afterDelay == .send else { return .targetNotFrontmost }
        return nil
    }
}
