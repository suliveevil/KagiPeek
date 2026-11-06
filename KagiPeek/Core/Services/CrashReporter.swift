import AppKit
import Foundation

/// Captures the two ways this process can die without a chance to clean up, and turns both
/// into a JSON report the user can hand over.
///
/// The design follows the constraint that shapes every crash reporter: a signal handler may
/// only call async-signal-safe C functions. So the two paths are deliberately different.
///
/// * NSException — the handler runs before teardown, with a live runtime. It writes the full
///   report itself: name, reason, call stack, recent actions.
/// * Fatal signal — the handler pre-computes the file path and pre-serialises the context at
///   launch, then `open`s the fragment only when the signal actually fires, `write()`s a
///   one-line fragment containing the signal and the time, and re-raises. The system's own
///   crash log supplies the stack; the next launch turns the fragment into a complete report
///   with the recent actions and the log tail.
///
/// The sentinel (`logs/session.active`) is what distinguishes "the app crashed" from "the
/// user force quit / the machine lost power": both leave no clean exit, but only the first
/// leaves a fragment, and the second is still worth one honest line in the log.
/// `nonisolated` is not a convenience here, it is the model. Every entry point can be
/// reached from a thread other than main: `install`/`beginSession` at launch, `markCleanExit`
/// on termination, `handleException` from the NSException handler, and the six signal
/// handlers from whatever thread took the fault. Under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unmarked enum would imply the opposite,
/// and the C function pointers below could not even be formed.
///
/// The signal state is `nonisolated(unsafe)` for the same reason the file header states:
/// a POSIX signal handler may only call async-signal-safe C functions. It cannot take a
/// lock, hop to an actor, or allocate. These values are written once while arming (before
/// any handler can fire) and then only read, which is the invariant — no lock can enforce
/// it from inside a handler, so the type system is told the truth instead of being handed
/// a false guarantee. Swift 5 merely never checked; Swift 6 does.
nonisolated enum CrashReporter {
    // MARK: - Paths

    private static var crashDirectory: URL { DataDirectory.url(for: "crash") }
    private static var sentinelURL: URL { DataDirectory.url(for: "logs").appendingPathComponent("session.active") }

    private static let logs = FileLogStore.shared
    private static let actions = ActionRecorder.shared

    /// Written once by the launch-time sweep and read later by the diagnostics report, which
    /// can be produced on a background queue. The lock is the honest spelling of that access:
    /// the value is small and read rarely, and a torn read would be a wrong report.
    ///
    /// The guarded blocks go through `withLock`, the same idiom as `KeyboardMonitor` and
    /// `Diag.State`: the lock is never spelled at a call site, so there is no pair to leave
    /// half-finished.
    private final class RecoveryState: @unchecked Sendable {
        private let lock = NSLock()
        var status = CrashRecoveryStatus()

        func withLock<T>(_ body: (RecoveryState) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }
    private static let recoveryState = RecoveryState()

    /// What the last launch-time fragment sweep could not complete. Empty when nothing was
    /// left behind, or when everything left behind became a report.
    static var recoveryStatus: CrashRecoveryStatus {
        recoveryState.withLock { $0.status }
    }

    private static func publish(_ status: CrashRecoveryStatus) {
        recoveryState.withLock { $0.status = status }
    }

    /// "Was the app frontmost when it died" is a best-effort diagnostic, and AppKit's
    /// `isActive` is main-actor-isolated — a crash handler cannot read it. Rather than
    /// asserting main-actor isolation from a thread that may not be main, the reader is
    /// installed once from the main actor at launch and only *called* from the crash path.
    /// `nonisolated(unsafe)` is the honest spelling: the value is a hint in a report, never
    /// a correctness dependency, and no lock can make an AppKit query async-signal-safe.
    private nonisolated(unsafe) static var appActiveReader: () -> Bool = { false }

    /// Written once at launch, read at clean exit and by the exception path. Both are
    /// `nonisolated` methods, so this is a shared mutable global under Swift 6; the
    /// `nonisolated(unsafe)` says the write happens before any reader can exist, exactly
    /// the arming invariant the signal state below relies on.
    private nonisolated(unsafe) static var startedAt = Date()

    // MARK: - Signal state (written at arming, read by the handler)

    private nonisolated(unsafe) static var partialPathPointer: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var partialURL: URL?
    private nonisolated(unsafe) static var contextPointer: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var contextLength: Int = 0
    private nonisolated(unsafe) static var digitsPointer = UnsafeMutablePointer<CChar>.allocate(capacity: 24)
    /// Set once the signal handler has opened the fragment for this crash. A second entry
    /// for the same signal must not truncate the first fragment.
    private nonisolated(unsafe) static var fragmentWritten: Int32 = 0
    /// Pre-encoded `sig=N\ntime=` per handled signal, so the handler never has to format.
    ///
    /// Six separate values rather than a dictionary: a `Dictionary` lookup is not on the
    /// async-signal-safe list, and this is the one call in the handler a reviewer cannot
    /// prove safe. A `switch` over the signal constants can be.
    fileprivate typealias Preencoded = (pointer: UnsafeMutablePointer<CChar>?, length: Int)
    private nonisolated(unsafe) static var abrtText: Preencoded = (nil, 0)
    private nonisolated(unsafe) static var segvText: Preencoded = (nil, 0)
    private nonisolated(unsafe) static var busText: Preencoded = (nil, 0)
    private nonisolated(unsafe) static var illText: Preencoded = (nil, 0)
    private nonisolated(unsafe) static var fpeText: Preencoded = (nil, 0)
    private nonisolated(unsafe) static var trapText: Preencoded = (nil, 0)
    private nonisolated(unsafe) static var fallbackText: Preencoded = (nil, 0)
    private nonisolated(unsafe) static var newlinePointer: UnsafeMutablePointer<CChar>?
    /// Set once the NSException path has written its own report, so the SIGABRT that follows
    /// does not produce a second, emptier one.
    private nonisolated(unsafe) static var exceptionHandled: Int32 = 0

    private static let reportedSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    // MARK: - Install

    /// Called first thing in `AppDelegate.init` — before the settings store touches disk,
    /// which is the earliest window in which the app can crash.
    ///
    /// `@MainActor` for exactly one line: installing the AppKit reader. Everything else here
    /// is deliberately nonisolated, because the handlers it arms run on arbitrary threads.
    @MainActor
    static func install() {
        appActiveReader = { NSApplication.shared.isActive }
        DataDirectory.ensureExists()
        try? FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)

        prepareSignalTexts()
        for signalNumber in reportedSignals {
            signal(signalNumber, crashSignalHandler)
        }
        NSSetUncaughtExceptionHandler(kagiUncaughtExceptionHandler)
    }

    // MARK: - Session lifecycle

    /// Called right after `install()`. Reports what the previous session left behind, then
    /// arms this session's sentinel and fragment path.
    ///
    /// Order matters twice over:
    /// * the sweep for last session's fragments must run *before* today's fragment exists,
    ///   or the sweep finds an empty file, fails to parse it and deletes the very file the
    ///   handler is about to write to;
    /// * the sentinel goes down before the fragment, because a crash in between then still
    ///   lands in the "unexpected exit, no report" branch instead of vanishing silently.
    static func beginSession() {
        startedAt = Date()
        completePartialReports()
        reportPreviousSessionIfNeeded()
        writeSentinel()
        prepareSignalFragment()
        pruneCrashReports()
        // Says out loud whether the next crash will leave anything behind — the one piece of
        // diagnostics state that is otherwise invisible.
        Diag.info(.crash, """
            crash reporter armed signals=\(reportedSignals.count) \
            fragment=\(partialPathPointer != nil ? "armed" : "unavailable")
            """)
    }

    /// Called before any flush on a clean termination: deleting the sentinel is idempotent
    /// and cannot fail in a way that matters, so it goes first.
    static func markCleanExit() {
        let sentinelExists = FileManager.default.fileExists(atPath: sentinelURL.path)
        if SentinelState.terminateDecision(sentinelExists: sentinelExists) == .remove {
            try? FileManager.default.removeItem(at: sentinelURL)
        }
        cleanupPartial()
        actions.clear()
        let uptime = Int(Date().timeIntervalSince(startedAt))
        Diag.info(.exit, "clean exit uptime=\(uptime)s")
        logs.flushNow()
    }

    // MARK: - Launch-side reporting

    private static func writeSentinel() {
        let content = "pid=\(ProcessInfo.processInfo.processIdentifier) started=\(ISO8601DateFormatter().string(from: Date()))\n"
        do {
            try FileManager.default.createDirectory(
                at: sentinelURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: sentinelURL, atomically: true, encoding: .utf8)
        } catch {
            // Without the sentinel the next launch cannot tell a crash from a clean quit, so
            // this is not housekeeping: it is the whole detection mechanism. A line in the log
            // is the only thing that makes a silent gap explainable later.
            Diag.warning(.crash, "could not write the launch sentinel (\(error.localizedDescription)): an unclean exit will go unreported")
        }
    }

    /// Turns the previous session's sentinel into an honest log line. A crash and a force
    /// quit both leave the sentinel; only one of them leaves a report, and the log says which.
    private static func reportPreviousSessionIfNeeded() {
        let sentinelExists = FileManager.default.fileExists(atPath: sentinelURL.path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: sentinelURL.path)
        let sentinelDate = attributes?[.modificationDate] as? Date
        let report = sentinelExists ? latestCrashReport(after: sentinelDate) : nil

        switch SentinelState.launchDecision(
            sentinelExists: sentinelExists,
            crashPartialExists: report != nil
        ) {
        case .clean:
            return
        case .write, .remove:
            return
        case .reportUnexpectedExit(let partial):
            if partial, let report {
                Diag.warning(.exit, "previous session ended unexpectedly (crash report: \(report))")
            } else {
                Diag.warning(.exit, "previous session ended unexpectedly (no crash report: killed, force quit or power loss)")
            }
        }
        try? FileManager.default.removeItem(at: sentinelURL)
    }

    private static func latestCrashReport(after date: Date?) -> String? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: crashDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let reports = contents.filter { $0.lastPathComponent.hasSuffix(".json") }.compactMap { url -> (URL, Date)? in
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                return nil
            }
            if let date, modified < date { return nil }
            return (url, modified)
        }
        return reports.max { $0.1 < $1.1 }?.0.lastPathComponent
    }

    // MARK: - Exception path

    /// Called from the C-style handler below. `fileprivate` because a top-level function
    /// cannot see a type's `private` members, and the handler itself cannot be a closure:
    /// `NSSetUncaughtExceptionHandler` only accepts a capture-free C function pointer.
    fileprivate static func handleException(_ exception: NSException) {
        exceptionHandled = 1
        // `reason` is a formatted string, and a third-party assertion can put anything in it
        // — including the user data that caused it. The report leaves the machine, so it goes
        // through the same redaction as every log line.
        let reason = exception.reason.map { Sanitizer.prepare($0, homePrefix: NSHomeDirectory()) }
        let context = CrashContext(
            kind: "nsexception",
            exceptionName: exception.name.rawValue,
            exceptionReason: reason,
            signalNumber: nil,
            occurredAt: Date(),
            appVersion: appVersion,
            appBuild: appBuild,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            modelIdentifier: DeviceInfo.modelIdentifier,
            isAppActive: appActiveReader(),
            recentActions: actions.snapshot(),
            callStack: exception.callStackSymbols
        )
        let report = CrashLogFormatter.makeReport(context: context)
        write(report, kind: "exception")
        // The log buffer still lives in this process: give it a moment to reach disk.
        logs.flushNow(timeout: 0.3)
        cleanupPartial()
    }

    // MARK: - Signal path

    /// Pre-encodes everything the handler is allowed to write. Allocation, Foundation and
    /// locks are all off-limits after this point.
    private static func prepareSignalTexts() {
        fallbackText = allocateText("sig=?\ntime=")
        abrtText = allocateText("sig=\(SIGABRT)\ntime=")
        segvText = allocateText("sig=\(SIGSEGV)\ntime=")
        busText = allocateText("sig=\(SIGBUS)\ntime=")
        illText = allocateText("sig=\(SIGILL)\ntime=")
        fpeText = allocateText("sig=\(SIGFPE)\ntime=")
        trapText = allocateText("sig=\(SIGTRAP)\ntime=")
        newlinePointer = allocateBuffer("\n")
    }

    private static func allocateText(_ text: String) -> Preencoded {
        guard let buffer = allocateBuffer(text) else { return (nil, 0) }
        return (buffer, text.utf8.count)
    }

    private static func allocateBuffer(_ text: String) -> UnsafeMutablePointer<CChar>? {
        let utf8 = Array(text.utf8)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
        buffer.initialize(from: utf8.map { CChar(bitPattern: $0) }, count: utf8.count)
        return buffer
    }

    /// Pre-computes the fragment path and pre-serialises the context line.
    ///
    /// The file itself is created by the signal handler, not here: a session that exits
    /// cleanly must leave no `*.partial` behind, because a zero-byte file named like crash
    /// evidence is indistinguishable from a crash that failed to write.
    private static func prepareSignalFragment() {
        let name = "kaname-crash-\(timestampString(Date()))-signal.partial"
        let url = crashDirectory.appendingPathComponent(name)
        let path = Array(url.path.utf8)
        let pathPointer = UnsafeMutablePointer<CChar>.allocate(capacity: path.count + 1)
        url.path.withCString { source in
            pathPointer.initialize(from: source, count: path.count + 1)
        }
        partialPathPointer = pathPointer
        partialURL = url
        fragmentWritten = 0

        // One key per line: the OS version string contains spaces and parentheses, so a
        // space-separated format would parse back as the first word only.
        let context = """
            ver=\(appVersion)
            build=\(appBuild)
            os=\(ProcessInfo.processInfo.operatingSystemVersionString)
            model=\(DeviceInfo.modelIdentifier)
            pid=\(ProcessInfo.processInfo.processIdentifier)

            """
        let length = context.utf8.count
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: length + 1)
        context.withCString { source in
            pointer.initialize(from: source, count: length + 1)
        }
        contextPointer = pointer
        contextLength = length
    }

    private static func cleanupPartial() {
        if let partialURL {
            try? FileManager.default.removeItem(at: partialURL)
            CrashReporter.partialURL = nil
        }
        // The path buffer is deliberately not deallocated: the signal handler can fire on
        // another thread until the process actually exits, and a small one-time allocation
        // is cheaper than reasoning about that race.
    }

    // MARK: - Report files

    private static func write(_ report: CrashReport, kind: String) {
        let name = "kaname-crash-\(timestampString(Date()))-\(kind).json"
        let url = crashDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)
            try CrashLogFormatter.render(report).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // This runs inside the uncaught-exception handler, which is why it looked like there
            // was nothing left to fall back to. There is: `handleException` flushes the log
            // buffer immediately after this call, so a line written here does reach disk.
            // Without it the app swallows the exception *and* the record of having swallowed it,
            // and the next launch reports a crash that left no evidence at all.
            Diag.warning(
                .crash,
                "could not write the crash report to \(url.lastPathComponent) (\(error.localizedDescription))"
            )
        }
    }

    // MARK: - Retention

    /// Deletes the crash reports `ArtifactRetentionPolicy.crashReports` names.
    ///
    /// Runs once per launch, at the end of `beginSession` — after the fragment sweep, so a
    /// launch that recovers twenty fragments does not leave the folder at twenty-one, and
    /// before anything reads the folder again. The only file that must never be touched is
    /// this session's own evidence: none exists yet (a clean session writes no `.partial`),
    /// and the policy would not name a `.partial` even if one did.
    ///
    /// A failed delete is housekeeping, not a launch failure: the file simply survives until
    /// the next launch can try again. It still gets a line, because "the folder did not
    /// shrink" is otherwise indistinguishable from "retention is not running".
    private static func pruneCrashReports() {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: crashDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        } catch {
            // `completePartialReports` already warned that the folder cannot be listed; a
            // second warning would repeat it. Debug keeps the two failures distinguishable.
            Diag.debug(.crash, "could not list the crash folder for retention: \(error.localizedDescription)")
            return
        }
        let candidates: [RetentionCandidate] = contents.compactMap { url in
            let name = url.lastPathComponent
            let isPartial = name.hasSuffix(".partial")
            guard isPartial || name.hasSuffix(".json") else { return nil }
            // An unreadable date means "we do not know how old this is", which is not the same
            // as "it is ancient". Leaving it out keeps the policy from deleting evidence it
            // cannot date.
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return nil }
            return RetentionCandidate(name: name, modifiedAt: modified, isPartial: isPartial)
        }
        let doomed = ArtifactRetentionPolicy.crashReports.artifactsToDelete(entries: candidates)
        for artifact in doomed {
            do {
                try FileManager.default.removeItem(at: crashDirectory.appendingPathComponent(artifact.name))
            } catch {
                Diag.warning(.crash, """
                    could not delete the old crash report \(artifact.name) \
                    (\(error.localizedDescription)); it stays until retention can remove it
                    """)
            }
        }
        if !doomed.isEmpty {
            Diag.debug(.crash, "retention removed \(doomed.count) of \(candidates.count) crash reports")
        }
    }

    /// Called at launch: turns every signal fragment left by a dead session into a full
    /// report, using the action mirror and the day's log tail.
    ///
    /// Three outcomes are deliberately different, because they call for different actions:
    /// * an unreadable fragment is **kept** — permissions or an I/O error can be temporary,
    ///   and the fragment is the only record of that crash;
    /// * a fragment that parses but cannot become a report is **kept** and retried next
    ///   launch, for the same reason;
    /// * a fragment that does not contain the fields the formatter needs is unparseable by
    ///   construction and is deleted, but with a debug line rather than as a side effect.
    private static func completePartialReports() {
        var status = CrashRecoveryStatus()
        defer { publish(status) }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: crashDirectory,
                includingPropertiesForKeys: nil
            )
        } catch {
            status.folderError = error.localizedDescription
            Diag.warning(.crash, """
                could not list the crash folder, so any fragment in it stays unprocessed: \
                \(error.localizedDescription)
                """)
            return
        }

        for url in contents where url.lastPathComponent.hasSuffix(".partial") {
            let name = url.lastPathComponent
            let raw: String
            do {
                raw = try String(contentsOf: url, encoding: .utf8)
            } catch {
                status.unreadable.append(.init(name: name, detail: error.localizedDescription))
                Diag.warning(.crash, """
                    could not read crash fragment \(name), keeping it for the next launch: \
                    \(error.localizedDescription)
                    """)
                continue
            }
            guard let info = CrashLogFormatter.parsePartial(raw) else {
                // Unlike a read failure, this file cannot become a report no matter how many
                // times it is retried. Deleting it is the right call; doing so without a trace
                // was not.
                status.discarded.append(.init(name: name, detail: "the fragment did not contain the expected fields"))
                Diag.debug(.crash, "discarding unparseable crash fragment \(name)")
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let occurredAt = Date(timeIntervalSince1970: info.timestamp)
            let mirror = ActionRecorder.loadMirror()
            let context = CrashContext(
                kind: "signal",
                exceptionName: nil,
                exceptionReason: nil,
                signalNumber: info.signalNumber,
                occurredAt: occurredAt,
                appVersion: info.appVersion,
                appBuild: info.appBuild,
                macOSVersion: info.macOSVersion,
                modelIdentifier: info.modelIdentifier,
                isAppActive: false,
                recentActions: mirror.records,
                recentActionsError: mirror.error
            )
            let tail = logs.tail(of: occurredAt, lines: 200)
            let report = CrashLogFormatter.makeReport(
                context: context,
                logTail: tail.lines,
                logTailError: tail.error
            )
            let target = crashDirectory.appendingPathComponent(
                "kaname-crash-\(timestampString(occurredAt))-\(CrashLogFormatter.signalName(info.signalNumber)).json"
            )
            do {
                try CrashLogFormatter.render(report).write(to: target, atomically: true, encoding: .utf8)
            } catch {
                // The report was assembled and then thrown away: the one failure this feature
                // exists to avoid. Keep the fragment so the next launch can try again, and say
                // so, because the alternative is a user reporting a crash to a log that insists
                // nothing happened.
                status.failedToComplete.append(.init(
                    name: name,
                    detail: "the completed report could not be written: \(error.localizedDescription)"
                ))
                Diag.warning(.crash, """
                    could not write the crash report to \(target.lastPathComponent) \
                    (\(error.localizedDescription)); keeping \(name) for the next launch
                    """)
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // The report exists now, but the fragment does too: the next launch would
                // produce a duplicate. Record it rather than leaving the folder to grow one
                // copy per launch.
                status.failedToComplete.append(.init(
                    name: name,
                    detail: "the completed report was written but the fragment could not be removed: \(error.localizedDescription)"
                ))
                Diag.warning(.crash, """
                    wrote \(target.lastPathComponent) but could not remove \(name): \
                    \(error.localizedDescription)
                    """)
            }
        }
    }

    // MARK: - Helpers

    private static var appVersion: String {
        Bundle.main.kagiPeekVersionDisplay
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

// MARK: - Exception handler

nonisolated private func kagiUncaughtExceptionHandler(_ exception: NSException) {
    CrashReporter.handleException(exception)
}

// MARK: - Signal handler

/// Global, capture-free, and restricted to `open`/`write`/`time`/`close`/`signal`/`raise`.
///
/// Everything it needs was prepared before arming: the path is pre-encoded, the context string
/// is pre-formatted, each signal's prefix is pre-encoded, and the digit buffer is allocated.
/// The only values computed here are the descriptor and the timestamp. `open` is on the
/// POSIX async-signal-safe list, which is why the file can be created here instead of at
/// launch — a clean session leaves no empty `*.partial` behind.
nonisolated private func crashSignalHandler(_ signalNumber: Int32) {
    if CrashReporter.exceptionHandledForHandler == 0,
       CrashReporter.fragmentWrittenForHandler == 0,
       let path = CrashReporter.partialPathForHandler {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if descriptor >= 0 {
            CrashReporter.markFragmentWritten()
            writeAll(descriptor, CrashReporter.contextPointerForHandler, CrashReporter.contextLengthForHandler)
            let text = CrashReporter.signalTextForHandler(signalNumber)
            if let pointer = text.pointer {
                writeAll(descriptor, pointer, text.length)
            } else {
                let fallback = CrashReporter.fallbackTextForHandler
                writeAll(descriptor, fallback.pointer, fallback.length)
            }
            writeEpochSeconds(descriptor)
            writeAll(descriptor, CrashReporter.newlineForHandler, 1)
            close(descriptor)
        }
    }
    // Default disposition, then re-raise: the system's own crash report is the one that
    // carries a symbolicated stack, and it only exists if the signal is left to kill us.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

/// Writes the whole buffer, retrying on a short write or an interrupt. A truncated fragment
/// would parse as damage and turn a real crash into "no crash report".
nonisolated private func writeAll(_ descriptor: Int32, _ pointer: UnsafePointer<CChar>?, _ length: Int) {
    guard let pointer, length > 0 else { return }
    var offset = 0
    while offset < length {
        let written = write(descriptor, pointer + offset, length - offset)
        if written > 0 {
            offset += written
        } else if written < 0, errno == EINTR {
            continue
        } else {
            return
        }
    }
}

nonisolated private func writeEpochSeconds(_ descriptor: Int32) {
    let buffer = CrashReporter.digitsForHandler
    var value = Int(time(nil))
    var index = 24
    if value <= 0 {
        buffer[23] = CChar(48)
        writeAll(descriptor, buffer + 23, 1)
        return
    }
    while value > 0, index > 0 {
        index -= 1
        buffer[index] = CChar(48 + Int(value % 10))
        value /= 10
    }
    writeAll(descriptor, buffer + index, 24 - index)
}

nonisolated extension CrashReporter {
    // Exposed to the C-style handler above without making the rest of the state public.
    fileprivate static var exceptionHandledForHandler: Int32 { exceptionHandled }
    fileprivate static var fragmentWrittenForHandler: Int32 { fragmentWritten }
    fileprivate static var partialPathForHandler: UnsafeMutablePointer<CChar>? { partialPathPointer }
    fileprivate static var contextPointerForHandler: UnsafeMutablePointer<CChar>? { contextPointer }
    fileprivate static var contextLengthForHandler: Int { contextLength }
    fileprivate static var digitsForHandler: UnsafeMutablePointer<CChar> { digitsPointer }
    fileprivate static var fallbackTextForHandler: Preencoded { fallbackText }
    fileprivate static var newlineForHandler: UnsafeMutablePointer<CChar>? { newlinePointer }

    fileprivate static func markFragmentWritten() {
        fragmentWritten = 1
    }

    /// A `switch` over the six handled signals: no dictionary, no array search, no closure —
    /// nothing a POSIX signal handler cannot prove.
    fileprivate static func signalTextForHandler(_ number: Int32) -> Preencoded {
        switch number {
        case SIGABRT: return abrtText
        case SIGSEGV: return segvText
        case SIGBUS: return busText
        case SIGILL: return illText
        case SIGFPE: return fpeText
        case SIGTRAP: return trapText
        default: return (nil, 0)
        }
    }
}
