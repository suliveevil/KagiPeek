import AppKit
import Foundation
import os

/// The single entry point for diagnostics that are meant to outlive the process.
///
/// Two sinks, one call: the unified log keeps the developer's view (`log show`, Console.app)
/// and the file log keeps what a user can still attach to a bug report after the app died.
/// The level gate runs first and the message is an `@autoclosure`, so a debug line on the
/// key-press path costs one comparison when verbose logging is off.
///
/// Nothing here throws or propagates: a logger that can break the app it observes would be
/// worse than no logger. Every failure degrades to "the file simply stops receiving lines".
enum Diag {
    private static let lock = NSLock()
    private static var enabled = true
    private static var verbose = false
    private static var store: FileLogStore?

    /// Wires the switches and the sink. Called at launch and whenever settings change.
    static func configure(enabled: Bool, verbose: Bool, store: FileLogStore = .shared) {
        lock.lock()
        self.enabled = enabled
        self.verbose = verbose
        self.store = store
        lock.unlock()
    }

    static func applySettings(_ settings: AppSettingsSnapshot) {
        configure(enabled: settings.diagnosticsEnabled, verbose: settings.verboseDiagnostics)
    }

    static var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    static var isVerbose: Bool {
        lock.lock()
        defer { lock.unlock() }
        return verbose
    }

    // MARK: - Levels

    static func verbose(_ tag: DiagTag, _ message: @autoclosure () -> String) {
        write(.verbose, tag, message)
    }

    static func debug(_ tag: DiagTag, _ message: @autoclosure () -> String) {
        write(.debug, tag, message)
    }

    static func info(_ tag: DiagTag, _ message: @autoclosure () -> String) {
        write(.info, tag, message)
    }

    static func warning(_ tag: DiagTag, _ message: @autoclosure () -> String) {
        write(.warning, tag, message)
    }

    static func error(_ tag: DiagTag, _ message: @autoclosure () -> String) {
        write(.error, tag, message)
    }

    /// Records a user action for the crash report's "recent actions" list.
    ///
    /// Separate from the log on purpose: it is cheap, it survives a crash through a disk
    /// mirror, and it carries no content — only what the action was and which app it hit.
    static func action(_ name: String, target: String? = nil) {
        guard isEnabled else { return }
        ActionRecorder.shared.record(name, target: target)
    }

    // MARK: - Internals

    /// The gate lives here: the level filter is checked *before* `message` is evaluated, so a
    /// debug line costs one comparison when verbose logging is off — not a string build.
    private static func write(
        _ level: DiagLevel,
        _ tag: DiagTag,
        _ message: () -> String
    ) {
        lock.lock()
        let enabled = self.enabled
        let verbose = self.verbose
        let store = self.store
        lock.unlock()

        guard enabled else { return }
        guard LogLevelFilter.shouldLog(level: level, verboseEnabled: verbose) else { return }

        let text = message()
        mirror(level: level, tag: tag, text: text)
        store?.enqueue(level: level, tag: tag, message: text)
    }

    /// Keeps the unified log complete: the file sink can be switched off or trimmed by its
    /// size cap, while `log show` remains the full-resolution view during development.
    ///
    /// Deliberately *not* redacted: the unified log stays on this Mac, is readable only with
    /// admin rights, and its whole purpose is being searchable during development. The file
    /// sink — the thing that gets exported — is the one that goes through `Sanitizer`.
    private static func mirror(level: DiagLevel, tag: DiagTag, text: String) {
        let logger = logger(for: tag)
        let line = "\(tag.keyword) \(text)"
        switch level {
        case .verbose, .debug:
            logger.debug("\(line, privacy: .public)")
        case .info:
            logger.info("\(line, privacy: .public)")
        case .warning:
            logger.notice("\(line, privacy: .public)")
        case .error:
            logger.error("\(line, privacy: .public)")
        }
    }

    private static func logger(for tag: DiagTag) -> Logger {
        switch tag {
        case .scan:
            return AppLog.scan
        case .tap, .inject, .run:
            return AppLog.input
        case .settings:
            return AppLog.storage
        case .start, .perm, .net, .ui, .crash, .exit, .export:
            return AppLog.ui
        }
    }
}

/// Hardware and OS facts that belong in every crash report and every launch line.
enum DeviceInfo {
    /// The marketing-independent identifier, e.g. `Mac14,2`.
    static var modelIdentifier: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    static var macOSVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// One line that identifies the build and the machine, for `[start]` and `[crash]`.
    static var summary: String {
        "version=\(appVersion) build=\(appBuild) macOS=\(macOSVersion) model=\(modelIdentifier)"
    }
}
