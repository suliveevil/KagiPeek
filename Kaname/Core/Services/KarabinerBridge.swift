import Foundation

/// Keeps Karabiner-Elements' `kaname_panel` variable in step with the panel.
///
/// `KarabinerPanelSignal` explains why the variable exists; this type owns only the transport.
/// One `karabiner_cli` run per state change, on a queue of its own, coalesced: opening and
/// closing the panel twice in a second costs at most one write per state, and the run loop that
/// just drew the panel never waits for a child process.
///
/// Failure is deliberately quiet. Karabiner may not be installed, its CLI may be busy, and the
/// write may be refused — none of that is worth interrupting the panel the user just asked for,
/// and none of it is an error the user can act on in the middle of using the app. The first
/// failure is logged once; after that the bridge stays silent and keeps retrying on the next
/// state change.
nonisolated final class KarabinerBridge: @unchecked Sendable {
    /// Where the Karabiner-Elements installer puts its CLI. There is no PATH entry for it and
    /// no preference carries a path, so this is the only address Kaname can know.
    ///
    /// `KANAME_KARABINER_CLI` overrides it. That exists so a fake CLI — one that sleeps
    /// instead of exiting — can prove the bound in `write` on a machine without Karabiner
    /// installed; it is not a user-facing preference.
    static var defaultCLIPath: String {
        let override = ProcessInfo.processInfo.environment["KANAME_KARABINER_CLI"]
        if let override, !override.isEmpty { return override }
        return "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
    }

    /// A `karabiner_cli` run that has not exited by then is terminated and reported as a
    /// failure.
    ///
    /// The CLI talks to Karabiner's daemon over a Unix socket, and a wedged daemon leaves the
    /// child hanging forever. That used to be unbounded on the termination path, where it is
    /// not a hang but a quit the user can only finish by forcing the app — and the two store
    /// flushes queued behind it never ran, taking the last settings edit with them.
    /// `DiagnosticsExporter.runDitto` (20 s) and `FileLogStore.flushNow` (0.5 s) bound their
    /// waits the same way.
    static let writeTimeout: TimeInterval = 0.8

    private let cliPath: String
    private let fileManager: FileManager
    private let queue = DispatchQueue(
        label: "com.suliveevil.kaname.karabiner-bridge",
        qos: .utility
    )
    private let lock = NSLock()
    /// What the variable is believed to hold. Nil until the first successful write — which is
    /// why the first publish always speaks: a force quit can leave a stale 1 behind, and this
    /// process cannot know until it has looked.
    private var lastWritten: Bool?
    /// The state asked for most recently. Only the newest matters; older ones are already
    /// superseded by the time a process could start.
    private var desired = false
    private var isDrainScheduled = false
    private var hasReportedFailure = false

    init(cliPath: String = KarabinerBridge.defaultCLIPath, fileManager: FileManager = .default) {
        self.cliPath = cliPath
        self.fileManager = fileManager
    }

    /// Whether Karabiner-Elements is installed where Kaname looks. The settings page says so
    /// next to the switch; the bridge uses the same check to stay quiet when there is nobody
    /// to talk to.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: defaultCLIPath)
    }

    /// While the panel is up and the switch is on, the variable reads 1; every other state
    /// writes 0.
    func publish(panelIsVisible: Bool, isEnabled: Bool) {
        let value = KarabinerPanelSignal.desiredState(
            panelIsVisible: panelIsVisible,
            isEnabled: isEnabled
        )
        lock.lock()
        desired = value
        let needsDrain = !isDrainScheduled
        isDrainScheduled = true
        lock.unlock()
        guard needsDrain else { return }
        queue.async { [weak self] in self?.drain() }
    }

    /// Brings the variable to 0 and waits for it. Called on the way out: the process is about
    /// to end, an async write would be cut in half by the exit, and leaving a 1 behind would
    /// suppress the user's rule until the next launch.
    ///
    /// Deliberately not `publish` plus a synchronous drain: that schedules a second drain
    /// behind this one, and a CLI that times out is then paid for twice. Setting the request
    /// and draining once means a wedged `karabiner_cli` costs one `writeTimeout` here.
    func clearAndWait() {
        lock.lock()
        desired = false
        lock.unlock()
        queue.sync { [self] in drain() }
    }

    // MARK: - Transport

    private func drain() {
        lock.lock()
        isDrainScheduled = false
        let value = desired
        let known = lastWritten
        lock.unlock()

        // Nothing to say: the variable already holds what the panel state asks for.
        guard known != value else { return }
        guard isAvailable else {
            reportFailureOnce("karabiner_cli not found at \(cliPath)")
            return
        }
        guard write(value) else { return }

        lock.lock()
        lastWritten = value
        lock.unlock()
    }

    private var isAvailable: Bool {
        fileManager.isExecutableFile(atPath: cliPath)
    }

    /// Runs the CLI once. Returns whether it exited cleanly.
    ///
    /// Output goes to /dev/null rather than a pipe: nothing reads it, and an unread pipe fills
    /// up and blocks the child until the timeout. The wait is bounded by `writeTimeout`: on
    /// timeout the child is asked to terminate and the write is reported as failed, because a
    /// quit must not be held hostage by another process.
    private func write(_ value: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--set-variables", KarabinerPanelSignal.payload(panelIsVisible: value)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Signalled from the process's own termination queue, so the wait ends the moment the
        // child exits instead of after a fixed sleep.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            reportFailureOnce("could not start karabiner_cli: \(error.localizedDescription)")
            return false
        }
        guard finished.wait(timeout: .now() + Self.writeTimeout) == .success else {
            process.terminate()
            // Deliberately not waited on again: `terminate` is a request (SIGTERM) that a
            // wedged child may ignore, and waiting for it here would put the unbounded wait
            // straight back.
            reportFailureOnce(
                "karabiner_cli did not exit within \(Self.writeTimeout)s on "
                    + KarabinerPanelSignal.payload(panelIsVisible: value)
            )
            return false
        }
        guard process.terminationStatus == 0 else {
            reportFailureOnce(
                "karabiner_cli exited \(process.terminationStatus) on "
                    + KarabinerPanelSignal.payload(panelIsVisible: value)
            )
            return false
        }
        return true
    }

    /// One line for the first failure, silence for the rest. A missing Karabiner is a state,
    /// not an event, and repeating it on every panel toggle would bury everything else.
    private func reportFailureOnce(_ reason: @autoclosure () -> String) {
        lock.lock()
        let alreadyReported = hasReportedFailure
        hasReportedFailure = true
        lock.unlock()
        guard !alreadyReported else { return }
        Diag.warning(.settings, "Karabiner panel signal not sent: \(reason())")
    }
}
