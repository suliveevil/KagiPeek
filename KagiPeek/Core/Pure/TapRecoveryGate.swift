/// Whether a tap-disable notification should start a recovery, and whether that recovery is
/// still on the books.
///
/// The monitor's `pendingReEnable` work item was cleared only when it actually ran. A work
/// item cancelled by the safety net, or one whose run loop never drained, left the flag set
/// forever: every later disable was dropped and only a relaunch brought shortcuts back.
/// This value keeps the two questions in one place so the failure modes are testable.
nonisolated struct TapRecoveryGate: Equatable {
    /// A re-enable is queued: a second disable describes the same failure, not a new one.
    private(set) var isPending = false

    /// A disabled tap is only worth handling while the monitor is running and no re-enable
    /// is already in flight.
    func shouldHandleDisable(isRunning: Bool) -> Bool {
        isRunning && !isPending
    }

    /// A re-enable is now queued.
    mutating func schedule() {
        isPending = true
    }

    /// The queued re-enable ran, was cancelled, or was never scheduled. Whatever the reason,
    /// the next disable must be allowed to start a new recovery.
    mutating func finish() {
        isPending = false
    }
}
