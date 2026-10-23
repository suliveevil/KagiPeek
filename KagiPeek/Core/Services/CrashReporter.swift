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
/// * Fatal signal — the handler pre-opens a file descriptor and pre-serialises the context at
///   launch, then `write()`s a one-line fragment containing the signal and the time, and
///   re-raises. The system's own crash log supplies the stack; the next launch turns the
///   fragment into a complete report with the recent actions and the log tail.
///
/// The sentinel (`logs/session.active`) is what distinguishes "the app crashed" from "the
/// user force quit / the machine lost power": both leave no clean exit, but only the first
/// leaves a fragment, and the second is still worth one honest line in the log.
enum CrashReporter {
    // MARK: - Paths

    private static var crashDirectory: URL { DataDirectory.url(for: "crash") }
    private static var sentinelURL: URL { DataDirectory.url(for: "logs").appendingPathComponent("session.active") }

    private static let logs = FileLogStore.shared
    private static let actions = ActionRecorder.shared

    private static var startedAt = Date()

    // MARK: - Signal state (written at arming, read by the handler)

    private static var partialDescriptor: Int32 = -1
    private static var partialHandle: FileHandle?
    private static var partialURL: URL?
    private static var contextPointer: UnsafeMutablePointer<CChar>?
    private static var contextLength: Int = 0
    private static var digitsPointer = UnsafeMutablePointer<CChar>.allocate(capacity: 24)
    /// Pre-encoded `sig=N\ntime=` per handled signal, so the handler never has to format.
    ///
    /// Six separate values rather than a dictionary: a `Dictionary` lookup is not on the
    /// async-signal-safe list, and this is the one call in the handler a reviewer cannot
    /// prove safe. A `switch` over the signal constants can be.
    fileprivate typealias Preencoded = (pointer: UnsafeMutablePointer<CChar>?, length: Int)
    private static var abrtText: Preencoded = (nil, 0)
    private static var segvText: Preencoded = (nil, 0)
    private static var busText: Preencoded = (nil, 0)
    private static var illText: Preencoded = (nil, 0)
    private static var fpeText: Preencoded = (nil, 0)
    private static var trapText: Preencoded = (nil, 0)
    private static var fallbackText: Preencoded = (nil, 0)
    private static var newlinePointer: UnsafeMutablePointer<CChar>?
    /// Set once the NSException path has written its own report, so the SIGABRT that follows
    /// does not produce a second, emptier one.
    private static var exceptionHandled: Int32 = 0

    private static let reportedSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    // MARK: - Install

    /// Called first thing in `AppDelegate.init` — before the settings store touches disk,
    /// which is the earliest window in which the app can crash.
    static func install() {
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
    /// arms this session's sentinel and fragment.
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
        // Says out loud whether the next crash will leave anything behind — the one piece of
        // diagnostics state that is otherwise invisible.
        Diag.info(.crash, """
            crash reporter armed signals=\(reportedSignals.count) \
            fragment=\(partialDescriptor >= 0 ? "ready" : "unavailable")
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
        try? FileManager.default.createDirectory(
            at: sentinelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? content.write(to: sentinelURL, atomically: true, encoding: .utf8)
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
            isAppActive: NSApplication.shared.isActive,
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

    /// Pre-opens the fragment file and pre-serialises the context line.
    private static func prepareSignalFragment() {
        let name = "kagipeek-crash-\(timestampString(Date()))-signal.partial"
        let url = crashDirectory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        // A `FileHandle` is the reliable way to get a descriptor here: the C `open` imported
        // into Swift is variadic, and a wrong overload silently means "no file, no handler".
        guard let opened = try? FileHandle(forWritingTo: url) else {
            Diag.error(.crash, "could not arm the signal reporter (no descriptor for \(name))")
            return
        }
        partialHandle = opened
        partialDescriptor = opened.fileDescriptor
        partialURL = url

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
        if partialDescriptor >= 0 {
            // Closing through the handle keeps Swift's ownership rules satisfied; the raw
            // descriptor is only ever written from the signal handler.
            partialHandle?.closeFile()
            partialHandle = nil
            partialDescriptor = -1
        }
        if let partialURL {
            try? FileManager.default.removeItem(at: partialURL)
            CrashReporter.partialURL = nil
        }
    }

    // MARK: - Report files

    private static func write(_ report: CrashReport, kind: String) {
        let name = "kagipeek-crash-\(timestampString(Date()))-\(kind).json"
        let url = crashDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)
            try CrashLogFormatter.render(report).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Nothing left to fall back to at this point.
        }
    }

    /// Called at launch: turns every signal fragment left by a dead session into a full
    /// report, using the action mirror and the day's log tail.
    private static func completePartialReports() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: crashDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasSuffix(".partial") {
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  let info = CrashLogFormatter.parsePartial(raw) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let occurredAt = Date(timeIntervalSince1970: info.timestamp)
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
                recentActions: ActionRecorder.loadMirror(),
                callStack: nil
            )
            let report = CrashLogFormatter.makeReport(
                context: context,
                logTail: logs.tail(of: occurredAt, lines: 200)
            )
            let target = crashDirectory.appendingPathComponent(
                "kagipeek-crash-\(timestampString(occurredAt))-\(CrashLogFormatter.signalName(info.signalNumber)).json"
            )
            try? CrashLogFormatter.render(report).write(to: target, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
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

private func kagiUncaughtExceptionHandler(_ exception: NSException) {
    CrashReporter.handleException(exception)
}

// MARK: - Signal handler

/// Global, capture-free, and restricted to `write`/`time`/`close`/`signal`/`raise`.
///
/// Everything it needs was prepared before arming: the descriptor is open, the context string
/// is pre-formatted, each signal's prefix is pre-encoded, and the digit buffer is allocated.
/// The only value computed here is the timestamp.
private func crashSignalHandler(_ signalNumber: Int32) {
    let descriptor = CrashReporter.partialDescriptorForHandler
    if CrashReporter.exceptionHandledForHandler == 0, descriptor >= 0 {
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
        // A handler can be entered twice for the same signal; without this, the second entry
        // would close a descriptor number someone else may already own.
        CrashReporter.markDescriptorClosed()
    }
    // Default disposition, then re-raise: the system's own crash report is the one that
    // carries a symbolicated stack, and it only exists if the signal is left to kill us.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

/// Writes the whole buffer, retrying on a short write or an interrupt. A truncated fragment
/// would parse as damage and turn a real crash into "no crash report".
private func writeAll(_ descriptor: Int32, _ pointer: UnsafePointer<CChar>?, _ length: Int) {
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

private func writeEpochSeconds(_ descriptor: Int32) {
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

extension CrashReporter {
    // Exposed to the C-style handler above without making the rest of the state public.
    fileprivate static var exceptionHandledForHandler: Int32 { exceptionHandled }
    fileprivate static var partialDescriptorForHandler: Int32 { partialDescriptor }
    fileprivate static var contextPointerForHandler: UnsafeMutablePointer<CChar>? { contextPointer }
    fileprivate static var contextLengthForHandler: Int { contextLength }
    fileprivate static var digitsForHandler: UnsafeMutablePointer<CChar> { digitsPointer }
    fileprivate static var fallbackTextForHandler: Preencoded { fallbackText }
    fileprivate static var newlineForHandler: UnsafeMutablePointer<CChar>? { newlinePointer }

    fileprivate static func markDescriptorClosed() {
        partialDescriptor = -1
        partialHandle = nil
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
