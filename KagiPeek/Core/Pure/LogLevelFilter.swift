import Foundation

/// The level gate for the file log.
///
/// The file log defaults to info-and-above: high-frequency success paths (scan results,
/// row runs) log at debug and stay out of the file unless the user turns verbose logging
/// on. Failures are always `I/W/E` and never depend on any switch — a log that goes quiet
/// exactly when things break would be worse than no log.
enum LogLevelFilter {
    static func shouldLog(level: DiagLevel, verboseEnabled: Bool) -> Bool {
        switch level {
        case .error, .warning, .info:
            return true
        case .debug, .verbose:
            return verboseEnabled
        }
    }
}
