import AppKit
import Foundation

/// Bundles the diagnostics folder into one archive the user can attach to a bug report.
///
/// Nothing is uploaded, ever: this type has no networking, and the only thing it does with the
/// collected files is copy them into a zip the user chooses to share or not. Redaction already
/// happened at the write boundary (`FileLogStore`), so what is copied here is what a log line
/// already contains.
enum DiagnosticsExporter {
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
    }

    static func defaultFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "KagiPeek-diagnostics-\(formatter.string(from: now)).zip"
    }

    /// Builds `destination` (a `.zip`). Throws only when nothing usable could be produced.
    static func export(to destination: URL, settings: AppSettingsSnapshot, now: Date = Date()) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("KagiPeek-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let bundle = staging.appendingPathComponent("KagiPeek-diagnostics", isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let logsFolder = DataDirectory.url(for: "logs")
        let crashFolder = DataDirectory.url(for: "crash")
        let logFiles = copyContents(of: logsFolder, into: bundle.appendingPathComponent("logs", isDirectory: true))
        let crashFiles = copyContents(of: crashFolder, into: bundle.appendingPathComponent("crash", isDirectory: true))

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
            logFiles: logFiles,
            crashFiles: crashFiles
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(
            to: bundle.appendingPathComponent("session-info.json"),
            options: [.atomic]
        )

        Diag.info(.export, "exporting diagnostics: \(logFiles.count) log files, \(crashFiles.count) crash files")

        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try runDitto(from: bundle, to: destination)
    }

    // MARK: - Internals

    private static func copyContents(of source: URL, into destination: URL) -> [String] {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let contents = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            return []
        }
        var copied: [String] = []
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
                copied.append(name)
            } catch {
                // A file locked by another process is not worth failing the export over.
                continue
            }
        }
        return copied.sorted()
    }

    private static func summary(of settings: AppSettingsSnapshot) -> [String: String] {
        [
            "triggerMode": settings.triggerMode.rawValue,
            "panelPlacement": settings.panelPlacement.rawValue,
            "panelTheme": settings.panelTheme.rawValue,
            "keyStyle": settings.keyStyle.rawValue,
            "keyPosition": settings.keyPosition.rawValue,
            "columnCount": String(settings.columnCount),
            "maxItemsPerPage": String(settings.maxItemsPerPage),
            "language": settings.language.rawValue,
            "sortMode": settings.sortMode.rawValue,
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

        var errorDescription: String? {
            switch self {
            case .archiveFailed:
                return "The diagnostics archive could not be created."
            case .archiveTimedOut:
                return "The diagnostics archive took too long to create."
            }
        }
    }
}
