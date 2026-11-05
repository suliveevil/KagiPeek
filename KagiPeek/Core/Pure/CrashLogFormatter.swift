import Foundation

/// Everything a crash report knows, gathered at the moment of the crash (or, for signals,
/// reconstructed at the next launch — a signal handler may only `write()`).
nonisolated struct CrashContext {
    /// "nsexception" or "signal".
    var kind: String
    var exceptionName: String?
    var exceptionReason: String?
    var signalNumber: Int32?
    var occurredAt: Date
    var appVersion: String
    var appBuild: String
    var macOSVersion: String
    var modelIdentifier: String
    var isAppActive: Bool
    var recentActions: [ActionRecord]
    /// Why `recentActions` is empty when that is a failure rather than a clean session.
    /// The signal path reads the on-disk mirror at the next launch; that read can fail.
    var recentActionsError: String? = nil
    /// Symbolicated frames, available only on the NSException path.
    var callStack: [String]?
}

/// The durable JSON crash report.
nonisolated struct CrashReport: Codable, Equatable {
    /// Report layout version, so a reader can refuse what it cannot parse.
    static let currentFormat = 1

    var format: Int
    var kind: String
    var exceptionName: String?
    var exceptionReason: String?
    var signalNumber: Int32?
    var signalName: String?
    /// Seconds since 1970, UTC.
    var occurredAt: TimeInterval
    var appVersion: String
    var appBuild: String
    var macOSVersion: String
    var modelIdentifier: String
    var isAppActive: Bool
    var recentActions: [ActionRecord]
    /// Why `recentActions` is empty or partial. Absent when nothing went wrong.
    var recentActionsError: String?
    var callStack: [String]?
    /// The tail of the day's log file, added when the report is completed at the next
    /// launch (the dying process could not have read its own log).
    var logTail: [String]?
    /// Why `logTail` is empty when the file existed but could not be read. Absent when the
    /// day simply had no log file.
    var logTailError: String?
}

/// Assembles and renders crash reports; parses the minimal `.partial` fragment the signal
/// handler was able to `write()`.
nonisolated enum CrashLogFormatter {
    /// Signal names for the set CrashReporter installs handlers for. Nonisolated so the
    /// report builder can run outside the main actor.
    nonisolated static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(signal)"
        }
    }

    static func makeReport(
        context: CrashContext,
        logTail: [String]? = nil,
        logTailError: String? = nil
    ) -> CrashReport {
        CrashReport(
            format: CrashReport.currentFormat,
            kind: context.kind,
            exceptionName: context.exceptionName,
            exceptionReason: context.exceptionReason,
            signalNumber: context.signalNumber,
            signalName: context.signalNumber.map(signalName),
            occurredAt: context.occurredAt.timeIntervalSince1970,
            appVersion: context.appVersion,
            appBuild: context.appBuild,
            macOSVersion: context.macOSVersion,
            modelIdentifier: context.modelIdentifier,
            isAppActive: context.isAppActive,
            recentActions: context.recentActions,
            recentActionsError: context.recentActionsError,
            callStack: context.callStack,
            logTail: logTail,
            logTailError: logTailError
        )
    }

    /// Pretty-printed JSON, sorted keys, ISO dates — stable output for diffs and for the
    /// user attaching the file to a bug report.
    static func render(_ report: CrashReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Dates are stored as epoch seconds (`occurredAt: TimeInterval`), so no date strategy
        // is involved — a reader never has to guess a format.
        do {
            let data = try encoder.encode(report)
            guard let text = String(data: data, encoding: .utf8) else {
                return unrenderable("the encoded report was not valid UTF-8")
            }
            return text
        } catch {
            return unrenderable(error.localizedDescription)
        }
    }

    /// Valid JSON that says why the report is missing.
    ///
    /// The previous fallback was `{}`, which parses, looks intact, and means nothing: a reader
    /// concludes the crash simply carried no information, when the truth is that this app
    /// failed to write down what it knew. The only file a crash leaves behind should not be
    /// able to lie by omission.
    private static func unrenderable(_ reason: String) -> String {
        let payload = ["error": "the crash report could not be serialised: \(reason)"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"the crash report could not be serialised\"}"
        }
        return text
    }

    // MARK: - Minimal signal fragment

    /// The fields the signal handler managed to `write()`: the pre-serialised context
    /// line plus `sig=` and `time=`. No heap, no Foundation — which is why the parse
    /// happens here, at the next launch, instead of at the crash.
    struct PartialCrashInfo: Equatable {
        var appVersion: String
        var appBuild: String
        var macOSVersion: String
        var modelIdentifier: String
        var pid: Int32
        var signalNumber: Int32
        var timestamp: TimeInterval
    }

    /// Parses the one-key-per-line fragment the signal handler wrote. Line-based because a
    /// value (`os=Version 15.1 (Build 24B83)`) may contain spaces.
    /// Returns nil when the fragment is too damaged to trust.
    static func parsePartial(_ raw: String) -> PartialCrashInfo? {
        var values: [String: String] = [:]
        for line in raw.split(whereSeparator: { $0 == "\n" }) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        guard let version = values["ver"],
              let os = values["os"],
              let model = values["model"],
              let pid = values["pid"], let pidValue = Int32(pid),
              let sig = values["sig"], let sigValue = Int32(sig),
              let time = values["time"], let timeValue = Double(time) else { return nil }
        return PartialCrashInfo(
            appVersion: version,
            appBuild: values["build"] ?? "",
            macOSVersion: os,
            modelIdentifier: model,
            pid: pidValue,
            signalNumber: sigValue,
            timestamp: timeValue
        )
    }
}
