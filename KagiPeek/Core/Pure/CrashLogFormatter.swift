import Foundation

/// Everything a crash report knows, gathered at the moment of the crash (or, for signals,
/// reconstructed at the next launch — a signal handler may only `write()`).
struct CrashContext {
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
    /// Symbolicated frames, available only on the NSException path.
    var callStack: [String]?
}

/// The durable JSON crash report.
struct CrashReport: Codable, Equatable {
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
    var callStack: [String]?
    /// The tail of the day's log file, added when the report is completed at the next
    /// launch (the dying process could not have read its own log).
    var logTail: [String]?
}

/// Assembles and renders crash reports; parses the minimal `.partial` fragment the signal
/// handler was able to `write()`.
enum CrashLogFormatter {
    /// Signal names for the set CrashReporter installs handlers for.
    static func signalName(_ signal: Int32) -> String {
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

    static func makeReport(context: CrashContext, logTail: [String]? = nil) -> CrashReport {
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
            callStack: context.callStack,
            logTail: logTail
        )
    }

    /// Pretty-printed JSON, sorted keys, ISO dates — stable output for diffs and for the
    /// user attaching the file to a bug report.
    static func render(_ report: CrashReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Dates are stored as epoch seconds (`occurredAt: TimeInterval`), so no date strategy
        // is involved — a reader never has to guess a format.
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8) else {
            // A crash report that cannot be serialised is still worth a line on stdout-adjacent
            // channels; but this struct is fully Codable with value types, so the path is dead.
            return "{}"
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
