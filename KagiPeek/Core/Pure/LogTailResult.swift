import Foundation

/// What the crash report's "log tail" step actually found.
///
/// It used to be `[String]`: a call site could not tell a day with no log file (normal — the
/// app may not have written anything yet) from a file that existed and could not be read
/// (the one case where the missing tail is itself evidence). Both looked like an empty array,
/// so a permission problem on the log folder silently removed the context from every crash
/// report written afterwards.
nonisolated enum LogTailResult: Equatable, Sendable {
    /// The day's file was read; `lines` is its last `count` lines, possibly empty.
    case lines([String])
    /// There is no file for that day. Normal, not an error.
    case missing
    /// The file exists (or should) but could not be turned into text.
    case unreadable(String)

    /// The lines to put in the report. Empty for both failure cases.
    var lines: [String] {
        if case let .lines(lines) = self { return lines }
        return []
    }

    /// Why the tail is absent, when that is a failure rather than an empty day.
    var error: String? {
        if case let .unreadable(reason) = self { return reason }
        return nil
    }
}
