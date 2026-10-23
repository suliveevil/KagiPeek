import Foundation
import os

/// Categorised logging.
///
/// Everything in this app used to fail silently: a settings write, a failed scan and a
/// dropped keystroke all looked the same from the outside — "it stopped working". These
/// loggers give each of those paths a place to speak, so a user can run
///
///     log show --last 10m --predicate 'subsystem == "com.voltline.kagipeek"'
///
/// and a bug report can carry the answer instead of a guess.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.voltline.kagipeek"

    /// Menu scanning: which app, how many items, why a catalog was empty or dropped.
    static let scan = Logger(subsystem: subsystem, category: "scan")
    /// Event tap, swallowing decisions, key injection.
    static let input = Logger(subsystem: subsystem, category: "input")
    /// Reads and writes of settings.json / usage.json.
    static let storage = Logger(subsystem: subsystem, category: "storage")
    /// Windows, permissions, update checks.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
