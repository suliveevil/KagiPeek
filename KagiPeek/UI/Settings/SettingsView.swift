import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @EnvironmentObject private var state: EngineState
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var usageStore: UsageStore
    @EnvironmentObject private var localization: Localization

    private var settings: AppSettingsSnapshot { store.settings }

    @State private var tab: SettingsTab = .general
    /// Selected row in the excluded-apps list. Selection, not a text cursor: an app is
    /// removed by pointing at it, the same way the Finder works.
    @State private var excludedSelection: String?
    @State private var showIgnoreSheet = false
    /// Which ignored-command groups are open. The global group starts open; app groups open
    /// when a rule is added to them.
    @State private var expandedScopes: Set<String> = ["*"]
    /// Which app groups in the statistics list are open. The busiest one opens on appear.
    @State private var expandedUsageApps: Set<String> = []
    /// How many findings the Conflicts page draws. Raised by the "show more" button.
    @State private var findingPageSize = SettingsView.findingPageStep
    private static let findingPageStep = 40
    /// Lets the preview harness open a specific tab (e.g. `KAGIPEEK_PREVIEW=settings-ranking`).
    init(initialTab: SettingsTab = .general) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases, id: \.self) { item in
                    Text(localization.text(item.titleKey)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 600)
        .background(Theme.surface)
        .environmentObject(localization)
        .onAppear {
            engine.closeSurfaces()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: generalTab
        case .trigger: triggerTab
        case .appearance: appearanceTab
        case .statistics: statisticsTab
        case .conflicts: conflictsTab
        case .permissions: permissionsTab
        case .diagnostics: diagnosticsTab
        case .about: aboutTab
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Picker(localization.text(.appearanceLanguage), selection: $store.settings.language) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(localization.text(language.titleKey)).tag(language)
                }
            }

            Toggle(localization.text(.generalLaunchAtLogin), isOn: Binding(
                get: { settings.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))

            if let message = store.launchAtLoginMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }

            Toggle(localization.text(.rankingHUD), isOn: $store.settings.showExecutedHUD)
            Toggle(localization.text(.rankingIncludeBuiltIn), isOn: $store.settings.includeBuiltInCatalog)
            Toggle(localization.text(.generalShowAppleMenu), isOn: $store.settings.showAppleMenu)
            Text(localization.text(.generalShowAppleMenuHint))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle(localization.text(.generalShowDockIcon), isOn: $store.settings.showDockIcon)
            Text(localization.text(.generalShowDockIconHint))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Section(localization.text(.rowActionSection)) {
                hotkeyRow(title: localization.text(.rowActionExecute),
                          target: .runRow,
                          spec: settings.runRowKey)
                hotkeyRow(title: localization.text(.rowActionCopy),
                          target: .copyRow,
                          spec: settings.copyRowKey)
                Text(localization.text(.rowActionHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(localization.text(.generalExcludedApps)) {
                excludedAppsList
                HStack(spacing: 8) {
                    Button { addExcludedApps() } label: {
                        Label(localization.text(.generalAddApp), systemImage: "plus")
                    }
                    Button { removeSelectedExcludedApp() } label: {
                        Label(localization.text(.generalRemoveApp), systemImage: "minus")
                    }
                    .disabled(excludedSelection == nil)
                    Spacer()
                }
                Text(localization.text(.generalExcludedAppsHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(localization.text(.generalIgnoredCommands)) {
                ignoredCommandsList
                HStack {
                    Button { showIgnoreSheet = true } label: {
                        Label(localization.text(.ignoredAddCommand), systemImage: "plus")
                    }
                    Spacer()
                }
                Text(localization.text(.generalIgnoredCommandsHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showIgnoreSheet) {
            IgnoreCommandSheet(
                runningApps: state.runningApps,
                localization: localization,
                suggestionsFor: { app, completion in
                    engine.commandTitles(for: app, completion: completion)
                },
                onAdd: { command in
                    store.settings.ignoredCommands = IgnoredCommands.normalized(
                        store.settings.ignoredCommands + [command]
                    )
                    expandedScopes.insert(command.scopeKey)
                },
                onCancel: { showIgnoreSheet = false }
            )
            .environmentObject(localization)
        }
    }

    // MARK: - Excluded apps

    /// A selectable list, not a text field: bundle identifiers are easy to mistype and
    /// impossible to verify by eye. The picker hands the user the app itself.
    private var excludedAppsList: some View {
        Group {
            if settings.excludedBundleIDs.isEmpty {
                Text(localization.text(.generalNoExcludedApps))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                            excludedRow(bundleID)
                        }
                    }
                }
                .frame(height: 132)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.8)
                )
            }
        }
    }

    private func excludedRow(_ bundleID: String) -> some View {
        let selected = excludedSelection == bundleID
        return HStack(spacing: 8) {
            if let icon = appIcon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(appDisplayName(for: bundleID))
                .lineLimit(1)
            Text(bundleID)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { excludedSelection = bundleID }
    }

    private func addExcludedApps() {
        let panel = NSOpenPanel()
        panel.title = localization.text(.generalAddApp)
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if let appType = UTType(filenameExtension: "app") {
            panel.allowedContentTypes = [appType]
        }
        guard panel.runModal() == .OK else { return }
        var list = settings.excludedBundleIDs
        for url in panel.urls {
            guard let identifier = Bundle(url: url)?.bundleIdentifier,
                  !list.contains(identifier) else { continue }
            list.append(identifier)
        }
        store.settings.excludedBundleIDs = list
        excludedSelection = panel.urls.first.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    private func removeSelectedExcludedApp() {
        guard let selection = excludedSelection else { return }
        store.settings.excludedBundleIDs.removeAll { $0 == selection }
        excludedSelection = settings.excludedBundleIDs.first
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Ignored commands

    /// One disclosure group per scope: everything, then one group per app that has rules.
    /// A flat list would make “Reload Page in Safari” and “Reload Page in Xcode” look like the
    /// same rule, which is exactly the confusion the per-app scope exists to avoid.
    private var ignoredCommandsList: some View {
        Group {
            if settings.ignoredCommands.isEmpty {
                Text(localization.text(.ignoredEmpty))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(IgnoredCommands.scopes(in: settings.ignoredCommands), id: \.self) { scope in
                    DisclosureGroup(isExpanded: expansionBinding(for: scope)) {
                        ForEach(rules(in: scope)) { command in
                            HStack {
                                Text(command.title).lineLimit(1)
                                Spacer()
                                Button {
                                    remove(command)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(localization.text(.generalRemoveApp))
                            }
                        }
                    } label: {
                        Text(scopeTitle(for: scope))
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
            }
        }
    }

    private func rules(in scope: String?) -> [IgnoredCommand] {
        settings.ignoredCommands.filter { $0.appBundleID == scope }
    }

    private func scopeTitle(for scope: String?) -> String {
        guard let scope else { return localization.text(.ignoredScopeGlobal) }
        return appDisplayName(for: scope)
    }

    private func expansionBinding(for scope: String?) -> Binding<Bool> {
        let key = scope ?? "*"
        return Binding(
            get: { expandedScopes.contains(key) },
            set: { expanded in
                if expanded { expandedScopes.insert(key) } else { expandedScopes.remove(key) }
            }
        )
    }

    private func remove(_ command: IgnoredCommand) {
        store.settings.ignoredCommands.removeAll { $0.id == command.id }
    }

    // MARK: - Trigger

    private var triggerTab: some View {
        Form {
            Picker(localization.text(.triggerMode), selection: $store.settings.triggerMode) {
                ForEach(TriggerMode.allCases, id: \.self) { mode in
                    Text(localization.text(mode.titleKey)).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            LabeledContent(localization.text(.triggerHoldDelay)) {
                HStack {
                    Slider(value: $store.settings.holdDelay, in: 0.1...1.5, step: 0.05)
                    Text(String(format: "%.2fs", settings.holdDelay))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }
            }
            .disabled(settings.triggerMode != .holdModifiers)

            LabeledContent(localization.text(.triggerDoubleTapWindow)) {
                HStack {
                    Slider(value: $store.settings.doubleTapWindow, in: 0.15...0.8, step: 0.05)
                    Text(String(format: "%.2fs", settings.doubleTapWindow))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }
            }
            .disabled(settings.triggerMode != .doubleTapCommand)

            hotkeyRow(title: localization.text(.triggerPanelHotkey), target: .panel, spec: settings.panelHotkey)
            hotkeyRow(title: localization.text(.triggerSearchHotkey), target: .search, spec: settings.searchHotkey)
            hotkeyRow(title: localization.text(.triggerSwitchHotkey), target: .switcher, spec: settings.switchHotkey)

            Text(localization.text(.overlayHint))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func hotkeyRow(title: String, target: HotkeyTarget, spec: HotkeySpec) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if state.recordingTarget == target {
                    Text(localization.text(.triggerRecordingHint))
                        .foregroundStyle(.orange)
                } else {
                    KeycapView(text: KeyFormatter.render(spec.chord, style: settings.keyStyle), compact: true)
                }
                Button(state.recordingTarget == target
                       ? localization.text(.triggerOff)
                       : localization.text(.triggerRecording)) {
                    if state.recordingTarget == target {
                        engine.cancelRecording()
                    } else {
                        engine.beginRecording(target)
                    }
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        Form {
            Picker(localization.text(.appearanceKeyStyle), selection: $store.settings.keyStyle) {
                ForEach(KeyFormatter.Style.allCases, id: \.self) { style in
                    Text(localization.text(style.l10nKey)).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Picker(localization.text(.appearanceTheme), selection: $store.settings.panelTheme) {
                ForEach(PanelTheme.allCases, id: \.self) { theme in
                    Text(localization.text(theme.titleKey)).tag(theme)
                }
            }
            .pickerStyle(.segmented)

            Picker(localization.text(.appearanceKeyPosition), selection: $store.settings.keyPosition) {
                ForEach(KeyPosition.allCases, id: \.self) { position in
                    Text(localization.text(position.titleKey)).tag(position)
                }
            }
            .pickerStyle(.segmented)

            Picker(localization.text(.appearanceColumns), selection: $store.settings.columnCount) {
                Text("1").tag(1)
                Text("2").tag(2)
                Text("3").tag(3)
            }
            .pickerStyle(.segmented)

            LabeledContent(localization.text(.appearanceMaxItems)) {
                Stepper(value: $store.settings.maxItemsPerPage, in: 6...60, step: 2) {
                    Text("\(settings.maxItemsPerPage)").monospacedDigit()
                }
            }

            LabeledContent(localization.text(.appearanceMaxDescription)) {
                Stepper(value: $store.settings.maxDescriptionLength, in: 8...80, step: 2) {
                    Text("\(settings.maxDescriptionLength)").monospacedDigit()
                }
            }

            Toggle(localization.text(.appearanceShowDisabled), isOn: $store.settings.showDisabledItems)
            Toggle(localization.text(.favoritesPinTop), isOn: $store.settings.pinFavoritesToTop)
            Toggle(localization.text(.favoritesFilterable), isOn: $store.settings.favoritesCanBeFiltered)

            Picker(localization.text(.appearancePlacement), selection: $store.settings.panelPlacement) {
                ForEach(PanelPlacement.allCases, id: \.self) { placement in
                    Text(localization.text(placement.titleKey)).tag(placement)
                }
            }

            if settings.panelPlacement == .fixedSize {
                LabeledContent(localization.text(.appearanceFixedWidth)) {
                    Stepper(value: $store.settings.fixedPanelWidth, in: 320...4000, step: 20) {
                        Text("\(Int(settings.fixedPanelWidth))").monospacedDigit()
                    }
                }
                LabeledContent(localization.text(.appearanceFixedHeight)) {
                    Stepper(value: $store.settings.fixedPanelHeight, in: 240...3000, step: 20) {
                        Text("\(Int(settings.fixedPanelHeight))").monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Statistics

    /// What used to be the "Ranking" tab. Sort order stays here — it is what decides the
    /// numbers the section below reports — while the conflict list moved to its own tab: it
    /// answers a different question ("who else claims this key?") and made this page long
    /// enough that the statistics were never seen.
    private var statisticsTab: some View {
        Form {
            Picker(localization.text(.rankingMode), selection: $store.settings.sortMode) {
                ForEach(RankMode.allCases, id: \.self) { mode in
                    Text(localization.text(mode.titleKey)).tag(mode)
                }
            }
            Text(localization.text(.rankingModeHint))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Section(localization.text(.statsSection)) {
                Text(localization.format(.rankingUsageSummary, usageStore.trackedCount, usageStore.totalPresses))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                let summaries = UsageOrdering.apps(
                    usageStore.summariesByApp(),
                    mode: settings.sortMode,
                    name: { appDisplayName(for: $0) }
                )
                if summaries.isEmpty {
                    Text(localization.text(.statsNoData))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summaries) { summary in
                        usageGroup(summary)
                    }
                    .onAppear {
                        // Open the busiest app: the numbers are the point, and a page of
                        // collapsed rows shows none of them.
                        if expandedUsageApps.isEmpty, let first = summaries.first {
                            expandedUsageApps.insert(first.id)
                        }
                    }
                }

                Button(localization.text(.statsOpenDataFolder)) {
                    NSWorkspace.shared.open(usageStore.dataFolderURL)
                }
                Button(localization.text(.rankingReset)) {
                    engine.resetUsage()
                }
                .disabled(usageStore.totalPresses == 0)
            }

            Button(localization.text(.rankingDefaults)) {
                store.resetToDefaults()
                // A reset is a clean slate: cached scans were written under the old
                // settings, and their fingerprints are the only thing saying so.
                engine.invalidateScanCaches()
            }
        }
        .formStyle(.grouped)
    }

    /// One app, folded: the header carries the totals, the body is shortcut → command → count.
    private func usageGroup(_ summary: AppUsageSummary) -> some View {
        DisclosureGroup(isExpanded: usageExpansion(for: summary.id)) {
            let entries = engine.usageEntries(for: summary.bundleID)
            if entries.isEmpty {
                Text(localization.text(.statsNoData))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    usageRow(entry)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let icon = appIcon(for: summary.bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 15, height: 15)
                }
                Text(appDisplayName(for: summary.bundleID))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(summary.presses)")
                    .monospacedDigit()
                Text("\(summary.shortcutCount) \(localization.text(.statsShortcuts))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A row whose title is missing is still worth showing: the count is true, and the
    /// shortcut is recovered from the usage key. Saying "not scanned" is more useful than
    /// hiding a command the user clearly pressed.
    private func usageRow(_ entry: UsageEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.chord.map { KeyFormatter.render($0, style: settings.keyStyle) } ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.isShortcutless ? .secondary : .primary)
                .frame(width: 76, alignment: .leading)
            Text(entry.title ?? localization.text(.statsUnknownCommand))
                .font(.caption)
                .foregroundStyle(entry.title == nil ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(entry.presses)")
                .font(.caption)
                .monospacedDigit()
        }
    }

    private func usageExpansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedUsageApps.contains(id) },
            set: { expanded in
                if expanded { expandedUsageApps.insert(id) } else { expandedUsageApps.remove(id) }
            }
        )
    }

    // MARK: - Conflicts

    private var conflictsTab: some View {
        Form {
            // Sources first: "which files did you read" is the context for every verdict
            // below, and a reader who does not know whether Karabiner was scanned cannot
            // tell a clean result from a blind one.
            configToolsSection

            Section(localization.text(.conflictListTitle)) {
                LabeledContent(localization.text(.conflictType)) {
                    Picker("", selection: $state.conflictCategory) {
                        Text(localization.format(.conflictTypeAllFormat, state.crossAppConflicts.count))
                            .tag(ConflictCategory?.none)
                        ForEach(state.conflictTypeOptions) { option in
                            Text(typeFilterLabel(option)).tag(Optional(option.category))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                LabeledContent(localization.text(.conflictOwner)) {
                    Picker("", selection: $state.conflictOwner) {
                        ForEach(engine.conflictOwnerOptions) { option in
                            Text(ownerFilterLabel(option)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                // The scan walks every running app's menus, so it is a button, not something
                // that happens when the page opens. The timestamp says how old the list is.
                HStack(spacing: 8) {
                    if state.isScanningCrossApp {
                        ProgressView().controlSize(.small)
                        Text(localization.text(.conflictScanning))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(scanTimestampText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(localization.text(.conflictRescan)) {
                        engine.rescanCrossAppConflicts()
                    }
                    .controlSize(.small)
                    .disabled(state.isScanningCrossApp)
                }

                if state.visibleConflicts.isEmpty {
                    Text(localization.text(
                        state.conflicts.isEmpty ? .conflictNone : .conflictTypeEmpty
                    ))
                    .foregroundStyle(.secondary)
                } else {
                    Text(localization.format(.conflictFoundFormat, state.visibleConflicts.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // Rendered in pages. A scan can produce a few hundred findings, and a Form
                    // builds every row it is handed — laying out all of them at once is what
                    // makes the window stutter while the background scan appends.
                    let shown = Array(state.visibleConflicts.prefix(findingPageSize))
                    ForEach(shown) { conflict in
                        ConflictRowView(conflict: conflict, style: settings.keyStyle)
                    }
                    if state.visibleConflicts.count > shown.count {
                        Button(localization.format(
                            .conflictShowMoreFormat,
                            min(Self.findingPageStep, state.visibleConflicts.count - shown.count),
                            state.visibleConflicts.count
                        )) {
                            findingPageSize += Self.findingPageStep
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Stored data first, scan only when there is nothing to show: the page used to walk
        // every running app's menus on each visit, which is the "it hangs for a while"
        // complaint. Manual rescans live in the header below.
        .onAppear { engine.prepareCrossAppConflicts() }
    }

    private var scanTimestampText: String {
        guard let scannedAt = state.crossAppScannedAt else {
            return localization.text(.conflictNeverScanned)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return localization.format(.conflictScannedAtFormat, formatter.string(from: scannedAt))
    }

    private func typeFilterLabel(_ option: ConflictTypeOption) -> String {
        "\(localization.text(option.category.labelKey)) (\(option.count))"
    }

    private func ownerFilterLabel(_ option: ConflictOwnerFilter) -> String {
        if let key = option.labelKey { return localization.text(key) }
        if case .app(let bundleID) = option { return appDisplayName(for: bundleID) }
        return localization.text(.conflictOwnerAll)
    }

    /// Which third-party tools were read, and what they contributed.
    private var configToolsSection: some View {
        Section(localization.text(.configToolsTitle)) {
            Toggle(localization.text(.configToolsToggle), isOn: $store.settings.scanConfigFiles)
            Text(localization.text(.configToolsSubtitle))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !settings.scanConfigFiles {
                Text(localization.text(.configToolsPrivacyNote))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if state.configScan.totalCount == 0 && state.configScan.counts.isEmpty {
                Text(localization.text(.configToolsNoneFound))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ConfigTool.allCases) { tool in
                    HStack {
                        Text(tool.displayName)
                        Spacer()
                        Text(state.configScan.unreadable.contains(tool)
                             ? localization.text(.configToolUnreadable)
                             : localization.format(
                                .configToolCountFormat,
                                tool.displayName,
                                state.configScan.counts[tool] ?? 0
                             ))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button(localization.text(.configToolsRescan)) {
                engine.scanConfigFiles()
            }
            .disabled(!settings.scanConfigFiles)
        }
    }

    // MARK: - Permissions

    private var permissionsTab: some View {
        Form {
            Section {
                Button(localization.text(.permissionWizard)) {
                    engine.showPermissionsWindow()
                }
                Text(localization.text(.permissionsSubtitle))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            permissionRow(
                title: localization.text(.permissionAccessibility),
                hint: localization.text(.permissionAccessibilityHint),
                granted: state.hasAccessibility,
                showDrag: true,
                request: { engine.requestAccessibility() },
                openSettings: { engine.openAccessibilitySettings() }
            )

            permissionRow(
                title: localization.text(.permissionInputMonitoring),
                hint: localization.text(.permissionInputMonitoringHint),
                granted: state.hasInputMonitoring,
                request: { engine.requestInputMonitoring() },
                openSettings: { engine.openInputMonitoringSettings() }
            )

            Section {
                LabeledContent(localization.text(.statusReady)) {
                    Text(state.isListening ? localization.text(.statusReady) : localization.text(.statusNoPermission))
                        .foregroundStyle(state.isListening ? .green : .orange)
                }
                LabeledContent(localization.text(.appName)) {
                    Text(state.appName.isEmpty ? "—" : state.appName).foregroundStyle(.secondary)
                }
                LabeledContent(localization.text(.aboutMenuItems)) {
                    Text("\(state.catalogSize)").monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(
        title: String,
        hint: String,
        granted: Bool,
        showDrag: Bool = false,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(granted ? localization.text(.permissionGranted) : localization.text(.permissionMissing))
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(granted ? Color.green.opacity(0.18) : Color.orange.opacity(0.18)))
                    .foregroundStyle(granted ? .green : .orange)
                Spacer()
                if !granted {
                    Button(localization.text(.permissionRequest), action: request)
                    Button(localization.text(.permissionOpenSettings), action: openSettings)
                }
            }
            Text(hint).font(.footnote).foregroundStyle(.secondary)
            if showDrag, !granted {
                HStack(spacing: 10) {
                    DragAppIcon()
                    Text(localization.text(.permissionDragHint))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Diagnostics

    /// The user-facing half of the observability work: the switches that decide what is
    /// recorded, the folder it lands in, and one button that turns the result into something
    /// attachable to a bug report.
    private var diagnosticsTab: some View {
        Form {
            Section {
                Toggle(localization.text(.diagnosticsEnable), isOn: $store.settings.diagnosticsEnabled)
                Text(localization.text(.diagnosticsEnableHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle(localization.text(.diagnosticsVerbose), isOn: $store.settings.verboseDiagnostics)
                    .disabled(!settings.diagnosticsEnabled)
                Text(localization.text(.diagnosticsVerboseHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(localization.text(.diagnosticsPath)) {
                Text(logFolderURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(localization.text(.diagnosticsOpenFolder)) {
                        NSWorkspace.shared.open(logFolderURL)
                    }
                    Button(localization.text(.diagnosticsExport)) {
                        exportLogArchive()
                    }
                    .disabled(!settings.diagnosticsEnabled)
                }
            }

            Section {
                Text(localization.text(.diagnosticsPrivacyNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var logFolderURL: URL {
        DataDirectory.url(for: "logs")
    }

    /// Writes the archive the user picked a destination for.
    ///
    /// The copy and the `ditto` run happen on a background queue: the destination can be a
    /// slow network volume, and a save panel that has already closed must not freeze the
    /// window while the archive is built.
    private func exportLogArchive() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsExporter.defaultFileName()
        panel.canCreateDirectories = true
        if let zipType = UTType(filenameExtension: "zip") {
            panel.allowedContentTypes = [zipType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = settings
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try DiagnosticsExporter.export(to: url, settings: snapshot)
                DispatchQueue.main.async {
                    engine.showHUD(chord: "✓", title: localization.text(.diagnosticsExportDone))
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    engine.showHUD(
                        chord: "!",
                        title: localization.format(.diagnosticsExportFailed, message)
                    )
                }
            }
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localization.text(.appName))
                            .font(.system(size: 18, weight: .semibold))
                        Text(appVersion)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(localization.text(.aboutSystem)) {
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                        .foregroundStyle(.secondary)
                }
                UpdateCheckRow(
                    checker: engine.updateChecker,
                    currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                )
                .environmentObject(localization)
            }

            Section(localization.text(.aboutDataFolder)) {
                Text(usageStore.dataFolderURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Button(localization.text(.statsOpenDataFolder)) {
                    NSWorkspace.shared.open(usageStore.dataFolderURL)
                }
            }

            Section {
                LabeledContent(localization.text(.aboutRepository)) {
                    Link("suliveevil/KagiPeek", destination: URL(string: "https://github.com/suliveevil/KagiPeek")!)
                }
                LabeledContent(localization.text(.aboutLicense)) {
                    Text("GNU GPL v2.0").foregroundStyle(.secondary)
                }
            }

            Section(localization.text(.aboutDiagnostics)) {
                LabeledContent(localization.text(.permissionAccessibility)) {
                    Text(state.hasAccessibility ? "✓" : "—")
                }
                LabeledContent(localization.text(.permissionInputMonitoring)) {
                    Text(state.hasInputMonitoring ? "✓" : "—")
                }
                LabeledContent(localization.text(.statusReady)) {
                    Text(state.isListening ? localization.text(.statusReady) : localization.text(.statusNoPermission))
                }
                LabeledContent(localization.text(.aboutMenuItems)) {
                    Text("\(state.catalogSize)").monospacedDigit()
                }
                Button(localization.text(.aboutExportDiagnostics)) {
                    exportDiagnostics()
                }
                Text(localization.text(.aboutDiagnosticsHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Writes the same report the About tab shows, plus the settings snapshot, to a file the
    /// user can attach to a bug report.
    private func exportDiagnostics() {
        guard let data = engine.diagnosticsReport() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kagipeek-diagnostics.json"
        panel.canCreateDirectories = true
        if let jsonType = UTType(filenameExtension: "json") {
            panel.allowedContentTypes = [jsonType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            engine.showHUD(chord: "!", title: error.localizedDescription)
        }
    }

    private func appDisplayName(for bundleID: String) -> String {
        if bundleID == "*" { return localization.text(.statsGenericApp) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.infoDictionary?["CFBundleName"] as? String {
            return name
        }
        return bundleID
    }

    // MARK: - Helpers

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }
}

private struct UpdateCheckRow: View {
    @ObservedObject var checker: UpdateChecker
    @EnvironmentObject private var localization: Localization
    let currentVersion: String

    var body: some View {
        LabeledContent(localization.text(.updateCheck)) {
            HStack(spacing: 10) {
                status
                Button(localization.text(.updateCheck)) {
                    checker.check(currentVersion: currentVersion)
                }
                .disabled(checker.state == .checking)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch checker.state {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Text(localization.text(.updateNone))
                .foregroundStyle(.secondary)
        case let .available(version, url):
            Button(localization.format(.updateAvailable, version)) {
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.link)
        case .failed:
            Text(localization.text(.updateFailed))
                .foregroundStyle(.orange)
        }
    }
}

enum SettingsTab: String, CaseIterable {
    case general, trigger, appearance, statistics, conflicts, permissions, diagnostics, about

    var titleKey: L10nKey {
        switch self {
        case .general: return .generalTitle
        case .trigger: return .triggerTitle
        case .appearance: return .appearanceTitle
        case .statistics: return .statisticsTitle
        case .conflicts: return .conflictTitle
        case .permissions: return .permissionTitle
        case .diagnostics: return .diagnosticsTitle
        case .about: return .aboutTitle
        }
    }
}

/// The add sheet for an ignored command: choose the scope, then the command.
///
/// The suggestion list is what KagiPeek has already read for that app — the frontmost
/// catalog, or the disk cache behind it. It is a convenience, not a requirement: the title
/// field accepts anything, which is what makes the feature work for an app that is not
/// running (and therefore cannot be scanned) and for a command that appeared a minute ago.
private struct IgnoreCommandSheet: View {
    let runningApps: [AppEntry]
    let localization: Localization
    let suggestionsFor: (AppEntry, @escaping ([String]) -> Void) -> Void
    let onAdd: (IgnoredCommand) -> Void
    let onCancel: () -> Void

    @State private var scopeIsGlobal = true
    @State private var selectedAppID: String?
    @State private var title = ""
    @State private var suggestions: [String] = []
    @State private var loading = false

    private var selectedApp: AppEntry? {
        runningApps.first { $0.id == selectedAppID }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSuggestions: [String] {
        let needle = trimmedTitle.lowercased()
        let matching = needle.isEmpty
            ? suggestions
            : suggestions.filter { $0.lowercased().contains(needle) }
        return Array(matching.prefix(80))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localization.text(.ignoredSheetTitle))
                .font(.headline)

            Picker("", selection: $scopeIsGlobal) {
                Text(localization.text(.ignoredScopeGlobal)).tag(true)
                Text(localization.text(.ignoredScopeApp)).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !scopeIsGlobal {
                Picker(localization.text(.ignoredAppPicker), selection: $selectedAppID) {
                    Text("—").tag(String?.none)
                    ForEach(runningApps) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                .onChange(of: selectedAppID) { _, _ in loadSuggestions() }
            }

            LabeledContent(localization.text(.ignoredCommandTitle)) {
                TextField(localization.text(.ignoredCommandPlaceholder), text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            if loading {
                ProgressView().controlSize(.small)
            } else if !filteredSuggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredSuggestions, id: \.self) { suggestion in
                            Button {
                                title = suggestion
                            } label: {
                                Text(suggestion)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 140)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.8)
                )
            }

            Text(localization.text(.ignoredSuggestionsHint))
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(localization.text(.ignoredCancel)) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(localization.text(.ignoredAdd)) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty || (!scopeIsGlobal && selectedApp == nil))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func loadSuggestions() {
        guard let app = selectedApp else {
            suggestions = []
            return
        }
        loading = true
        suggestionsFor(app) { titles in
            suggestions = titles
            loading = false
        }
    }

    private func add() {
        let command = IgnoredCommand(
            title: trimmedTitle,
            appBundleID: scopeIsGlobal ? nil : selectedApp?.bundleID
        )
        onAdd(command)
    }
}

/// The app icon is a real drag source: drop it into the Accessibility list in System Settings.
private struct DragAppIcon: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 40, height: 40)
            .onDrag {
                NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider()
            }
            .help("Drag into System Settings")
    }
}
