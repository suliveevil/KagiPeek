import AppKit
import CoreGraphics
import Foundation
import os

/// Replays a shortcut into the app it was meant for.
///
/// The panel and the search palette both take the keyboard while they are open, so a run
/// ends by giving focus back to the app the row belongs to and posting the chord. Typing
/// into whatever happens to be in front is not a substitute: the key events would land in
/// another window, do something unpredictable there, and look like the command ran. The
/// target is therefore named up front and checked after activation; a target that does not
/// reach the front in the short wait aborts the replay with a failure the caller can show.
enum ShortcutInjector {
    /// How long the target gets to become the front app before the chord is withheld.
    private static let activationTimeout: TimeInterval = 0.5
    /// Short enough that a successful activation is not padded, long enough not to spin.
    private static let activationPollInterval: TimeInterval = 0.02
    /// The gap between strokes of a multi-step chord, so the app sees them as typed.
    private static let stepInterval: TimeInterval = 0.04

    /// Posts `chord` after making sure the app it belongs to is in front.
    ///
    /// When `target` is nil the chord is replayed into whatever is frontmost — the system
    /// hotkey path, where there is no owner to name. Otherwise the target is activated (if
    /// needed), waited for, and verified; nothing is posted unless the verdict is to send.
    ///
    /// Every suspension in here is a cancellation checkpoint. `Task.sleep` is the only one
    /// that reports cancellation at all, and swallowing it (`try?`) is how a cancelled
    /// replay used to walk on to the next line and post the chord anyway.
    @discardableResult
    @MainActor
    static func post(
        _ chord: KeyChord,
        to target: InjectionTarget? = nil,
        delay: TimeInterval = 0.15
    ) async -> InjectionOutcome {
        if Task.isCancelled { return .cancelled }
        let steps = chord.steps.filter { $0.key != nil }
        guard !steps.isEmpty else {
            // Nothing was posted, so nothing happened in the app — indistinguishable from a
            // command that ran and did nothing.
            Diag.error(.inject, "empty chord, nothing posted")
            return .emptyChord
        }
        guard let target else {
            return await postSteps(steps, target: nil)
        }

        // The activation itself is verified before the wait; the verdict is carried over so
        // the post-wait check can compare where the target was with where it is now.
        let beforeDelay: InjectionTargetVerdict
        switch await prepareFrontmost(target) {
        case .failed(let outcome):
            return outcome
        case .ready(let verdict):
            beforeDelay = verdict
        }
        // Activation can take up to the timeout above, which is long enough for the engine
        // to have cancelled this replay in the meantime.
        if Task.isCancelled {
            Diag.info(.inject, "replay cancelled after activation, nothing posted")
            return .cancelled
        }
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                Diag.info(.inject, "replay cancelled during the activation wait, nothing posted")
                return .cancelled
            }
        }
        // Re-verify after the wait. A different app coming forward during it means a key
        // posted now would land in that app; the chord is withheld instead.
        let afterDelay = InjectionTimeline.verdict(target: target, frontmost: frontmostState())
        if let refusal = InjectionTimeline.outcome(beforeDelay: beforeDelay, afterDelay: afterDelay) {
            Diag.error(.inject, """
                target changed during the wait: expected pid=\(target.processID) \
                bundle=\(target.bundleID ?? "?"), before=\(beforeDelay), after=\(afterDelay)
                """)
            return refusal
        }
        return await postSteps(steps, target: target)
    }

    private enum Preparation {
        case ready(InjectionTargetVerdict)
        case failed(InjectionOutcome)
    }

    /// Activates the target when needed and returns the verdict observed after the
    /// activation settles.
    @MainActor
    private static func prepareFrontmost(_ target: InjectionTarget) async -> Preparation {
        guard let app = NSRunningApplication(processIdentifier: target.processID) else {
            Diag.error(.inject, "target pid \(target.processID) is gone, nothing posted")
            return .failed(.targetMissing)
        }
        if !app.isActive {
            // macOS 14 replaced `activate(options: .activateIgnoringOtherApps)` with plain
            // `activate()`: the system decides whether the request is honoured. A refusal
            // shows up as "never became active" and is reported, never worked around.
            app.activate()
            switch await waitUntilActive(app) {
            case .active:
                break
            case .cancelled:
                Diag.info(.inject, "replay cancelled while waiting for pid \(target.processID), nothing posted")
                return .failed(.cancelled)
            case .timedOut:
                logMismatch(target, app: app, reason: "did not become frontmost")
                return .failed(.targetNotFrontmost)
            }
        }
        let verdict = InjectionTimeline.verdict(target: target, frontmost: frontmostState())
        guard verdict == .send else {
            logMismatch(target, app: app, reason: "\(verdict)")
            return .failed(.targetNotFrontmost)
        }
        return .ready(verdict)
    }

    /// The front app plus whether the target process itself is active. Read at the instant
    /// of the check; the pure timeline functions do the comparing.
    @MainActor
    private static func frontmostState() -> FrontmostState {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let pid = frontmost?.processIdentifier
        return FrontmostState(
            bundleID: frontmost?.bundleIdentifier,
            processID: pid,
            isActive: pid.flatMap(NSRunningApplication.init(processIdentifier:))?.isActive ?? false
        )
    }

    /// The last checkpoint: verify again immediately before each step. For a single-key
    /// chord this is the "one more look right before the first key" that the activation
    /// wait cannot cover; for a multi-step chord it stops the remaining steps as soon as
    /// the target loses focus.
    @MainActor
    private static func stepRefusal(_ target: InjectionTarget, step index: Int) -> InjectionOutcome? {
        let state = frontmostState()
        let verdict = InjectionTimeline.verdict(target: target, frontmost: state)
        guard verdict != .send else { return nil }
        let app = NSRunningApplication(processIdentifier: target.processID)
        if let app {
            logMismatch(target, app: app, reason: "changed before step \(index + 1): \(verdict)")
        } else {
            Diag.error(.inject, "target pid \(target.processID) disappeared before step \(index + 1)")
        }
        return app == nil ? .targetMissing : .targetNotFrontmost
    }

    private enum ActivationWait {
        case active
        case timedOut
        /// The task was cancelled: not the same as "the app refused to come forward", and
        /// reporting it as a failure would blame the target for the engine's own decision.
        case cancelled
    }

    @MainActor
    private static func waitUntilActive(_ app: NSRunningApplication) async -> ActivationWait {
        let deadline = Date().addingTimeInterval(activationTimeout)
        while Date() < deadline {
            if app.isActive { return .active }
            do {
                try await Task.sleep(nanoseconds: UInt64(activationPollInterval * 1_000_000_000))
            } catch {
                return .cancelled
            }
        }
        return app.isActive ? .active : .timedOut
    }

    private static func logMismatch(_ target: InjectionTarget, app: NSRunningApplication, reason: String) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        Diag.error(.inject, """
            target not frontmost (\(reason)): expected pid=\(target.processID) \
            bundle=\(target.bundleID ?? "?") active=\(app.isActive) \
            front=[\(frontmost?.processIdentifier ?? -1):\(frontmost?.bundleIdentifier ?? "?")]
            """)
    }

    @MainActor
    private static func postSteps(_ steps: [KeyStep], target: InjectionTarget?) async -> InjectionOutcome {
        for (index, step) in steps.enumerated() {
            // Checked before every stroke, not just once at the start: a multi-step chord
            // cancelled half way must stop there instead of finishing the sequence.
            if Task.isCancelled { return .cancelled }
            if let target, let refusal = stepRefusal(target, step: index) {
                return refusal
            }
            guard let key = step.key, let keyCode = KeyMapper.keyCode(for: key) else {
                Diag.error(.inject, "step skipped: no virtual key for \(step.key.map { "\($0)" } ?? "nil")")
                continue
            }
            guard postKey(keyCode: keyCode, flags: ModifierSet.cgEventFlags(for: step.modifiers)) else {
                return .eventCreationFailed
            }
            // No gap after the last stroke: nothing follows it, so the only thing a trailing
            // sleep can do is turn a cancellation into a `.cancelled` verdict for a chord
            // that was in fact posted in full.
            if index < steps.count - 1 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(stepInterval * 1_000_000_000))
                } catch {
                    return .cancelled
                }
            }
        }
        return .sent
    }

    /// - Returns: whether both events were created and posted. A silent failure here is
    /// indistinguishable from "the app ignored the shortcut", so it is reported.
    private static func postKey(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Diag.error(.inject, "could not create key events for virtual key \(keyCode)")
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
