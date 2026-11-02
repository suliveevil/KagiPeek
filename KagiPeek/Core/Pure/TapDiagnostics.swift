import Foundation

/// The one line that explains a tap failure afterwards.
///
/// Every freeze investigated so far was diagnosed from this line and nothing else, so its
/// fields are load-bearing rather than decorative:
///
/// - **`attempt`** — which disable in the current episode this is. When it stopped climbing
///   (eleven `attempt 1`s in two minutes) the backoff was never reached, and that was the
///   bug.
/// - **`trusted`** — the process's own view of Accessibility. It read `true` through all
///   five episodes on 2026-11-02, which is why "detect the revocation and shut down" was
///   never a workable plan: macOS does not withdraw the grant from a running process.
/// - **`enabled`** — what *the system* thinks of the tap. Disagreement with `trusted` is the
///   only way to tell "our tap is stale" apart from "the system is refusing events".
/// - **`stoodForMilliseconds`** — how long the tap survived since it was last turned on. A
///   timeout milliseconds after the enable means events never reached the callback; one a
///   minute later is a fresh episode. Without this the two are indistinguishable.
///
/// Pure formatting, so the line can be pinned by a test: reading a diagnostic wrong costs
/// another freeze to re-measure.
nonisolated struct TapDiagnostics: Equatable {
    enum Trigger: String {
        case timeout
        /// The user asked for the tap to stop (another process enabled secure input).
        case userInput = "user input"
    }

    var trigger: Trigger
    /// Which disable in the current episode, counting from one.
    var attempt: Int
    var trusted: Bool
    var enabled: Bool
    /// Milliseconds the tap stood since its last enable; nil when it was never recorded.
    var stoodForMilliseconds: Int?
    var recovery: TapRecovery

    /// The measured fields alone. This is what a teardown line carries: the sentence around
    /// it already says the tap is gone, so appending "giving up" would say it twice.
    var detail: String {
        let stood = stoodForMilliseconds.map(String.init) ?? "?"
        return "event tap disabled by the system (\(trigger.rawValue)); "
            + "attempt \(attempt), trusted=\(trusted), enabled=\(enabled), stood_ms=\(stood)"
    }

    /// What the tap decided to do about it, appended to `detail`.
    var line: String {
        detail + " — " + Self.describe(recovery)
    }

    private static func describe(_ recovery: TapRecovery) -> String {
        switch recovery {
        case let .reEnable(delay): return "re-enabling in \(delay)s"
        case .tearDown: return "giving up"
        }
    }
}
