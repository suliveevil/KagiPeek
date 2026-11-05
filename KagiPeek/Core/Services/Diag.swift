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
///
/// **One façade.** There used to be a second one (`AppLog`) with raw `os.Logger`s, and 43 call
/// sites wrote straight to it — lines that looked identical at the call site but never reached
/// the file, which is why a "the keyboard froze and the log says nothing" report could be true
/// and useless at the same time. Every line now goes through `Diag`, and the four `Logger`s
/// below are the private detail of the mirror:
///
///     log show --last 10m --predicate 'subsystem == "com.voltline.kagipeek"'
nonisolated enum Diag {
    /// The three switches behind one lock, in a `static let` box.
    ///
    /// Under Swift 6 a `static var` on a `nonisolated` type is global mutable state and is
    /// rejected outright — even when a lock makes it correct. The box turns three mutable
    /// globals into one immutable reference to a value that owns its own lock, so the type
    /// system can see the safety instead of being told to ignore it. `Diag` must stay
    /// `nonisolated`: the event-tap thread logs from its callback, and a main-actor hop
    /// there is precisely what the dedicated tap thread was created to avoid.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        var enabled = true
        var verbose = false
        var store: FileLogStore?

        /// The one idiom for shared state in this program, the same shape as
        /// `KeyboardMonitor.withLock` and `CrashReporter.RecoveryState.withLock`: no caller
        /// spells `lock()`/`unlock()`, so no caller can miss one. Three spellings of the same
        /// invariant is how the next person concludes all three are fine.
        func withLock<T>(_ body: (State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    private static let state = State()
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.voltline.kagipeek"
    /// Menu scanning: which app, how many items, why a catalog was empty or dropped.
    private static let scanLogger = Logger(subsystem: subsystem, category: "scan")
    /// Event tap, swallowing decisions, key injection.
    private static let inputLogger = Logger(subsystem: subsystem, category: "input")
    /// Reads and writes of settings.json / usage.json.
    private static let storageLogger = Logger(subsystem: subsystem, category: "storage")
    /// Windows, permissions, update checks.
    private static let uiLogger = Logger(subsystem: subsystem, category: "ui")

    /// Wires the switches and the sink. Called at launch and whenever settings change.
    static func configure(enabled: Bool, verbose: Bool, store: FileLogStore = .shared) {
        state.withLock { state in
            state.enabled = enabled
            state.verbose = verbose
            state.store = store
        }
    }

    static func applySettings(_ settings: AppSettingsSnapshot) {
        configure(enabled: settings.diagnosticsEnabled, verbose: settings.verboseDiagnostics)
    }

    static var isEnabled: Bool {
        state.withLock { $0.enabled }
    }

    static var isVerbose: Bool {
        state.withLock { $0.verbose }
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
        // Copied out in one guarded read: the message is built after the lock is released, so
        // a slow caller cannot hold the logger against every other thread.
        let (enabled, verbose, store) = state.withLock { ($0.enabled, $0.verbose, $0.store) }

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
            return scanLogger
        case .tap, .inject, .run:
            return inputLogger
        case .settings:
            return storageLogger
        case .start, .perm, .net, .ui, .crash, .exit, .export:
            return uiLogger
        }
    }
}

/// Hardware and OS facts that belong in every crash report and every launch line.
///
/// `nonisolated` because `DiagnosticsExporter` reads these from a background queue and the
/// crash-report path can reach them from the exception handler; they are pure reads of
/// `sysctlbyname`, `ProcessInfo` and `Bundle.main.infoDictionary`, with no shared state.
nonisolated enum DeviceInfo {
    /// The marketing-independent identifier, e.g. `Mac14,2`.
    static var modelIdentifier: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        // `String(cString:)` is deprecated in the Swift 6 SDK. Decode explicitly up to the
        // NUL instead of relying on the C-string overload's implicit termination scan.
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static var macOSVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var appVersion: String {
        Bundle.main.kagiPeekVersionDisplay
    }

    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// One line that identifies the build and the machine, for `[start]` and `[crash]`.
    static var summary: String {
        "version=\(appVersion) build=\(appBuild) macOS=\(macOSVersion) model=\(modelIdentifier)"
    }
}
