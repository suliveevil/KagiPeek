import AppKit
import Foundation

/// Bundles the diagnostics folder into one archive the user can attach to a bug report.
///
/// Nothing is uploaded, ever: this type has no networking, and the only thing it does with the
/// collected files is copy them into a zip the user chooses to share or not. Redaction already
/// happened at the write boundary (`FileLogStore`), so the copied files are what a log line
/// already contains; the manifest this type writes itself goes through `DiagnosticsRedactor`
/// before it reaches the archive, because file names and error notes quote the folder they
/// came from.
///
/// Explicitly `nonisolated`: `export` runs on a background queue on purpose (a slow network
/// destination must not freeze the settings window), and every dependency here —
/// `DataDirectory`, `PermissionCenter`, `DeviceInfo`, `Diag` — is thread-agnostic too. With
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unmarked enum would make `export`
/// main-actor-isolated and the background call an error.
nonisolated enum DiagnosticsExporter {
    struct SessionInfo: Codable {
        var generatedAt: String
        var appVersion: String
        var appBuild: String
        var macOSVersion: String
        var modelIdentifier: String
        var uptimeSeconds: Int
        var locale: String
        var accessibilityGranted: Bool
        var inputMonitoringGranted: Bool
        var diagnosticsEnabled: Bool
        var verboseEnabled: Bool
        /// Enum-valued settings only: enough to reproduce a layout bug, without the app-usage
        /// profile that `excludedBundleIDs` and favourites would amount to.
        var settingsSummary: [String: String]
        var logFiles: [String]
        var crashFiles: [String]
        /// Why `logFiles` is not everything that was on disk: the folder could not be read, or
        /// a file was found but could not be copied. **Absent** when nothing is missing.
        ///
        /// Both fields follow the `settingsError` convention from the report the About tab
        /// builds: a partial report is still worth attaching, so these never fail the export —
        /// they just make sure "we could not read your logs" is legible to the person reading
        /// the attachment, instead of looking like an app that simply had no logs.
        var logFilesError: String?
        var crashFilesError: String?
        /// Redaction patterns that did not compile and so are not being applied.
        ///
        /// Empty is the only acceptable value. This is here rather than left to the log because
        /// a non-empty list means log lines are reaching disk — and leaving the machine in this
        /// archive — with content this table exists to remove, which is the one failure in this
        /// file that outlives the session.
        var sanitizerFailedPatterns: [String]
        /// Crash fragments the launch sweep could not complete. **Absent** when there was
        /// nothing left to recover, or when everything was recovered.
        var crashRecoveryErrors: [String]?
        /// Why the recent-action mirror is not current. **Absent** in a healthy session.
        var actionMirrorError: String?
        /// Log lines this session could not write (or dropped at the daily cap). **Absent**
        /// when the attached log has no holes.
        var logLinesDropped: Int?
    }

    static func defaultFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Kaname-diagnostics-\(formatter.string(from: now)).zip"
    }

    /// Builds `destination` (a `.zip`). Throws only when nothing usable could be produced.
    static func export(to destination: URL, settings: AppSettingsSnapshot, now: Date = Date()) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("Kaname-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let bundle = staging.appendingPathComponent("Kaname-diagnostics", isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let logsFolder = DataDirectory.url(for: "logs")
        let crashFolder = DataDirectory.url(for: "crash")
        let logCopy = copyContents(of: logsFolder, into: bundle.appendingPathComponent("logs", isDirectory: true))
        let crashCopy = copyContents(of: crashFolder, into: bundle.appendingPathComponent("crash", isDirectory: true))
        let recoveryMessages = CrashReporter.recoveryStatus.messages
        let mirrorError = ActionRecorder.shared.mirrorError
        let droppedLines = FileLogStore.shared.droppedLineCount

        let info = SessionInfo(
            generatedAt: ISO8601DateFormatter().string(from: now),
            appVersion: DeviceInfo.appVersion,
            appBuild: DeviceInfo.appBuild,
            macOSVersion: DeviceInfo.macOSVersion,
            modelIdentifier: DeviceInfo.modelIdentifier,
            uptimeSeconds: Int(ProcessInfo.processInfo.systemUptime),
            locale: Locale.current.identifier,
            accessibilityGranted: PermissionCenter.hasAccessibility,
            inputMonitoringGranted: PermissionCenter.hasInputMonitoring,
            diagnosticsEnabled: settings.diagnosticsEnabled,
            verboseEnabled: settings.verboseDiagnostics,
            settingsSummary: summary(of: settings),
            logFiles: logCopy.copied,
            crashFiles: crashCopy.copied,
            logFilesError: logCopy.note,
            crashFilesError: crashCopy.note,
            sanitizerFailedPatterns: Sanitizer.failedPatterns,
            crashRecoveryErrors: recoveryMessages.isEmpty ? nil : recoveryMessages,
            actionMirrorError: mirrorError,
            logLinesDropped: droppedLines > 0 ? droppedLines : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // The manifest is part of the archive, so it gets the same boundary as the report:
        // file names and error notes can carry a path or a token from someone's folder.
        let encoded = try encoder.encode(info)
        guard let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            // `SessionInfo` is a struct of strings and numbers, so this cannot fire. Failing
            // loudly beats writing a manifest that skipped the redaction pass.
            throw ExportError.manifestFailed
        }
        try DiagnosticsRedactor.jsonData(fields, homePrefix: NSHomeDirectory()).write(
            to: bundle.appendingPathComponent("session-info.json"),
            options: [.atomic]
        )

        Diag.info(.export, "exporting diagnostics: \(logCopy.copied.count) log files, \(crashCopy.copied.count) crash files")
        // The archive is the only thing the user takes away, so what is missing goes in the log
        // too: a dropped file is invisible there, and this is the line a bug report quotes.
        if let note = logCopy.note { Diag.warning(.export, "logs folder incomplete: \(note)") }
        if let note = crashCopy.note { Diag.warning(.export, "crash folder incomplete: \(note)") }

        do {
            try fileManager.removeItem(at: destination)
        } catch CocoaError.fileNoSuchFile {
            // The normal case: `ditto` is about to create it.
        }
        try runDitto(from: bundle, to: destination)
    }

    // MARK: - Internals

    /// What copying one folder contributed to the archive.
    ///
    /// `copied` is what the archive actually holds; the other two fields are what it does not.
    /// They exist to separate two situations that used to look identical to whoever receives
    /// the report: a folder that was genuinely empty, and a folder whose contents we never got.
    private struct FolderCopy {
        var copied: [String] = []
        /// Files that were found but could not be copied, each with the reason.
        var skipped: [(name: String, reason: String)] = []
        /// Why this folder contributed nothing: the destination could not be created, or the
        /// source could not be listed. `nil` means the folder was read, so an empty `copied`
        /// really does mean it was empty.
        var failure: String?

        /// One sentence for `session-info.json`; `nil` when nothing is missing.
        var note: String? {
            var parts: [String] = []
            if let failure { parts.append(failure) }
            for skip in skipped { parts.append("\(skip.name): \(skip.reason)") }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
    }

    private static func copyContents(of source: URL, into destination: URL) -> FolderCopy {
        let fileManager = FileManager.default
        var result = FolderCopy()
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            result.failure = "destination folder could not be created: \(error.localizedDescription)"
            return result
        }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        } catch {
            result.failure = "folder could not be listed: \(error.localizedDescription)"
            return result
        }
        for file in contents where !file.hasDirectoryPath {
            // The sentinel belongs to the session doing the exporting, an unfinished fragment
            // is a crash the next launch will complete, and the action mirror is already
            // folded into that report — none of them helps a reader.
            let name = file.lastPathComponent
            if name == "session.active" || name == "last-actions.json" || name.hasSuffix(".partial") {
                continue
            }
            let target = destination.appendingPathComponent(name)
            do {
                try fileManager.copyItem(at: file, to: target)
                result.copied.append(name)
            } catch {
                // A file locked by another process is not worth failing the export over, but it
                // is worth writing down: an archive that quietly lacks a log file is worse than
                // no archive, because the reader will not know to distrust it.
                result.skipped.append((name, error.localizedDescription))
            }
        }
        result.copied.sort()
        return result
    }

    private static func summary(of settings: AppSettingsSnapshot) -> [String: String] {
        [
            "modifierTriggerEnabled": String(settings.modifierTriggerEnabled),
            "hotkeyTriggerEnabled": String(settings.hotkeyTriggerEnabled),
            "triggerGesture": settings.triggerGesture.rawValue,
            "triggerKey": settings.triggerKey.rawValue,
            "panelPlacement": settings.panelPlacement.rawValue,
            "panelTheme": settings.panelTheme.rawValue,
            "keyStyle": settings.keyStyle.rawValue,
            "keyPosition": settings.keyPosition.rawValue,
            "columnCount": String(settings.columnCount),
            "maxItemsPerPage": String(settings.maxItemsPerPage),
            "language": settings.language.rawValue,
            "usageSortField": settings.usageSortField.rawValue,
            "showAppleMenu": String(settings.showAppleMenu),
            "scanConfigFiles": String(settings.scanConfigFiles),
            "includeBuiltInCatalog": String(settings.includeBuiltInCatalog)
        ]
    }

    /// `ditto` ships with macOS and produces a zip that survives extractors other than
    /// Archive Utility, unlike a hand-rolled archive. It is invoked without a shell.
    ///
    /// The wait is bounded: the destination can be an unreachable network volume, and a
    /// process that never exits must not leave the caller hanging forever. On timeout the
    /// child is terminated and the export is reported as failed.
    private static func runDitto(from source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            throw ExportError.archiveTimedOut
        }
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw ExportError.archiveFailed
        }
    }

    enum ExportError: LocalizedError {
        case archiveFailed
        case archiveTimedOut
        case manifestFailed

        var errorDescription: String? {
            switch self {
            case .archiveFailed:
                return "The diagnostics archive could not be created."
            case .archiveTimedOut:
                return "The diagnostics archive took too long to create."
            case .manifestFailed:
                return "The diagnostics summary could not be prepared."
            }
        }
    }
}
