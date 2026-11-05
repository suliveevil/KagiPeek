import Foundation

/// Assembles the one JSON report a user attaches to a bug report.
///
/// The engine *has* these facts; it does not interpret them. Keeping the assembly here is what
/// makes that true, and it is the only way this report can be tested: `ShortcutEngine` has no
/// test net and cannot be constructed in one, while this type needs nothing but its `Input`.
///
/// Note what is deliberately absent: no `NSApp`, no `EngineState`, no stores. The engine
/// supplies every value, so this file stays free of AppKit and of the shared mutable state it
/// has no business writing. `sanitizerFailedPatterns` is read from `Sanitizer` because that is
/// a fact about the build, not about a session.
///
/// Everything that leaves here goes through `DiagnosticsRedactor` first: the report contains
/// other applications' window titles and the raw settings blob, and it is handed to a stranger.
/// The pass happens once, on the assembled payload, rather than at each field — the same
/// boundary discipline as the file log.
nonisolated enum DiagnosticsReportBuilder {
    /// Every fact the report is assembled from, travelling as one value.
    ///
    /// A parameter object rather than twenty-two arguments: the group is produced in one place
    /// and consumed in one place, and never varies in between (R2 *Introduce Parameter Object*).
    /// It is also what makes the report testable — a report can now be built from values that
    /// never existed in a running app.
    struct Input {
        /// Passed in rather than read from `Date()`, so a test can pin it and the output stops
        /// being non-deterministic.
        var generatedAt: Date
        var settings: AppSettingsSnapshot
        var hasAccessibility: Bool
        var hasInputMonitoring: Bool
        var isListening: Bool
        var catalogSize: Int
        var frontmostName: String
        var frontmostBundleID: String
        var usedBuiltInCatalog: Bool
        /// The three numbers a "Return did nothing" report needs: was a row selected, how many
        /// rows were there, and what prefix was the panel matching against.
        var panelSelectionIndex: Int
        var panelRowCount: Int
        /// Already rendered: how a chord is spelled is the panel's decision, not the report's.
        var prefixText: String
        var scanDuration: TimeInterval
        var scanState: ScanState
        var conflictCount: Int
        var systemBindingCount: Int
        var usageTracked: Int
        var usageTotalPresses: Int
        var favoriteCount: Int
        var dataFolderPath: String
        /// Supplied by the caller because reading them means asking `NSApp`, which is the one
        /// thing this file should not need.
        var windowTitles: [String]
        /// Crash fragments the launch-time sweep could not turn into a report. Empty when
        /// there was nothing left behind, or when everything left behind was completed.
        var crashRecoveryErrors: [String] = []
        /// Why the recent-actions mirror could not be written. Absent in a healthy session.
        var actionMirrorError: String? = nil
        /// Log lines the file sink could not write (or had to drop at the daily cap). Zero is
        /// the normal value; a non-zero one means the attached log has holes.
        var logLinesDropped: Int = 0
        /// The user's home directory, replaced with `~` in every path in the report. Supplied by
        /// the caller because the pure target must not ask for it, and because a test needs to
        /// pin it.
        var homePrefix: String? = nil
    }

    static func report(_ input: Input) throws -> Data {
        let bundle = Bundle.main
        let info = bundle.infoDictionary
        let bundleID = bundle.bundleIdentifier ?? "?"
        var payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: input.generatedAt),
            "version": AppVersion.display(
                shortVersion: info?["CFBundleShortVersionString"] as? String,
                commit: info?["KagiPeekCommit"] as? String
            ),
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "bundleID": bundleID,
            "bundlePath": bundle.bundlePath,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "schemaVersion": AppSettingsSnapshot.currentSchemaVersion,
            // Empty is the only acceptable value: a pattern here is a redaction rule that is
            // not being applied, so log lines are reaching disk unredacted.
            "sanitizerFailedPatterns": Sanitizer.failedPatterns,
            "hasAccessibility": input.hasAccessibility,
            "hasInputMonitoring": input.hasInputMonitoring,
            "isListening": input.isListening,
            "catalogSize": input.catalogSize,
            "frontmost": input.frontmostName,
            "frontmostBundleID": input.frontmostBundleID,
            "usedBuiltInCatalog": input.usedBuiltInCatalog,
            "panelSelectionIndex": input.panelSelectionIndex,
            "panelRowCount": input.panelRowCount,
            "prefix": input.prefixText,
            "scanDuration": input.scanDuration,
            // `ScanState` already spells itself for the file log; the report uses the same
            // spelling so one grep finds both.
            "scanState": input.scanState.diagnosticCode,
            "conflicts": input.conflictCount,
            "systemHotkeys": input.systemBindingCount,
            "usageTracked": input.usageTracked,
            "usageTotalPresses": input.usageTotalPresses,
            "favorites": input.favoriteCount,
            "dataFolder": input.dataFolderPath,
            "windowTitles": input.windowTitles,
            "logCommand": "log show --last 10m --predicate 'subsystem == \"\(bundleID)\"'"
        ]
        // Partial-success facts: the values that are empty for a reason. Absent when there is
        // nothing to explain, in the same shape as `settingsError` below.
        if !input.crashRecoveryErrors.isEmpty {
            payload["crashRecoveryErrors"] = input.crashRecoveryErrors
        }
        if let actionMirrorError = input.actionMirrorError {
            payload["actionMirrorError"] = actionMirrorError
        }
        if input.logLinesDropped > 0 {
            payload["logLinesDropped"] = input.logLinesDropped
        }
        do {
            let encoded = try JSONEncoder().encode(input.settings)
            payload["settings"] = try JSONSerialization.jsonObject(with: encoded)
        } catch {
            // An enrichment, not a requirement: a report without settings is still worth
            // attaching. But dropping a section in silence is how a broken encoder stays hidden,
            // so the reason goes inside the file the user attaches rather than nowhere.
            payload["settingsError"] = String(describing: error)
        }
        // One redaction pass at the boundary, after every section is in place: window titles,
        // the settings blob and the data-folder path all leave this function through the same
        // door the log lines use. The pass names the fields it changed in `redactedFields`.
        return try DiagnosticsRedactor.jsonData(payload, homePrefix: input.homePrefix)
    }
}
