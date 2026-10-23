import Foundation

/// Diagnostic log levels, ordered from most verbose to most severe.
enum DiagLevel: Int, CaseIterable, Comparable, Sendable {
    case verbose = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4

    /// Single-character spelling in the log line: `2026-10-23 14:15:22.123 I [tap] …`.
    var character: String {
        switch self {
        case .verbose: return "V"
        case .debug: return "D"
        case .info: return "I"
        case .warning: return "W"
        case .error: return "E"
        }
    }

    static func < (lhs: DiagLevel, rhs: DiagLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The grep keyword every file log line carries. The raw value *is* the keyword, so
/// `[tap]`-style searches line up with `DiagTag.tap` without a mapping table.
enum DiagTag: String, CaseIterable, Sendable {
    case start
    case perm
    case tap
    case scan
    case inject
    case net
    case run
    case settings
    case ui
    case crash
    case exit
    case export

    /// The bracketed keyword as it appears in a log line: `[tap]`.
    var keyword: String { "[\(rawValue)]" }
}

/// One entry of the "recent user actions" ring buffer that crash reports include.
///
/// Only what the action *was* and which app it was aimed at — never menu item content,
/// typed characters or filter text. Those are the user's, not the log's.
struct ActionRecord: Codable, Equatable, Sendable {
    /// Seconds since 1970. A number rather than a `Date` so the same value means the same
    /// thing in the on-disk mirror, in the crash report and in a grep.
    var ts: TimeInterval
    var action: String
    /// Bundle identifier of the target app, nil for app-global actions.
    var target: String?
}
