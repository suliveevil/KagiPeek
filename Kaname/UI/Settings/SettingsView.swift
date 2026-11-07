import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @Environment(EngineState.self) private var state
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var usageStore: UsageStore
    @EnvironmentObject private var localization: Localization

    private var settings: AppSettingsSnapshot { store.settings }

    /// The conflict filters are the only two pieces of engine state this window writes.
    /// Observation has no projected value, so they get explicit bindings.
    private var conflictCategorySelection: Binding<ConflictCategory?> {
        Binding(
            get: { state.conflictCategory },
            set: { state.conflictCategory = $0 }
        )
    }

    private var conflictOwnerSelection: Binding<ConflictOwnerFilter> {
        Binding(
            get: { state.conflictOwner },
            set: { state.conflictOwner = $0 }
        )
    }

    @State private var tab: SettingsTab = .general
    /// Selected row in the excluded-apps list. Selection, not a text cursor: an app is
    /// removed by pointing at it, the same way the Finder works.
    @State private var excludedSelection: String?
    /// Whether that list owns the keyboard. Clicking a row moves focus here so Delete does
    /// what the row already looks selected for.
    @FocusState private var excludedListFocused: Bool
    @State private var showIgnoreSheet = false
    /// Which ignored-command groups are open. The global group starts open; app groups open
    /// when a rule is added to them.
    @State private var expandedScopes: Set<String> = ["*"]
    /// How many findings the Conflicts page draws. Raised by the "show more" button.
    @State private var findingPageSize = SettingsView.findingPageStep
    @State private var confirmResetUsage = false
    @State private var confirmRestoreDefaults = false
    /// Layout controls most users touch once, if at all. The two that change everyday
    /// appearance — theme and column count — stay outside the disclosure.
    @State private var showLayoutDetails = false
    /// Diagnostics are a one-time or bug-report-only group: they sit at the end of General,
    /// folded away, instead of claiming a sidebar row of their own.
    @State private var showDiagnostics = false
    private static let findingPageStep = 40
    private let onTabChange: ((SettingsTab) -> Void)?
    /// Lets the preview harness open a specific tab (e.g. `KANAME_PREVIEW=settings-ranking`).
    /// `onTabChange` is how the hosting window keeps its title on the visible pane without
    /// lifting the whole selection state out of the view.
    /// `expandDiagnostics` lets `KANAME_PREVIEW=settings-diagnostics` capture the folded
    /// group open, since the mode no longer maps to a tab of its own.
    init(
        initialTab: SettingsTab = .general,
        onTabChange: ((SettingsTab) -> Void)? = nil,
        expandDiagnostics: Bool = false
    ) {
        _tab = State(initialValue: initialTab)
        _showDiagnostics = State(initialValue: expandDiagnostics)
        self.onTabChange = onTabChange
    }

    var body: some View {
        // A sidebar, not a segmented picker: at 680 pt each segment had about 80 pt,
        // which already crowded the longest label and would have broken at the first
        // word longer than it. Seven pages cannot share one row; a list holds them, and
        // it is the shape macOS 14 users expect from a settings window.
        NavigationSplitView {
            // `List` selection is optional by default; this window always shows one page, so
            // clearing the selection is ignored instead of blanking the detail column.
            List(selection: tabSelection) {
                ForEach(SettingsTab.allCases, id: \.self) { item in
                    Label(localization.text(item.titleKey), systemImage: item.symbolName)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 240)
            // The list is the only navigation, so a collapsed sidebar would be an empty
            // window with no way back. The window is resizable; that is enough control.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // The page content is unchanged: only the container around it moved.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        // 720, not the 680 it was: the sidebar takes 188 of it, and the widest fixed row
        // in the pages — the English permission row, "Input Monitoring" + "Not granted" +
        // "Request" + "Open System Settings" — measures 429 pt. A 531 pt detail column
        // leaves 102 pt for the grouped form's insets (about 20–25 a side) and a margin;
        // at 680 the detail is 491 and that row clips as soon as the inset reaches 30 a
        // side, which is where a system font with wider metrics puts it.
        .frame(minWidth: 720, minHeight: 600)
        .background(Theme.surface)
        .environmentObject(localization)
        .onAppear {
            engine.closeSurfaces()
        }
    }

    private var tabSelection: Binding<SettingsTab?> {
        Binding(
            get: { tab },
            set: { if let selected = $0 { tab = selected; onTabChange?(selected) } }
        )
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
        case .about: aboutTab
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            // Every other group on this page has a heading; the first one did not, so the
            // page had two rhythms.
            Section(localization.text(.generalBehaviorSection)) {
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

                // Three-state status dots at the head of each panel row — green, amber,
                // red. Off leaves the slot reserved but empty, so toggling never reflows
                // the list. The row-end conflict badge is unrelated and always stays on.
                Toggle(
                    localization.text(.settingsAutoAuditUnreachable),
                    isOn: $store.settings.autoAuditUnreachableShortcuts
                )
                Text(localization.text(.settingsAutoAuditHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle(localization.text(.generalShowDockIcon), isOn: $store.settings.showDockIcon)
                Text(localization.text(.generalShowDockIconHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

                Divider()

                Text(localization.text(.rowActionPagingTitle))
                    .font(.headline)
                ForEach(PagingPair.allCases, id: \.self) { pair in
                    Toggle(
                        localization.text(pair.titleKey),
                        isOn: pagingPairBinding(pair)
                    )
                }
                Text(localization.text(.rowActionPagingHint))
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

                // Both switches decide what the scan is allowed to see, so they belong
                // beside the ignore list rather than in the behaviour card.
                Divider()

                Toggle(localization.text(.rankingIncludeBuiltIn), isOn: $store.settings.includeBuiltInCatalog)
                Toggle(localization.text(.generalShowAppleMenu), isOn: $store.settings.showAppleMenu)
                Text(localization.text(.generalShowAppleMenuHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup(isExpanded: $showDiagnostics) {
                    diagnosticsContent
                } label: {
                    Label(localization.text(.diagnosticsTitle), systemImage: "stethoscope")
                }
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
                // Delete needs a first responder. A `ScrollView` does not take focus on its
                // own, so it is made focusable here and the rows hand it focus when they are
                // clicked: pointing at an app is still the only way to select one, and the
                // press is also the moment a keyboard shortcut becomes useful.
                .focusable()
                .focused($excludedListFocused)
                .onDeleteCommand { removeSelectedExcludedApp() }
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            excludedSelection = bundleID
            excludedListFocused = true
        }
        // A row is the thing that gets selected, so VoiceOver has to be able to make that
        // selection too — otherwise Delete, and the "−" button beside it, can be reached
        // from the keyboard but never armed.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { excludedSelection = bundleID }
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
        AppArtworkCache.icon(for: bundleID)
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
                                // `.help` is a tooltip for the mouse; VoiceOver never reads
                                // it. An icon-only button needs its own label or it is
                                // announced as "minus circle".
                                .accessibilityLabel(localization.text(.generalRemoveApp))
                                .help(localization.text(.generalRemoveApp))
                            }
                        }
                    } label: {
                        Text(scopeTitle(for: scope))
                            .font(.system(size: TypeScale.callout, weight: .semibold))
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
            // Two independent paths, one card each: the gesture and the three hotkeys. Either
            // one can be live, both can, and both off is the pause state. The switch that
            // turns a card on sits in its header, immediately left of the title.
            Section {
                HStack(spacing: 8) {
                    Picker(localization.text(.triggerGesture), selection: $store.settings.triggerGesture) {
                        ForEach(TriggerGesture.allCases, id: \.self) { gesture in
                            Text(localization.text(gesture.titleKey)).tag(gesture)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)

                    Picker(localization.text(.triggerKey), selection: $store.settings.triggerKey) {
                        ForEach(TriggerKey.allCases, id: \.self) { key in
                            Text(localization.text(key.titleKey)).tag(key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)

                    Spacer(minLength: 0)
                }
                .disabled(!settings.modifierTriggerEnabled)

                LabeledContent(localization.text(.triggerHoldDelay)) {
                    HStack {
                        Slider(value: $store.settings.holdDelay, in: 0.3...0.9, step: 0.1)
                        Text(String(format: "%.2fs", settings.holdDelay))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                .disabled(!settings.modifierTriggerEnabled || settings.triggerGesture != .hold)
            } header: {
                triggerSectionHeader(title: .triggerModifierGesture,
                                     isOn: $store.settings.modifierTriggerEnabled)
            }

            Section {
                Group {
                    hotkeyRow(title: localization.text(.triggerPanelHotkey), target: .panel, spec: settings.panelHotkey)
                    hotkeyRow(title: localization.text(.triggerSearchHotkey), target: .search, spec: settings.searchHotkey)
                    hotkeyRow(title: localization.text(.triggerSwitchHotkey), target: .switcher, spec: settings.switchHotkey)
                }
                .disabled(!settings.hotkeyTriggerEnabled)
            } header: {
                triggerSectionHeader(title: .triggerGlobalHotkey,
                                     isOn: $store.settings.hotkeyTriggerEnabled)
            }

            // Karabiner rewrites the keyboard below the tap, so a rule bound to the trigger key
            // keeps firing while the panel is up. This switch is the one channel that lets
            // such a rule stand down; see `KarabinerPanelSignal`.
            //
            // The switch sits in the header like the other two on this tab: it is the card's
            // on/off, and the body is the explanation plus the one condition the user's own
            // Karabiner rule needs.
            Section {
                Text(localization.text(.triggerKarabinerSignalNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !KarabinerBridge.isInstalled {
                    Text(localization.text(.triggerKarabinerSignalMissing))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                triggerSectionHeader(title: .triggerKarabinerSignal,
                                     isOn: $store.settings.karabinerPanelSignalEnabled)
            }
        }
        .formStyle(.grouped)
    }

    /// A section header with its on/off switch immediately left of the title.
    ///
    /// The switch is the header's only accessibility element: the visible title is hidden
    /// from VoiceOver and folded into the switch's label, so a card is announced as
    /// "Enable Modifier triggers, switch, on" and then read once, not twice.
    private func triggerSectionHeader(
        title: L10nKey,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .accessibilityLabel(
                    localization.format(.triggerEnableAccessibility,
                                        localization.text(title))
                )

            Text(localization.text(title))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A whole number typed into a fixed-width field.
    ///
    /// Return and losing focus both commit. A value that is not a bare integer inside the
    /// range is not clamped into range: the field restores the value that was already in
    /// effect and says so for three seconds, so a typo cannot silently become a setting.
    private struct NumericSettingRow: View {
        let title: L10nKey
        @Binding var value: Int
        let range: ClosedRange<Int>

        @EnvironmentObject private var localization: Localization
        @State private var draft = ""
        @State private var showsInvalid = false
        @State private var dismissInvalid: Task<Void, Never>?
        @FocusState private var focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(localization.text(title)) {
                    TextField("", text: $draft)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 56)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused { commit() }
                        }
                        .onChange(of: draft) { _, newDraft in
                            // Editing again retracts the warning; restoring the previous
                            // value in `commit` must not retract it, hence the comparison.
                            if showsInvalid, newDraft != String(value) {
                                clearInvalid()
                            }
                        }
                        .accessibilityLabel(localization.text(title))
                }

                if showsInvalid {
                    Text(localization.format(.appearanceNumberInvalidFormat,
                                             range.lowerBound, range.upperBound, value))
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                }
            }
            .onAppear { draft = String(value) }
            .onChange(of: value) { _, newValue in
                if !focused { draft = String(newValue) }
            }
        }

        private func commit() {
            if let parsed = NumericSettingInput.value(from: draft, in: range) {
                value = parsed
                draft = String(parsed)
                clearInvalid()
            } else {
                draft = String(value)
                showsInvalid = true
                dismissInvalid?.cancel()
                dismissInvalid = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    showsInvalid = false
                }
            }
        }

        private func clearInvalid() {
            showsInvalid = false
            dismissInvalid?.cancel()
            dismissInvalid = nil
        }
    }

    /// A checkbox over the set: enabling one pair leaves the others alone, and unchecking the
    /// last pair is allowed (the arrows still page).
    private func pagingPairBinding(_ pair: PagingPair) -> Binding<Bool> {
        Binding(
            get: { store.settings.pagingPairs.contains(pair) },
            set: { enabled in
                var pairs = store.settings.pagingPairs
                if enabled { pairs.insert(pair) } else { pairs.remove(pair) }
                store.settings.pagingPairs = pairs
            }
        )
    }

    private func hotkeyRow(title: String, target: HotkeyTarget, spec: HotkeySpec?) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if state.recordingTarget == target {
                    Text(localization.text(.triggerRecordingHint))
                        .foregroundStyle(.orange)
                } else if let spec {
                    KeycapView(text: KeyFormatter.render(spec.chord, style: settings.keyStyle), compact: true)
                } else {
                    Text(localization.text(.triggerUnset))
                        .foregroundStyle(.secondary)
                }
                Button(state.recordingTarget == target
                       ? localization.text(.triggerStopRecording)
                       : localization.text(.triggerRecording)) {
                    if state.recordingTarget == target {
                        engine.cancelRecording()
                    } else {
                        engine.beginRecording(target)
                    }
                }
                Button {
                    engine.clearBinding(target)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(localization.text(.triggerClear))
                .help(localization.text(.triggerClear))
                .disabled(spec == nil || state.recordingTarget == target)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        Form {
            Section(localization.text(.appearanceLayoutSection)) {
                Picker(localization.text(.appearanceTheme), selection: $store.settings.panelTheme) {
                    ForEach(PanelTheme.allCases, id: \.self) { theme in
                        Text(localization.text(theme.titleKey)).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Picker(localization.text(.appearanceColumns), selection: $store.settings.columnCount) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)

                // Five segmented rows in a column is the bulk of this page, and only the
                // theme and the column count are changed with any regularity. The rest keep
                // their labels and controls; the disclosure just stops them from competing
                // with the two that matter.
                DisclosureGroup(isExpanded: $showLayoutDetails) {
                    Picker(localization.text(.appearanceKeyStyle), selection: $store.settings.keyStyle) {
                        ForEach(KeyFormatter.Style.allCases, id: \.self) { style in
                            Text(localization.text(style.l10nKey)).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker(localization.text(.appearanceKeyPosition), selection: $store.settings.keyPosition) {
                        ForEach(KeyPosition.allCases, id: \.self) { position in
                            Text(localization.text(position.titleKey)).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker(localization.text(.appearancePanelOrder), selection: $store.settings.panelOrder) {
                        ForEach(PanelSortOrder.allCases, id: \.self) { order in
                            Text(localization.text(order.titleKey)).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)

                    NumericSettingRow(title: .appearanceMaxItems,
                                      value: $store.settings.maxItemsPerPage,
                                      range: AppSettingsSnapshot.maxItemsPerPageRange)

                    NumericSettingRow(title: .appearanceMaxDescription,
                                      value: $store.settings.maxDescriptionLength,
                                      range: AppSettingsSnapshot.maxDescriptionLengthRange)

                    Toggle(localization.text(.appearanceShowDisabled), isOn: $store.settings.showDisabledItems)

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
                } label: {
                    Text(localization.text(.appearanceLayoutAdvanced))
                }
            }

            // Favourites are a preference about the panel's list, not about its layout, so
            // they get their own card instead of trailing the last layout row.
            Section(localization.text(.appearanceFavoritesSection)) {
                Toggle(localization.text(.favoritesPinTop), isOn: $store.settings.pinFavoritesToTop)
                Toggle(localization.text(.favoritesFilterable), isOn: $store.settings.favoritesCanBeFiltered)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Statistics

    /// One flat list, one line per usage key, ordered by the field the picker names.
    ///
    /// Rows are not grouped by app any more: the shortcut comes first, and the app and the
    /// command are the note underneath it, because "which key was that" is the question this
    /// page exists to answer. The conflicts tab answers a different question and has its own
    /// page.
    private var statisticsTab: some View {
        Form {
            Section {
                LabeledContent(localization.text(.statsSortField)) {
                    Picker("", selection: $store.settings.usageSortField) {
                        ForEach(UsageSortField.allCases, id: \.self) { field in
                            Text(localization.text(field.titleKey)).tag(field)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section(localization.text(.statsSection)) {
                Text(localization.format(.rankingUsageSummary, usageStore.trackedCount, usageStore.totalPresses))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                let entries = UsageSorting.entries(
                    engine.usageEntries(),
                    by: settings.usageSortField,
                    appName: { appDisplayName(for: $0) }
                )
                if entries.isEmpty {
                    Text(localization.text(.statsNoData))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        usageRow(entry)
                    }
                }

                Button(localization.text(.statsOpenDataFolder)) {
                    NSWorkspace.shared.open(usageStore.dataFolderURL)
                }
                Button(localization.text(.rankingReset)) {
                    confirmResetUsage = true
                }
                .disabled(usageStore.totalPresses == 0)
                .confirmationDialog(
                    localization.text(.rankingResetConfirmTitle),
                    isPresented: $confirmResetUsage,
                    titleVisibility: .visible
                ) {
                    Button(localization.text(.rankingReset), role: .destructive) {
                        engine.resetUsage()
                    }
                    Button(localization.text(.ignoredCancel), role: .cancel) {}
                } message: {
                    Text(localization.text(.rankingResetConfirmMessage))
                }
            }

            Button(localization.text(.rankingDefaults), role: .destructive) {
                confirmRestoreDefaults = true
            }
            .confirmationDialog(
                localization.text(.rankingDefaultsConfirmTitle),
                isPresented: $confirmRestoreDefaults,
                titleVisibility: .visible
            ) {
                Button(localization.text(.rankingDefaults), role: .destructive) {
                    store.resetToDefaults()
                    engine.invalidateScanCaches()
                }
                Button(localization.text(.ignoredCancel), role: .cancel) {}
            } message: {
                Text(localization.text(.rankingDefaultsConfirmMessage))
            }
        }
        .formStyle(.grouped)
    }

    /// Shortcut first, then the command and the app it belongs to as a note, then the count.
    ///
    /// A row whose title is missing is still worth showing: the count is true, and the
    /// shortcut is recovered from the usage key. Saying "not scanned" is more useful than
    /// hiding a command the user clearly pressed.
    private func usageRow(_ entry: UsageEntry) -> some View {
        let owner = UsageStatistics.bundleID(fromUsageKey: entry.usageKey)
        let renderedChord = entry.chord.map { KeyFormatter.render($0, style: settings.keyStyle) }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(renderedChord ?? "—")
                .font(.system(size: TypeScale.caption, design: .monospaced))
                .foregroundStyle(entry.isShortcutless ? .secondary : .primary)
                .frame(width: 76, alignment: .leading)
                // The dash is the column's word for "this command has no shortcut";
                // VoiceOver would read the glyph itself, so the label says the same thing
                // in words. "Not set" is the app's existing word for an unassigned key.
                .accessibilityLabel(renderedChord ?? localization.text(.triggerUnset))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? localization.text(.statsUnknownCommand))
                    .font(.caption)
                    .foregroundStyle(entry.title == nil ? .secondary : .primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let icon = appIcon(for: owner) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    Text(appDisplayName(for: owner))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
            Text("\(entry.presses)")
                .font(.caption)
                .monospacedDigit()
        }
        .padding(.vertical, 1)
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
                    Picker("", selection: conflictCategorySelection) {
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
                    Picker("", selection: conflictOwnerSelection) {
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
                        if let issue = conflictScanIssueText {
                            Text("·").font(.caption).foregroundStyle(.secondary)
                            Text(issue)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button(localization.text(.conflictRescan)) {
                        engine.rescanCrossAppConflicts()
                    }
                    .controlSize(.small)
                    .disabled(state.isScanningCrossApp)
                }

                if state.visibleConflicts.isEmpty {
                    Text(conflictEmptyMessage)
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

    /// `DateFormatter` construction is expensive enough that building one per body
    /// evaluation shows up in the Conflicts tab's scroll, so the tab reuses one.
    private static let scanTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var scanTimestampText: String {
        guard let scannedAt = state.crossAppScannedAt else {
            return localization.text(.conflictNeverScanned)
        }
        return localization.format(.conflictScannedAtFormat, Self.scanTimestampFormatter.string(from: scannedAt))
    }

    private var conflictScanIssueText: String? {
        switch state.crossAppScanState {
        case .failed:
            return localization.text(.conflictScanFailed)
        case .partial(let failed):
            return localization.format(.conflictScanPartialFormat, failed)
        default:
            return nil
        }
    }

    private var conflictEmptyMessage: String {
        if state.isScanningCrossApp || state.crossAppScanState == .scanning {
            return localization.text(.conflictScanning)
        }
        if let issue = conflictScanIssueText { return issue }
        if !state.crossAppConflicts.isEmpty {
            return localization.text(.conflictTypeEmpty)
        }
        if state.crossAppScannedAt == nil {
            return localization.text(.conflictNeverScanned)
        }
        return localization.text(.conflictNone)
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

            Toggle(
                localization.text(.configToolsShowInPanel),
                isOn: $store.settings.showConfigToolsInPanel
            )
            Text(localization.text(.configToolsShowInPanelNote))
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
                LabeledContent(localization.text(.statusLabel)) {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: TypeScale.callout, weight: .semibold))
                Text(granted ? localization.text(.permissionGranted) : localization.text(.permissionMissing))
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .padding(.horizontal, 8)
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
                HStack(spacing: 12) {
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
    ///
    /// It is one folded group at the end of General rather than a page of its own: every
    /// control here is a one-time choice or something only a bug report needs, and a sidebar
    /// row made diagnostics look as everyday as theme and hotkeys.
    @ViewBuilder
    private var diagnosticsContent: some View {
        Toggle(localization.text(.diagnosticsEnable), isOn: $store.settings.diagnosticsEnabled)
        Text(localization.text(.diagnosticsEnableHint))
            .font(.footnote)
            .foregroundStyle(.secondary)

        Toggle(localization.text(.diagnosticsVerbose), isOn: $store.settings.verboseDiagnostics)
            .disabled(!settings.diagnosticsEnabled)
        Text(localization.text(.diagnosticsVerboseHint))
            .font(.footnote)
            .foregroundStyle(.secondary)

        Divider()

        // The three former sections stay distinguishable after the flattening: a heading row
        // each, separated by a rule, the same shape the General page already uses.
        Text(localization.text(.diagnosticsPath))
            .font(.headline)
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

        Divider()

        Text(localization.text(.aboutDiagnostics))
            .font(.headline)
        LabeledContent(localization.text(.permissionAccessibility)) {
            permissionMark(state.hasAccessibility)
        }
        LabeledContent(localization.text(.permissionInputMonitoring)) {
            permissionMark(state.hasInputMonitoring)
        }
        LabeledContent(localization.text(.statusLabel)) {
            Text(state.isListening ? localization.text(.statusReady) : localization.text(.statusNoPermission))
        }
        LabeledContent(localization.text(.aboutMenuItems)) {
            Text("\(state.catalogSize)").monospacedDigit()
        }
        LabeledContent(localization.text(.diagnosticsDoubleTapWindow)) {
            Text(String(
                format: "%.2fs",
                DoubleTapTiming.window(systemDoubleClickInterval: NSEvent.doubleClickInterval)
            ))
            .monospacedDigit()
        }
        Text(localization.text(.diagnosticsDoubleTapWindowHint))
            .font(.footnote)
            .foregroundStyle(.secondary)
        Button(localization.text(.aboutExportDiagnostics)) {
            exportDiagnostics()
        }
        Text(localization.text(.aboutDiagnosticsHint))
            .font(.footnote)
            .foregroundStyle(.secondary)

        Divider()

        Text(localization.text(.diagnosticsPrivacyNote))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var logFolderURL: URL {
        DataDirectory.url(for: "logs")
    }

    /// A permission state drawn as a bare glyph.
    ///
    /// "✓" and "—" are the element's entire content, so VoiceOver reads "check mark" or
    /// "em dash" and never the state itself. The glyph stays — the column is meant to be
    /// scanned down — and the label supplies the two words the Permissions page already
    /// uses next to its coloured capsule.
    private func permissionMark(_ granted: Bool) -> some View {
        Text(granted ? "✓" : "—")
            .accessibilityLabel(localization.text(granted ? .permissionGranted : .permissionMissing))
    }

    /// Writes the archive the user picked a destination for.
    ///
    /// The copy and the `ditto` run happen on a background queue: the destination can be a
    /// slow network volume, and a save panel that has already closed must not freeze the
    /// window while the archive is built.
    private func exportLogArchive() {
        guard let url = ExportPanel.run(defaultName: DiagnosticsExporter.defaultFileName(), pathExtension: "zip") else { return }
        let snapshot = settings
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try DiagnosticsExporter.export(to: url, settings: snapshot)
                DispatchQueue.main.async {
                    engine.showHUD(chord: "", title: localization.text(.diagnosticsExportDone))
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    engine.showHUD(
                        chord: "!",
                        title: localization.format(.diagnosticsExportFailed, message),
                        kind: .failure
                    )
                }
            }
        }
    }

    /// Writes the report the Diagnostics tab shows, plus the settings snapshot, to a file the
    /// user can attach to a bug report.
    ///
    /// Both failures now end the same way. They used not to: a failed serialization returned
    /// `nil` and the button just looked dead, while the failed write right below it showed a
    /// HUD. The wording and the HUD chord match the other export path in this file.
    ///
    /// The log line is not redundant with the HUD: when this fails there is **no file**, so
    /// the log is the only durable trace. A HUD disappears and leaves nothing to attach.
    ///
    /// The save panel comes first. Building the report reads the scan state and the settings
    /// snapshot, and doing that before the user has picked a destination meant a cancelled
    /// save paid for work that was immediately thrown away — the archive export above has
    /// always asked first.
    private func exportDiagnostics() {
        guard let url = ExportPanel.run(defaultName: "kaname-diagnostics.json", pathExtension: "json") else { return }
        do {
            let data = try engine.diagnosticsReport()
            try data.write(to: url, options: [.atomic])
        } catch {
            Diag.error(.ui, "diagnostics export failed: \(error.localizedDescription)")
            engine.showHUD(
                chord: "!",
                title: localization.format(.diagnosticsExportFailed, error.localizedDescription),
                kind: .failure
            )
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localization.text(.appName))
                            .font(.system(size: IconScale.large, weight: .semibold))
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
                    Link("suliveevil/kaname", destination: URL(string: "https://github.com/suliveevil/kaname")!)
                }
                LabeledContent(localization.text(.aboutLicense)) {
                    Text("GNU GPL v2.0").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func appDisplayName(for bundleID: String) -> String {
        if bundleID == "*" { return localization.text(.statsGenericApp) }
        return AppArtworkCache.displayName(for: bundleID) ?? bundleID
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.kanameVersionDisplay
    }
}

private struct UpdateCheckRow: View {
    @ObservedObject var checker: UpdateChecker
    @EnvironmentObject private var localization: Localization
    let currentVersion: String

    var body: some View {
        LabeledContent(localization.text(.updateCheck)) {
            HStack(spacing: 12) {
                status
                Button(localization.text(.updateCheckNow)) {
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(localization.text(.updateChecking))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
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
    case general, trigger, appearance, statistics, conflicts, permissions, about

    var titleKey: L10nKey {
        switch self {
        case .general: return .generalTitle
        case .trigger: return .triggerTitle
        case .appearance: return .appearanceTitle
        case .statistics: return .statisticsTitle
        case .conflicts: return .conflictTitle
        case .permissions: return .permissionTitle
        case .about: return .aboutTitle
        }
    }

    /// The sidebar glyph. Symbol names, not text: they carry no wording and so need no
    /// localization. Each one already means the same thing elsewhere in the app —
    /// `gearshape` is Settings in the menu bar, `lock.shield` is the permission guide.
    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .trigger: return "keyboard"
        case .appearance: return "paintbrush"
        case .statistics: return "chart.bar"
        case .conflicts: return "exclamationmark.triangle"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

/// The add sheet for an ignored command: choose the scope, then the command.
///
/// The suggestion list is what Kaname has already read for that app — the frontmost
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
                    // The empty choice is a dash: it means "nothing picked yet", and the
                    // dash is read as "em dash" rather than as that meaning.
                    Text("—")
                        .tag(String?.none)
                        .accessibilityLabel(localization.text(.triggerUnset))
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
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 140)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
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

/// `NSWorkspace` and `Bundle` lookups are disk hits, and the settings lists call them per
/// row and per render. A bundle identifier's icon and display name do not change while the
/// app runs, so the answers are memoised for the process lifetime (negatives included).
@MainActor
private enum AppArtworkCache {
    private static var icons: [String: NSImage?] = [:]
    private static var names: [String: String?] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID], let cached { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            icons[bundleID] = NSImage?.none
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = .some(icon)
        return icon
    }

    static func displayName(for bundleID: String) -> String? {
        if let cached = names[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url),
              let name = bundle.infoDictionary?["CFBundleName"] as? String else {
            names[bundleID] = .some(nil)
            return nil
        }
        names[bundleID] = .some(name)
        return name
    }
}
