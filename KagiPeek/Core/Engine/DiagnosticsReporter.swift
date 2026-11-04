import AppKit

/// Builds the support report from the engine's visible state.
///
/// The report is deliberately a snapshot of what the app can see, not a live probe: it is
/// assembled on the main actor from `EngineState`, the settings store and the usage store, so
/// saving it cannot change what is being diagnosed.
@MainActor
final class DiagnosticsReporter {
    private let state: EngineState
    private let settingsStore: SettingsStore
    private let usageStore: UsageStore
    private let frontmostBundleID: () -> String?

    init(
        state: EngineState,
        settingsStore: SettingsStore,
        usageStore: UsageStore,
        frontmostBundleID: @escaping () -> String?
    ) {
        self.state = state
        self.settingsStore = settingsStore
        self.usageStore = usageStore
        self.frontmostBundleID = frontmostBundleID
    }

    /// One JSON report for a bug report: what the app can see, what it persisted, and the
    /// command that prints the matching log lines. Nothing is uploaded; the user saves the
    /// file and decides who gets it.
    ///
    /// Throws when the report itself cannot be serialized. The settings snapshot is the one
    /// exception: it is an enrichment, so a failure there is recorded *inside* the report
    /// (`settingsError`) rather than failing it — a report without settings is still worth
    /// attaching, but dropping the section in silence is how a broken encoder goes unnoticed.
    func makeReport() throws -> Data {
        try DiagnosticsReportBuilder.report(
            .init(
                generatedAt: Date(),
                settings: settingsStore.settings,
                hasAccessibility: state.hasAccessibility,
                hasInputMonitoring: state.hasInputMonitoring,
                isListening: state.isListening,
                catalogSize: state.catalogSize,
                frontmostName: state.appName,
                frontmostBundleID: frontmostBundleID() ?? "",
                usedBuiltInCatalog: state.usedBuiltInCatalog,
                panelSelectionIndex: state.panel.selectionIndex,
                panelRowCount: state.panel.flatRowIDs.count,
                prefixText: KeyFormatter.render(state.prefix, style: state.settings.keyStyle),
                scanDuration: state.scanDuration,
                scanState: state.scanState,
                conflictCount: state.conflicts.count,
                systemBindingCount: state.systemBindings.count,
                usageTracked: usageStore.trackedCount,
                usageTotalPresses: usageStore.totalPresses,
                favoriteCount: usageStore.favorites.count,
                dataFolderPath: usageStore.dataFolderURL.path,
                windowTitles: NSApp.windows.filter(\.isVisible).map(\.title)
            )
        )
    }
}
