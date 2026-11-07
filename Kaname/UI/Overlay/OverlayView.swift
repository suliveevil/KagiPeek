import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One surface for both the shortcut panel and the search palette.
///
/// They share the window, the title bar (App identity, one search field, actions)
/// and the footer; only the content below the bar swaps. The panel's filter uses the
/// event tap (the panel never takes focus), while the search palette focuses a real
/// text field because its window is allowed to become key.
///
/// The surface is deliberately a shell. The four areas below (`OverlayHeaderView`,
/// `OverlayPanelContentView`, `OverlaySearchContentView`, `OverlayFooterView`) each
/// subscribe to their own slice of `EngineState`, so a rebuild in one area — a
/// selection move, a countdown tick, a search result change — invalidates only the
/// views that read it, not the whole tree.
struct OverlayView: View {
    @Environment(EngineState.self) private var state
    @EnvironmentObject private var settingsStore: SettingsStore
    /// The window's effectiveAppearance, expressed for SwiftUI: `system` themes follow it.
    @Environment(\.colorScheme) private var systemColorScheme

    private var settings: AppSettingsSnapshot { settingsStore.settings }
    private var palette: PanelPalette {
        settings.panelTheme.palette(isDarkSystem: systemColorScheme == .dark)
    }
    private var isSearch: Bool { state.search.isVisible }

    /// The panel's material, kept on the shell so the content area cannot accidentally
    /// paint its own layer over the header and footer.
    ///
    /// `popover` for the light theme and `hudWindow` for the dark one are AppKit visual
    /// effect materials; SwiftUI's `Material` has no equivalents. The palette tint sits on
    /// top so the contrast ratios the text was tuned against do not move with the wallpaper.
    /// Reduce Transparency replaces the whole thing with a solid fill.
    @ViewBuilder
    private var panelSurface: some View {
        if Theme.reduceTransparency {
            palette.backgroundSolid
        } else {
            PanelSurfaceView(material: palette.isLight ? .popover : .hudWindow)
                .overlay(palette.backgroundSolid.opacity(palette.isLight ? 0.35 : 0.45))
        }
    }

    var body: some View {
        // The footer is a sibling of the content, never a layer over it: the content takes
        // the panel height minus the header, the rule and the footer, so no menu item can
        // end up underneath the hint bar. The same three numbers live in `OverlayMetrics`.
        VStack(alignment: .leading, spacing: 0) {
            OverlayHeaderView()
            Rectangle()
                .fill(palette.rule)
                .frame(height: OverlayMetrics.ruleHeight)
            if isSearch {
                OverlaySearchContentView()
            } else {
                OverlayPanelContentView()
            }
            OverlayFooterView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Material follows the theme: a light popover reads as paper, a dark HUD as glass.
        // The palette tint stays on top so the contrast ratios the text was tuned against
        // do not move when the wallpaper does. Reduce Transparency keeps the solid colour.
        .background(panelSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(palette.border, lineWidth: Theme.increaseContrast ? 1.5 : 0.8)
                .decorative()
        )
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
    }
}

// MARK: - Title bar

/// The shared title bar: App identity, the search field (when the palette is up), the
/// modifier chips and favorites toggle (when the panel is up), the scan/conflict
/// indicators and the count, plus the close button. Reads only the header's slice of
/// state (`search.*`, `appName`/`appIcon`, `panel.isScanning`/`hasConflicts`/
/// `appName`/`prefixLabels`, `pending.effective` and `panel.latchedModifiers` for the
/// chips, `showsFavoritesOnly`, `runningApps`), so a row-selection or results change
/// elsewhere does not redraw it.
private struct OverlayHeaderView: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @Environment(EngineState.self) private var state
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var localization: Localization
    @Environment(\.colorScheme) private var systemColorScheme
    @FocusState private var searchFocused: Bool

    private var settings: AppSettingsSnapshot { settingsStore.settings }
    private var palette: PanelPalette {
        settings.panelTheme.palette(isDarkSystem: systemColorScheme == .dark)
    }
    private var isSearch: Bool { state.search.isVisible }

    /// Observation has no projected value, so the text field gets an explicit binding to
    /// the one field it writes.
    private var searchQuery: Binding<String> {
        Binding(
            get: { state.search.query },
            set: { state.search.query = $0 }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            headerContent(layout: HeaderLayout(width: proxy.size.width))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: OverlayMetrics.headerHeight)
        .onAppear {
            if isSearch {
                DispatchQueue.main.async { searchFocused = true }
            }
        }
        .onChange(of: state.searchFocusToken) { _, _ in
            if isSearch { searchFocused = true }
        }
        .onChange(of: state.search.isVisible) { _, visible in
            if visible {
                DispatchQueue.main.async { searchFocused = true }
            } else {
                searchFocused = false
            }
        }
    }

    private func headerContent(layout: HeaderLayout) -> some View {
        HStack(spacing: 12) {
            headerIdentity(layout: layout)
            Spacer(minLength: 6)
            if isSearch {
                searchField(layout: layout)
            }
            Spacer(minLength: 6)
            headerActions(layout: layout)
        }
        .padding(.horizontal, 16)
    }

    /// What the list belongs to — plus the way back when the palette is the visible surface.
    private func headerIdentity(layout: HeaderLayout) -> some View {
        HStack(spacing: 12) {
            // The palette is a second view of the same window, so it gets a way back. `/`
            // does the same thing, but only while the search field is not taking text — and
            // it usually is.
            if isSearch {
                Button(action: engine.returnToPanelFromSearch) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: TypeScale.callout, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.controlHover, size: 28, cornerRadius: Theme.radiusControl))
                .help(localization.text(.searchBackToPanel))
                .accessibilityLabel(localization.text(.searchBackToPanel))
            }
            appIdentity(layout: layout)
        }
    }

    /// The quiet glyphs at the trailing edge: what is being looked at, then how to narrow it,
    /// then the two controls that leave this list.
    ///
    /// The search box itself is not here: the panel has no text field of its own any more —
    /// `/` opens the palette, which is where typing belongs. A second, quieter search box in
    /// the panel only asked the user to guess which one to use.
    private func headerActions(layout: HeaderLayout) -> some View {
        HStack(spacing: 12) {
            // Looking at another app and exporting what you see belong in the palette: it is
            // where the question is actually asked.
            if isSearch, layout != .minimal {
                searchScopeMenu
                Button { exportSearchMarkdown() } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: TypeScale.callout, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.controlHover, size: 28))
                .help(localization.text(.exportMarkdown))
                .accessibilityLabel(localization.text(.exportMarkdown))
            }

            if !isSearch, layout.showsModifierFilter {
                modifierChips
            }

            if !isSearch, layout.showsFavoritesToggle {
                Button(action: engine.toggleFavoritesFilter) {
                    Image(systemName: state.showsFavoritesOnly ? "star.fill" : "star")
                        .font(.system(size: TypeScale.body, weight: .semibold))
                        .foregroundStyle(state.showsFavoritesOnly ? Theme.favoriteStar : palette.secondaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.controlHover, size: 28))
                .help(localization.text(.panelFavoritesFilter))
                .accessibilityLabel(localization.text(.panelFavoritesFilter))
                // The filter's state is a filled, yellow star against an outline — colour
                // and a glyph shape, neither of which is spoken. The chip row above uses
                // the same trait for the same reason.
                .accessibilityAddTraits(state.showsFavoritesOnly ? .isSelected : [])
            }

            Button(action: engine.showSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: TypeScale.body, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
            }
            .buttonStyle(IconButtonStyle(hoverFill: palette.controlHover, size: 28))
            .help(localization.text(.panelSettings))
            .accessibilityLabel(localization.text(.panelSettings))

            statusIndicators(layout: layout)

            Button(action: dismissCurrentSurface) {
                Image(systemName: "xmark")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
            }
            .buttonStyle(IconButtonStyle(hoverFill: palette.controlHover, size: 28, cornerRadius: Theme.radiusControl))
            .help(localization.text(.panelClose))
            .accessibilityLabel(localization.text(.panelClose))
        }
    }

    /// The scan spinner, the conflict badge and the row count.
    ///
    /// The conflict badge is the one exception: it is a button that opens the Conflicts page,
    /// so a warning the user cannot act on does not become noise in a row of quiet glyphs.
    @ViewBuilder
    private func statusIndicators(layout: HeaderLayout) -> some View {
        if state.panel.isScanning {
            ProgressView().controlSize(.small).tint(palette.secondaryText)
        }
        if state.panel.hasConflicts {
            Button(action: engine.showConflicts) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: TypeScale.micro))
                    .foregroundStyle(Theme.warning.opacity(0.75))
            }
            .buttonStyle(IconButtonStyle(hoverFill: palette.controlHover, size: 22, cornerRadius: Theme.radiusControl))
            .help(localization.text(.overlayConflictOpen))
            .accessibilityLabel(localization.text(.overlayConflictOpen))
            .accessibilityHint(localization.text(.overlayConflictHint))
        }
        if layout.showsCount {
            // A bare "136" next to a warning triangle read as "136 conflicts"; the panel's
            // own total and the conflicts list then disagreed.
            Text(isSearch
                 ? "\(state.search.results.count)"
                 : localization.format(.overlayCountFormat, state.panel.totalCount))
                .font(.system(size: TypeScale.callout, weight: .medium, design: .rounded))
                .foregroundStyle(palette.secondaryText)
                .monospacedDigit()
        }
    }

    /// Checkable ⌃ ⌥ ⇧ ⌘ chips: a sticky way to narrow by modifier.
    ///
    /// Holding a modifier still narrows too (which-key style), but a held key returns to the
    /// full list the moment it is released. A tick does not: it survives, it is visible, and
    /// a tick plus a key composes a stroke. Several ticks mean "carries all of these".
    /// Either way the chip lights up while that modifier is narrowing the list, in step with
    /// the same glyph inside every row's chord.
    private var modifierChips: some View {
        HStack(spacing: 1) {
            ForEach(ModifierSet.canonicalOrder, id: \.rawValue) { modifier in
                modifierChip(modifier)
            }
        }
        .help(localization.text(.panelModifierFilterHint))
    }

    private func modifierChip(_ modifier: ModifierSet) -> some View {
        // The title bar lights up the same modifiers the rows do, from the same place:
        // `pending.effective` is what narrows the list, whether it got there by a held key
        // or by a clicked tick. Reading held/latched separately here used to leave a held
        // filter with lit glyphs in the rows but a merely "less grey" chip up top.
        // `ticked` still adds the outline that says this one is sticky, not just down.
        let active = state.pending.effective.contains(modifier)
        let ticked = state.panel.latchedModifiers.contains(modifier)
        return Button {
            engine.toggleModifier(modifier)
        } label: {
            Text(KeyFormatter.symbol(for: modifier))
                .font(.system(size: TypeScale.caption, weight: active ? .bold : .medium, design: .rounded))
                .foregroundStyle(active ? palette.keyHighlight : palette.secondaryText)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusTag, style: .continuous)
                        .fill(chipFill(ticked: ticked, active: active))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusTag, style: .continuous)
                        .stroke(ticked ? Color.accentColor.opacity(Theme.tickedChipStroke) : .clear, lineWidth: 1)
                        .decorative()
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.radiusTag, style: .continuous))
        }
        .buttonStyle(IconButtonStyle(hoverFill: palette.hover, size: 20, cornerRadius: Theme.radiusTag))
        .accessibilityLabel(KeyFormatter.word(for: modifier))
        // "Selected" means the sticky tick, not a key that happens to be down: VoiceOver
        // would otherwise announce a transient hold as a checked option.
        .accessibilityAddTraits(ticked ? [.isSelected] : [])
    }

    /// An active chip uses the row's highlight colour; a tick keeps its stronger fill and
    /// outline so "sticky" still reads differently from "down right now". Both are lit.
    private func chipFill(ticked: Bool, active: Bool) -> Color {
        guard active else { return .clear }
        return Color.accentColor.opacity(
            ticked
                ? (palette.isLight ? Theme.tickedChipFillLight : Theme.tickedChipFillDark)
                : (palette.isLight ? Theme.hintBadgeFillLight : Theme.hintBadgeFillDark)
        )
    }

    /// The app identity used to be a button that closed the surface, which made a mis-click
    /// on the icon silently dismiss the panel. It now only identifies; closing has its own
    /// button and still works by clicking outside or pressing Esc.
    private func appIdentity(layout: HeaderLayout) -> some View {
        HStack(spacing: 12) {
            if let icon = isSearch ? state.searchPaletteIcon : state.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
            }
            if layout.showsAppName || layout.showsSubtitle {
                VStack(alignment: .leading, spacing: 2) {
                    if layout.showsAppName {
                        Text(isSearch ? state.searchPaletteTitle : appTitle)
                            .font(.system(size: TypeScale.display, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(palette.text)
                    }
                    if layout.showsSubtitle {
                        subtitle
                    }
                }
            }
        }
    }

    private var appTitle: String {
        state.panel.appName.isEmpty ? localization.text(.appName) : state.panel.appName
    }

    @ViewBuilder
    private var subtitle: some View {
        if isSearch {
            Text(localization.text(state.search.scopeAppID == nil ? .searchSubtitle : .searchSubtitleScoped))
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
        } else if state.panel.prefixLabels.isEmpty {
            Text(localization.text(.panelIdleHint))
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
        } else {
            HStack(spacing: 4) {
                ForEach(Array(state.panel.prefixLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: TypeScale.caption, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusTag).fill(palette.selection))
                        .foregroundStyle(palette.secondaryText)
                }
                if state.panel.usedBuiltInCatalog {
                    // The rows are not this app's menus. Say so — and when the scan was
                    // blocked outright, say that too, instead of leaving the user to
                    // wonder why the app's own commands are missing.
                    Text(localization.text(state.scanState == .permissionDenied ? .scanFallbackHint : .overlayBuiltInBadge))
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Which app the palette searches. Nil is the frontmost app, which is the default.
    private var searchScopeMenu: some View {
        Menu {
            Button {
                engine.selectSearchScope(nil)
            } label: {
                Label(localization.text(.frontmostApp), systemImage: "desktopcomputer")
            }
            let apps = state.runningApps.filter { $0.bundleID != Bundle.main.bundleIdentifier }
            if !apps.isEmpty { Divider() }
            ForEach(apps) { app in
                Button(app.name) { engine.selectSearchScope(app.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: TypeScale.caption))
                Text(state.search.scopeName.isEmpty
                     ? localization.text(.frontmostApp)
                     : state.search.scopeName)
                    .font(.system(size: TypeScale.caption, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: 130, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help(localization.text(.frontmostApp))
    }

    private func exportSearchMarkdown() {
        let title = state.search.scopeName.isEmpty ? state.appName : state.search.scopeName
        guard let url = ExportPanel.run(defaultName: "\(title).md", pathExtension: "md") else { return }
        do {
            try engine.makeSearchMarkdown().write(to: url, atomically: true, encoding: .utf8)
            engine.showHUD(chord: "", title: localization.text(.exportMarkdown))
        } catch {
            engine.showHUD(chord: "!", title: error.localizedDescription, kind: .failure)
        }
    }

    private func searchField(layout: HeaderLayout) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: TypeScale.callout, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            TextField(localization.text(.searchPlaceholder), text: searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: TypeScale.body))
                .focused($searchFocused)
                .onSubmit {
                    engine.confirmSearchSelection()
                }
            if !state.search.query.isEmpty {
                Button {
                    state.search.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: TypeScale.callout))
                        .foregroundStyle(palette.tertiaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.selection, size: 18, cornerRadius: Theme.radiusTag))
                // The clear control is one glyph and nothing else. `.help` is a mouse
                // tooltip; VoiceOver would only say "xmark circle fill".
                .accessibilityLabel(localization.text(.searchClearHint))
                .help(localization.text(.searchClearHint))
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: CGFloat(layout.fieldMin), idealWidth: CGFloat(layout.fieldIdeal),
               maxWidth: CGFloat(layout.fieldIdeal), minHeight: 28, maxHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(palette.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .stroke(palette.rule, lineWidth: 1)
                .decorative()
        )
    }

    private func dismissCurrentSurface() {
        if isSearch { engine.hideSearch() } else { engine.dismissPanel() }
    }
}

// MARK: - Panel content

/// The shortcut list: the scanning/empty states and the row grid. Owns the row-level
/// interaction state (hover, press flash, hovered star) and reads only the panel slice
/// of state (`panel.*` groups/selection/scan flags) plus `scanState` and
/// `showsFavoritesOnly` — so typing in the search palette or a countdown elsewhere does
/// not rebuild the rows.
private struct OverlayPanelContentView: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @Environment(EngineState.self) private var state
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var localization: Localization
    @EnvironmentObject private var usageStore: UsageStore
    @State private var hoveredRowID: String?
    /// The row currently being clicked, held for one frame so a press is visible even when
    /// the action closes the panel straight away.
    @State private var pressedRowID: String?
    @State private var hoveredStarID: String?
    @Environment(\.colorScheme) private var systemColorScheme

    private var settings: AppSettingsSnapshot { settingsStore.settings }
    private var palette: PanelPalette {
        settings.panelTheme.palette(isDarkSystem: systemColorScheme == .dark)
    }

    var body: some View {
        content
            .onChange(of: state.panel.appName) { _, _ in
                // A stale hover would paint a row for the previous app, which the pointer has
                // never been over.
                hoveredRowID = nil
                hoveredStarID = nil
            }
    }

    /// The four "nothing here" answers.
    ///
    /// Scanning keeps its spinner and stays one line. The other three borrow the palette's
    /// own empty state structure — symbol, conclusion, next step, centred — because a single
    /// 12 pt sentence at the top-left read as a rendering fault rather than an answer.
    @ViewBuilder
    private func emptyState(_ kind: PanelEmptyKind) -> some View {
        Group {
            if kind == .scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(palette.secondaryText)
                    Text(localization.text(kind.messageKey))
                        .font(.system(size: TypeScale.callout))
                        .foregroundStyle(palette.secondaryText)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: emptyStateSymbol(kind))
                        .font(.system(size: IconScale.hero))
                        .foregroundStyle(palette.tertiaryText)
                        .accessibilityHidden(true)
                    Text(localization.text(kind.messageKey))
                        .font(.system(size: TypeScale.callout))
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    // The favourites message already ends with how to pin something, so
                    // only the filter/hold case needs a separate hint line.
                    if kind == .noMatches {
                        Text(localization.text(.overlayNoCandidatesHint))
                            .font(.system(size: TypeScale.caption))
                            .foregroundStyle(palette.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if kind == .permissionRequired {
                        Button(localization.text(.permissionsTitle)) {
                            engine.showPermissionsWindow()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 24)
    }

    private func emptyStateSymbol(_ kind: PanelEmptyKind) -> String {
        switch kind {
        case .permissionRequired: return "lock.fill"
        case .scanning: return "hourglass"
        case .noFavorites: return "star"
        case .noMatches: return "magnifyingglass"
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.panel.isEmpty {
            // One priority order lives in `PanelEmptyKind`: permission > scanning >
            // favourites > no match. The view only picks a shape for the answer.
            emptyState(PanelEmptyKind.kind(
                isScanning: state.panel.isScanning,
                permissionDenied: state.scanState == .permissionDenied,
                showsFavoritesOnly: state.panel.showsFavoritesOnly,
                favoritesEmpty: usageStore.favorites.isEmpty
            ))
        } else {
            GeometryReader { proxy in
                let columns = max(1, min(settings.columnCount, OverlayMetrics.columns(forWidth: proxy.size.width)))
                // How many rows one column can show. Filling each column to this height — not
                // dividing the page evenly — is what keeps a three-column page as tall as a
                // two-column one: 50 rows spread as 17·17·16 left the card short of the
                // window while the columns below were empty. `perCard` lets the rows be
                // shared out when a page straddles both sections.
                let cards = max(1, state.panel.groups.count)
                let cardChrome = Double(Theme.groupHeaderHeight) + OverlayMetrics.cardVerticalInset * 2
                let fittedRows = (Double(proxy.size.height)
                    - Double(OverlayMetrics.contentTopPadding + OverlayMetrics.contentBottomPadding)
                    - cardChrome * Double(cards))
                    / Double(Theme.rowHeight)
                let tallestCard = state.panel.groups.map(\.rows.count).max() ?? 0
                let capacity = max(
                    Int((Double(tallestCard) / Double(columns)).rounded(.up)),
                    max(1, Int(fittedRows) / cards)
                )
                // One measurement per panel, not per row: every row in every column is the
                // same width, so the three columns line up down the whole list.
                let layout = RowLayout.metrics(
                    // Two insets, not one: the scroll view's padding, then the card's own.
                    rowWidth: RowLayout.rowWidth(
                        contentWidth: proxy.size.width
                            - Theme.padding * 2
                            - OverlayMetrics.cardHorizontalInset * 2,
                        columns: columns
                    ),
                    keyPosition: settings.keyPosition,
                    keyStyle: settings.keyStyle
                )
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: OverlayMetrics.cardGap) {
                        ForEach(state.panel.groups) { group in
                            groupSection(group, columns: columns, capacity: capacity, layout: layout)
                        }
                    }
                    .padding(.horizontal, Theme.padding)
                    .padding(.top, OverlayMetrics.contentTopPadding)
                    .padding(.bottom, OverlayMetrics.contentBottomPadding)
                    // A short page used to end mid-window with 300 pt of empty glass under
                    // it; centring keeps the shape deliberate without shrinking the cover.
                    .frame(minHeight: proxy.size.height, alignment: .center)
                }
                // No fade over the last row: the page size is now capped by the geometry,
                // so the list ends where the content area ends. A gradient here tinted the
                // bottom of a real row and read as the footer covering it.
            }
        }
    }

    /// One section of the panel, drawn as a card — the same treatment the search palette gives
    /// its categories: a title strip, a hairline under it, and a border around the whole block.
    ///
    /// The panel has three sources (the app's commands, the system's hotkeys and each config
    /// tool's file), and they used to be told apart by a heading in the middle of the list. A
    /// card makes the boundary a shape instead of a line of text: it survives scrolling, it
    /// survives the narrow layout, and it matches what the palette already looks like.
    /// A tool's card is collapsible: its title strip is the click target and carries a chevron.
    private func groupSection(
        _ group: PanelGroup,
        columns: Int,
        capacity: Int,
        layout: RowLayout.Metrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !group.title.isEmpty {
                HStack(spacing: 8) {
                    if group.isCollapsible {
                        Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: TypeScale.micro, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                    }
                    Text(group.title)
                        .font(.system(size: TypeScale.callout, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(palette.secondaryText)
                    Text(localization.format(.overlayCountFormat, group.totalCount ?? group.rows.count))
                        .font(.system(size: TypeScale.caption, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: Theme.groupHeaderHeight, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.selection)
                // The tool card's header is the toggle: the rows are hidden, the count and the
                // source stay visible so the user can see what there is to open.
                .contentShape(Rectangle())
                .onTapGesture {
                    if let tool = group.tool {
                        engine.toggleToolSection(tool)
                    }
                }
                Rectangle()
                    .fill(palette.rule)
                    .frame(height: 1)
                    .decorative()
            }
            // Filled down each column, not across: the page is ordered by the shortcut
            // itself, so ⌘A…⌘K belong in one run down the first column. A LazyVGrid fills
            // across (A B C on one line), which zig-zags that order and makes ↓ walk sideways.
            HStack(alignment: .top, spacing: CGFloat(RowLayout.columnSpacing)) {
                ForEach(Array(PanelColumnFill.split(group.rows, into: columns, capacity: capacity).enumerated()),
                        id: \.offset) { _, columnRows in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(columnRows) { row in
                            rowView(row, layout: layout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(alignment: .leading) { columnRules(columns: columns) }
            .padding(.horizontal, OverlayMetrics.cardHorizontalInset)
            .padding(.vertical, OverlayMetrics.cardVerticalInset)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(palette.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .stroke(palette.border, lineWidth: Theme.increaseContrast ? 1.5 : 1)
                .decorative()
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }

    /// One hairline per internal column boundary.
    ///
    /// The columns are far apart by construction, so the chord at the end of one row sits
    /// closer to the command at the start of the next (36 pt) than to its own menu path
    /// (291 pt) — the nearest thing to a chord was somebody else's command. The rule is the
    /// border the gap could not draw.
    @ViewBuilder
    private func columnRules(columns: Int) -> some View {
        if columns > 1 {
            GeometryReader { proxy in
                let spacing = CGFloat(RowLayout.columnSpacing)
                let usable = proxy.size.width - spacing * CGFloat(columns - 1)
                let columnWidth = max(0, usable / CGFloat(columns))
                ForEach(1..<columns, id: \.self) { index in
                    Rectangle()
                        .fill(palette.rule)
                        .frame(width: 1)
                        .offset(x: CGFloat(index) * (columnWidth + spacing) - spacing / 2)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Three columns of fixed width, so the same field starts at the same x on every row:
    /// the command name, the menu path, and the chord with its trailing slot.
    private func rowView(_ row: PanelRow, layout: RowLayout.Metrics) -> some View {
        // A dimmed row carries index -1, exactly like the "nothing selected" marker, so
        // comparing the two lit up every dimmed row. Only a real position can be selected.
        let isSelected = row.index >= 0 && state.panelSelectionIndex == row.index
        return rowColumns(row, layout: layout, isSelected: isSelected)
            .padding(.horizontal, Theme.rowHorizontalPadding)
            .frame(height: Theme.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(rowFill(row, isSelected: isSelected))
            )
            // The selection marker sits in the row's own gutter: appearing and disappearing
            // must never reflow the title or the keycap.
            .overlay(alignment: .leading) { selectionMarker(isSelected) }
            .contentShape(Rectangle())
            // The row is a container, not one opaque blob: the star and the conflict badge
            // keep their own labels, while the purely decorative bits hide themselves. The
            // row itself still reads "name, shortcut, state" in that order.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(rowAccessibilityLabel(row)))
            .accessibilityValue(Text(rowAccessibilityValue(row)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction { engine.performPanelRow(rowID: row.id, action: .execute) }
            .onHover { inside in
                hoveredRowID = inside ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
                if inside {
                    engine.select(rowID: row.id)
                }
            }
            .onTapGesture {
                press(row.id)
                // A click copies a restricted or config-tool row and runs everything else;
                // the plan decides, so the view does not have to special-case either.
                engine.clickPanelRow(rowID: row.id)
            }
            .animation(.easeOut(duration: 0.1), value: isSelected)
            .contextMenu { rowMenu(row) }
    }

    /// The columns in the order the settings ask for: the chord is either the first thing on
    /// the row or the last, and the menu path travels with it.
    private func rowColumns(_ row: PanelRow, layout: RowLayout.Metrics, isSelected: Bool) -> some View {
        HStack(spacing: Theme.rowColumnGap) {
            if settings.keyPosition == .left {
                keyLabel(row, width: layout.keyWidth, alignment: .leading)
            }
            titleColumn(row, width: layout.titleWidth, selected: isSelected)
            if settings.keyPosition == .left {
                // Key · command · path — the path and the trailing slot travel together, so
                // the row still has three columns and the chord keeps the opposite end.
                HStack(spacing: Theme.rowColumnGap) {
                    if layout.showsNote {
                        noteColumn(row, width: layout.noteWidth, hugsChord: layout.noteHugsChord)
                    }
                    gutter(row)
                }
            } else {
                if layout.showsNote {
                    noteColumn(row, width: layout.noteWidth, hugsChord: layout.noteHugsChord)
                }
                HStack(spacing: Theme.rowColumnGap) {
                    gutter(row)
                    keyLabel(row, width: layout.keyWidth, alignment: .trailing)
                }
            }
        }
    }

    /// What just happened beats where the pointer is: a completed row stays lit, a press
    /// flashes, and only then do selection and hover get a colour.
    private func rowFill(_ row: PanelRow, isSelected: Bool) -> Color {
        if row.isCompleted { return Color.accentColor.opacity(Theme.completedRowEmphasis) }
        if pressedRowID == row.id { return Color.accentColor.opacity(Theme.pressedRowEmphasis) }
        if isSelected { return palette.selection }
        if hoveredRowID == row.id { return palette.hover }
        return .clear
    }

    private func selectionMarker(_ isSelected: Bool) -> some View {
        // 3 pt, not a hairline: the fill alone was easy to miss on the light palette at a
        // glance, and the bar is the second signal that survives a colour-blind reading.
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 3, height: 14)
            .padding(.leading, 2)
            .scaleEffect(x: 1, y: isSelected ? 1 : 0.2, anchor: .center)
            .opacity(isSelected ? 1 : 0)
            .decorative()
    }

    /// The right-click menu. The draft's four items are pass through, pin, copy the shortcut
    /// and locate it; locating needs a shortcut page this app cannot open yet, so the first
    /// three are here, in that order, and settings stays below them as the fifth door.
    ///
    /// Rows Kaname refuses to run get a shorter menu instead: copying stays, running does
    /// not, and the reason is written where the action would have been.
    @ViewBuilder
    private func rowMenu(_ row: PanelRow) -> some View {
        if row.isRestricted {
            if row.hasChord {
                Button(localization.text(.panelCopyShortcut)) {
                    engine.copyShortcut(rowID: row.id)
                }
            }
            Button(localization.text(.panelCopyMenuItem)) {
                engine.copyMenuPath(rowID: row.id)
            }
            Divider()
            Text(localization.text(.panelRestrictedReason))
        } else if row.source == .configFile {
            if !row.isEnabled {
                Text(localization.text(.panelDisabledReason))
                Divider()
            }
            if row.hasChord {
                Button(localization.text(.panelCopyShortcut)) {
                    engine.copyShortcut(rowID: row.id)
                }
            }
            Button(localization.text(.panelCopyMenuItem)) {
                engine.copyMenuPath(rowID: row.id)
            }
            Button(row.isFavorite ? localization.text(.panelUnpin) : localization.text(.panelPin)) {
                engine.toggleFavorite(rowID: row.id)
            }
            Divider()
            Text(localization.text(.panelUnsupportedSource))
            Divider()
            Button(localization.text(.panelSettings)) {
                engine.showSettings()
            }
        } else {
            if !row.isEnabled {
                // The menu states the reason instead of offering an action that cannot run.
                Text(localization.text(.panelDisabledReason))
                Divider()
            }
            Button(localization.text(.panelPassThrough)) {
                engine.activate(rowID: row.id)
            }
            Button(row.isFavorite ? localization.text(.panelUnpin) : localization.text(.panelPin)) {
                engine.toggleFavorite(rowID: row.id)
            }
            Button(localization.text(.panelCopyShortcut)) {
                engine.copyShortcut(rowID: row.id)
            }
            Divider()
            Button(localization.text(.panelSettings)) {
                engine.showSettings()
            }
        }
    }

    /// The pin star used to be a `Button` nested inside a row that also had a tap gesture.
    /// That is a nested-button gamble: pinning a row could also activate it, close the panel
    /// and fire the shortcut into the front app. A child tap gesture is unambiguous — the
    /// innermost recogniser wins — and the hit area is bounded to the (always reserved) star.
    private func favoriteButton(_ row: PanelRow) -> some View {
        let selected = row.index >= 0 && state.panelSelectionIndex == row.index
        let visible = hoveredRowID == row.id || selected || row.isFavorite
        let lit = hoveredStarID == row.id
        return Image(systemName: row.isFavorite ? "star.fill" : "star")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(row.isFavorite ? Theme.favoriteStar : palette.tertiaryText)
            .scaleEffect(lit ? 1.2 : 1)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .onHover { inside in
                hoveredStarID = inside ? row.id : (hoveredStarID == row.id ? nil : hoveredStarID)
            }
            .highPriorityGesture(TapGesture().onEnded {
                engine.toggleFavorite(rowID: row.id)
            })
            .animation(.easeOut(duration: 0.1), value: lit)
            .help(localization.text(row.isFavorite ? .panelUnpin : .panelPin))
            .accessibilityHidden(!visible)
            .accessibilityLabel(Text(localization.text(row.isFavorite ? .panelUnpin : .panelPin)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { engine.toggleFavorite(rowID: row.id) }
    }

    /// One-frame press highlight. Row actions usually dismiss the panel, so the flash is
    /// mostly seen on group rows that descend instead of closing, and on the star.
    private func press(_ id: String) {
        pressedRowID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.18)) {
                if pressedRowID == id { pressedRowID = nil }
            }
        }
    }

    private func rowAccessibilityLabel(_ row: PanelRow) -> String {
        let key = row.keySegments.map(\.text).joined()
        return [row.title, key, row.note]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The command name: whatever width is left once every other column is reserved.
    ///
    /// A fixed width, not a natural one — the menu path has to start at the same x on every
    /// row, and that is only true if this column does not grow and shrink with its text.
    private func titleColumn(_ row: PanelRow, width: Double, selected: Bool) -> some View {
        HStack(spacing: 4) {
            // The execution status leads the command name, whichever side the chord is on.
            // It sits inside this fixed-width column rather than in a new one, so the note,
            // gutter and chord keep their x positions on every row.
            executionStatusDot(row)
            if state.panel.runningRowID == row.id {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text(row.title)
                // A hint glyph sits at the far end of the row, a long way from the name it
                // addresses. Underlining the addressable names in the same accent colour as
                // the badge gives the eye an anchor on this side too, so a glance is less
                // likely to land on the row above or below and run the wrong command.
                // `hintLabel` is non-nil only while the hint layer is up.
                .underline(row.hintLabel != nil, color: Color.accentColor.opacity(0.65))
                .font(.system(size: TypeScale.body, weight: row.isCompleted ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(rowTitleColor(row))
                // A selected row's name steps up in brightness: the tint is a surface cue
                // and can wash out on the light palette.
                .brightness(selected ? 0.06 : 0)
            if !row.isEnabled {
                // A dimmed row and a row the app cannot run looked identical; the lock says
                // the cause at a glance without turning the row into an error banner.
                Image(systemName: "lock.slash")
                    .font(.system(size: TypeScale.micro))
                    .foregroundStyle(palette.tertiaryText)
                    .accessibilityLabel(localization.text(.overlayUnavailableBadge))
                    .accessibilityHint(localization.text(.panelDisabledReason))
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// Running is a state of the row, not a decoration: VoiceOver has to read it, otherwise a
    /// row that is being resolved is indistinguishable from an idle one.
    private func rowAccessibilityValue(_ row: PanelRow) -> String {
        if state.panel.runningRowID == row.id {
            return localization.text(.overlayRunning)
        }
        var values: [String] = []
        if !row.isEnabled { values.append(localization.text(.overlayUnavailableBadge)) }
        if row.isRestricted { values.append(localization.text(.panelRestrictedReason)) }
        // The dot is a colour, which VoiceOver cannot read. Its verdict goes here so the
        // leading marker and the trailing conflict badge stay independent aurally too.
        if let verdict = row.executionVerdict {
            values.append(localization.text(executionStatusKey(verdict.status)))
        }
        return values.joined(separator: ", ")
    }

    /// The menu path, with the "has a sub-level" chevron in a slot of its own at the left.
    ///
    /// Truncated in the middle: the head of a path ("File") and its last step are the parts
    /// that tell the user where the command lives, so those are what survive.
    private func noteColumn(_ row: PanelRow, width: Double, hugsChord: Bool) -> some View {
        Text(row.note)
            .font(.system(size: TypeScale.caption))
            .lineLimit(1)
            .truncationMode(.middle)
            // The menu path is the only answer to "where does this command live"; at 32 %
            // white it measured 2.8:1 on the card, under every legibility floor for 10.5 pt.
            .foregroundStyle(palette.secondaryText)
            // The path belongs to the chord, not to the middle of the row: with the chord on
            // the right its slot is aligned to that edge, so "System ⌘A" reads as one cluster.
            .frame(width: width, alignment: hugsChord ? .trailing : .leading)
    }

    /// The leading dot answers "can this row be executed at all", which is a different
    /// question from the trailing conflict badge. Both execution paths are named on hover,
    /// so a yellow dot says *why* the chord is blocked without claiming the row is dead.
    /// The pure layer only produces enum cases; the words live here.
    private func executionStatusHelp(_ verdict: PanelTriggerAudit.Verdict) -> String {
        var parts = [localization.text(executionStatusKey(verdict.status))]
        if let blocker = verdict.shortcutBlocker {
            parts.append(localization.text(shortcutBlockerKey(blocker)))
        }
        if let blocker = verdict.activationBlocker {
            parts.append(localization.text(activationBlockerKey(blocker)))
        }
        return parts.joined(separator: " · ")
    }

    private func executionStatusKey(_ status: PanelTriggerAudit.Status) -> L10nKey {
        switch status {
        case .executable: return .auditStatusExecutable
        case .shortcutBlocked: return .auditStatusShortcutBlocked
        case .unreachable: return .auditStatusUnreachable
        }
    }

    private func shortcutBlockerKey(_ blocker: PanelTriggerAudit.ShortcutBlocker) -> L10nKey {
        switch blocker {
        case .noChord: return .auditReasonNoChord
        case .claimedByFilter: return .auditReasonClaimedByFilter
        case .capturedByPanelKey: return .auditReasonCapturedByPanelKey
        case .unresolvedByRouter: return .auditReasonUnresolvedByRouter
        case .unmappableKey: return .auditReasonUnmappableKey
        }
    }

    private func activationBlockerKey(_ blocker: PanelTriggerAudit.ActivationBlocker) -> L10nKey {
        switch blocker {
        case .disabledItem: return .auditReasonDisabledItem
        case .refusedByPolicy: return .auditReasonRefusedByPolicy
        case .noExecutionTarget: return .auditReasonNoExecutionTarget
        }
    }

    private func executionStatusColor(_ status: PanelTriggerAudit.Status) -> Color {
        switch status {
        case .executable: return Theme.statusReady
        case .shortcutBlocked: return Theme.statusDegraded
        case .unreachable: return Theme.statusBlocked
        }
    }

    /// A small dot before the command name. Its slot is reserved on every row — even when
    /// the self-check is switched off — so the title never shifts when a verdict appears.
    @ViewBuilder
    private func executionStatusDot(_ row: PanelRow) -> some View {
        Group {
            if let verdict = row.executionVerdict {
                Circle()
                    .fill(executionStatusColor(verdict.status))
                    .help(executionStatusHelp(verdict))
                    .accessibilityLabel(Text(executionStatusHelp(verdict)))
            } else {
                Circle().fill(Color.clear)
            }
        }
        .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
        .accessibilityHidden(row.executionVerdict == nil)
    }

    /// The row's trailing slot: conflict badge, sub-level chevron and favourite star, always
    /// the same width.
    ///
    /// The badge used to be added only when there was a conflict, which moved the chord
    /// about 17pt to the left on exactly the rows where the user was being warned about
    /// something. Both markers are now always there and simply go transparent.
    ///
    /// Execution status deliberately does not live here: it has its own leading dot, so a
    /// healthy row with a shortcut collision still shows the ⚠︎, and a row whose chord is
    /// blocked shows yellow without borrowing the conflict's warning colour.
    ///
    /// The chevron lives here rather than beside the menu path so that it survives the narrow
    /// panel, where the menu path column is dropped: a row with a level below it must stay
    /// recognisable whichever columns are showing.
    private func gutter(_ row: PanelRow) -> some View {
        HStack(spacing: RowLayout.gutterSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Theme.warning.opacity(0.85))
                .frame(width: 12)
                .opacity(row.hasConflict ? 1 : 0)
                .accessibilityHidden(!row.hasConflict)
            Image(systemName: "chevron.right")
                .font(.system(size: TypeScale.micro, weight: .bold))
                .foregroundStyle(palette.tertiaryText)
                .frame(width: RowLayout.chevronWidth)
                .opacity(row.isGroup ? 1 : 0)
                .accessibilityHidden(!row.isGroup)
            favoriteButton(row)
        }
        .frame(width: Theme.rowGutterWidth, alignment: .trailing)
    }

    /// The shortcut column, one `Text` per glyph.
    ///
    /// A held (or ticked) modifier is coloured and bolded instead of being dropped from the
    /// chord: `⌘C` still reads `⌘C` while ⌘ is down, with the ⌘ lit. Per-glyph views are what
    /// makes that possible without re-parsing the formatted string.
    ///
    /// The width is a cap, not a natural size: a `words`-style chord ("control option A")
    /// used to overflow a two-column panel and, with the chord on the left, push the command
    /// name off the row entirely.
    private func keyLabel(_ row: PanelRow, width: Double, alignment: Alignment) -> some View {
        Group {
            if let hint = row.hintLabel {
                // Hint layer up: the glyph stands in for the chord, so the row answers
                // "which key runs me" without the user reading the shortcut first.
                Text(hint)
                    .font(.system(size: TypeScale.caption, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.text)
                    .frame(width: 17, height: 17)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusTag, style: .continuous)
                            .fill(Color.accentColor.opacity(palette.isLight ? Theme.hintBadgeFillLight : Theme.hintBadgeFillDark))
                    )
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(row.keySegments.enumerated()), id: \.offset) { _, segment in
                        Text(segment.text)
                            // A word standing in for a chord ("No shortcut") is a note, not a key: at
                            // chord size it no longer fits the slot the chord column was narrowed to.
                            .font(.system(
                                size: isLabel(segment) ? TypeScale.micro : TypeScale.callout,
                                weight: isEmphasized(segment) ? .bold : (isLabel(segment) ? .regular : .semibold),
                                design: isLabel(segment) ? .default : .monospaced
                            ))
                            .foregroundStyle(keySegmentColor(row, segment))
                    }
                }
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(width: width, alignment: alignment)
    }

    /// Modifiers whose glyph is lit: exactly the set the panel is narrowed by, from both
    /// sources (physically down and ticked in the title bar). The header's chips read the
    /// same `pending.effective`, so a lit row and a lit chip cannot drift apart.
    ///
    /// A lone held ⇧ is the hint layer, not a filter, so `effective` drops it; a ⇧ clicked
    /// in the title bar is explicit and stays.
    private var emphasizedModifiers: ModifierSet {
        state.pending.effective
    }

    private func isLabel(_ segment: KeyFormatter.Segment) -> Bool {
        if case .label = segment.kind { return true }
        return false
    }

    private func isEmphasized(_ segment: KeyFormatter.Segment) -> Bool {
        guard case .modifier(let modifier) = segment.kind else { return false }
        return emphasizedModifiers.contains(modifier)
    }

    private func rowTitleColor(_ row: PanelRow) -> Color {
        // Red is a statement about safety, not decoration: these rows are shown precisely so
        // the user can see that the shortcut exists, and that Kaname will not run it.
        if row.isRestricted { return palette.restrictedText }
        if row.isCompleted { return palette.text }
        if !row.isEnabled { return palette.disabledText }
        return row.isHighlighted ? palette.text : palette.text.opacity(0.88)
    }

    private func keySegmentColor(_ row: PanelRow, _ segment: KeyFormatter.Segment) -> Color {
        if case .label = segment.kind { return palette.secondaryText }
        if !row.isEnabled { return palette.disabledText }
        if isEmphasized(segment) { return palette.keyHighlight }
        if row.isCompleted { return palette.text }
        return palette.key
    }
}

// MARK: - Search content

/// The palette body: the combo answer banner and the results (or the empty state). Reads
/// only the search slice of state (`search.comboAnswer/results/selection/query`), so a
/// panel rebuild or a scan-progress change does not re-render the results.
private struct OverlaySearchContentView: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @Environment(EngineState.self) private var state
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var localization: Localization
    @Environment(\.colorScheme) private var systemColorScheme

    private var settings: AppSettingsSnapshot { settingsStore.settings }
    private var palette: PanelPalette {
        settings.panelTheme.palette(isDarkSystem: systemColorScheme == .dark)
    }

    var body: some View {
        VStack(spacing: 0) {
            // A query that spells out a combo gets its own answer above the list. Without
            // it, a combo only one thing owns comes back as an empty list, which reads as
            // "not scanned" rather than "nobody else wants this".
            if let answer = state.search.comboAnswer {
                ComboLookupBanner(answer: answer, palette: palette)
            }
            if state.search.usedBuiltInCatalog {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                    Text(localization.text(.searchBuiltInNotice))
                }
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.hover)
            }
            Group {
                if state.search.results.isEmpty {
                    searchEmptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SearchResultList(
                        sections: searchSections,
                        selection: state.search.selection,
                        scrollRequest: state.search.scrollRequest,
                        query: state.search.query,
                        style: settings.keyStyle,
                        keyPosition: settings.keyPosition,
                        palette: palette,
                        titleFor: { engine.displayName(of: $0) },
                        onTap: { engine.activateSearchResult($0) },
                        onHover: { engine.selectSearchResult($0, scrollIntoView: false) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var searchEmptyState: some View {
        if state.search.loadState == .loading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(localization.text(.searchScopeLoading))
                    .font(.system(size: TypeScale.callout))
                    .foregroundStyle(palette.secondaryText)
            }
        } else if state.search.loadState == .permissionDenied {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: IconScale.hero))
                    .foregroundStyle(palette.secondaryText)
                Text(localization.text(.scanPermissionDenied))
                    .font(.system(size: TypeScale.callout))
                    .foregroundStyle(palette.secondaryText)
                Button(localization.text(.permissionWizard)) {
                    engine.showPermissionsWindow()
                }
                .controlSize(.small)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: IconScale.hero))
                    .foregroundStyle(palette.tertiaryText)
                // Name the scope: with the palette scoped to one app, "No matches" reads
                // as "Kaname does not know this shortcut" when the answer is "not in this
                // app".
                Text(state.search.scopeName.isEmpty
                     ? localization.text(.searchNoResults)
                     : localization.format(.searchNoResultsScopedFormat, state.search.scopeName))
                    .font(.system(size: TypeScale.callout))
                    .foregroundStyle(palette.secondaryText)
                Text(localization.text(.searchNoResultsHint))
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
    }

    private var searchSections: [SearchSection] {
        var order: [String] = []
        var rows: [String: [(Int, BindingItem)]] = [:]
        for (index, item) in state.search.results.enumerated() {
            let key = item.displayGroup
            if rows[key] == nil { order.append(key) }
            rows[key, default: []].append((index, item))
        }
        return order.map { SearchSection(id: $0, title: $0, rows: rows[$0] ?? []) }
    }
}

// MARK: - Footer

/// The footer: search count, panel paging, and the action hint. Reads `search.*`, the
/// panel's page fields, `shiftHintActive` and the remappable run/copy keys, so unrelated
/// state changes do not redraw it.
private struct OverlayFooterView: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @Environment(EngineState.self) private var state
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var localization: Localization
    @Environment(\.colorScheme) private var systemColorScheme

    private var settings: AppSettingsSnapshot { settingsStore.settings }
    private var palette: PanelPalette {
        settings.panelTheme.palette(isDarkSystem: systemColorScheme == .dark)
    }
    private var isSearch: Bool { state.search.isVisible }

    var body: some View {
        GeometryReader { proxy in
            footerContent(layout: HeaderLayout(width: proxy.size.width))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: OverlayMetrics.footerHeight)
    }

    private func footerContent(layout: HeaderLayout) -> some View {
        HStack(spacing: 8) {
            if isSearch {
                Text(state.search.results.count == 1
                     ? localization.text(.searchResultCountOne)
                     : localization.format(.searchResultCount, state.search.results.count))
                    .font(.system(size: TypeScale.caption, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
            } else if state.panel.pageCount > 1 {
                Button(action: engine.previousPage) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: TypeScale.caption, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.hover, size: 22, cornerRadius: Theme.radiusControl))
                .accessibilityLabel(localization.text(.panelPreviousPage))
                .help(localization.text(.panelPreviousPage))

                Text(localization.format(.overlayPageFormat, state.panel.pageIndex + 1, state.panel.pageCount))
                    .font(.system(size: TypeScale.caption, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryText)

                Button(action: engine.nextPage) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: TypeScale.caption, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.hover, size: 22, cornerRadius: Theme.radiusControl))
                .accessibilityLabel(localization.text(.panelNextPage))
                .help(localization.text(.panelNextPage))
            }

            Spacer()
            Text(footerHint(layout: layout))
                .font(.system(size: TypeScale.caption))
                // This line is the only place the panel teaches its own keys; at 32 % white
                // it measured 2.5:1, the faintest text on the surface. While the hint layer
                // is up it borrows the same accent the row labels use, so the footer and the
                // labelled rows read as one mode.
                .foregroundStyle(state.panel.shiftHintActive ? palette.keyHighlight : palette.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
    }

    /// The hint spells out what the two keys actually do right now, so remapping Return in
    /// Settings cannot leave the footer lying.
    /// What the footer says, in the fullest form the width allows.
    ///
    /// Three bands rather than one string: the full hint wraps onto a second line at 460 pt
    /// and is cut off at 300 pt, and a hint that is cut off is a hint that is wrong.
    private func footerHint(layout: HeaderLayout) -> String {
        if isSearch {
            // The palette is run-only: Return replays the shortcut and there is no copy key.
            return localization.text(.searchHintRun)
        }
        // The hint layer is a sticky mode with two exits and no other visible clue. Name
        // the way in before it is up and both ways out while it is; the row labels are the
        // primary information then, so the run/copy keys step aside.
        if state.panel.shiftHintActive {
            switch layout {
            case .full, .tight: return localization.text(.panelHintActive)
            case .minimal: return localization.text(.panelHintActiveCompact)
            }
        }
        let enter = localization.text(.panelHintEnter)
        guard state.panel.isPinned else {
            return enter + " · " + localization.text(.overlayHint)
        }
        // A deleted row key is `nil`; the hint drops only the action it no longer has.
        let run = settings.runRowKey.map { KeyFormatter.render($0.chord, style: settings.keyStyle) }
        let copy = settings.copyRowKey.map { KeyFormatter.render($0.chord, style: settings.keyStyle) }
        let base: String
        switch layout {
        case .full:
            if let run, let copy { base = localization.format(.panelActionHintSearch, run, copy) }
            else { base = rowHint(run: run, copy: copy) }
        case .tight:
            if let run, let copy { base = localization.format(.panelActionHint, run, copy) }
            else { base = rowHint(run: run, copy: copy) }
        case .minimal:
            base = rowHint(run: run, copy: copy)
        }
        return enter + " · " + base
    }

    /// The narrow forms, for a footer that has one action key or none.
    private func rowHint(run: String?, copy: String?) -> String {
        if let run { return localization.format(.panelActionHintCompact, run) }
        if let copy { return localization.format(.panelCopyHintCompact, copy) }
        return localization.text(.panelEscCloseHint)
    }
}

private struct SearchSection: Identifiable {
    let id: String
    let title: String
    let rows: [(Int, BindingItem)]
}

/// The palette's results, one card per menu category.
///
/// Three kinds of content, three places, never mixed: the **category** is the card's header
/// (and nothing inside repeats it), the **shortcut** has a column of its own on the left, and
/// the **menu item** — its name plus where it lives — fills the rest of the row. A flat list
/// with headings interleaved made the three read as one stream; a card per category puts a
/// border between them and keeps each group's rows aligned with the next one's.
private struct SearchResultList: View {
    let sections: [SearchSection]
    let selection: Int
    /// Changes only when the palette itself wants the selection on screen — never for the
    /// pointer moving over a row.
    let scrollRequest: Int
    let query: String
    let style: KeyFormatter.Style
    let keyPosition: KeyPosition
    let palette: PanelPalette
    /// The engine decides what a row is called (a nameless system hotkey is named by its
    /// chord), so the list does not re-derive a title of its own.
    let titleFor: (BindingItem) -> String
    let onTap: (Int) -> Void
    let onHover: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(sections) { section in
                        sectionCard(section)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .onChange(of: scrollRequest) { _, _ in
                scroll(to: selection, proxy: proxy)
            }
        }
    }

    private func sectionCard(_ section: SearchSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(section.title.isEmpty ? "—" : section.title)
                    .font(.system(size: TypeScale.callout, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                Text("\(section.rows.count)")
                    .font(.system(size: TypeScale.caption, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.tertiaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            // Two tones: the header band is a step darker than the body, so the category
            // reads as a title strip rather than as a first row that happens to be bold.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.selection)
            // The rule is the boundary between the category and its items: one card holds
            // exactly one category, so nothing below this line can be mistaken for another.
            Rectangle()
                .fill(palette.rule)
                .frame(height: 1)
                .decorative()

            VStack(spacing: 1) {
                ForEach(section.rows, id: \.1.id) { index, item in
                    SearchResultRow(
                        item: item,
                        title: titleFor(item),
                        isUnnamed: item.title == DescriptionCleaner.placeholder,
                        isEnabled: item.isEnabled,
                        query: query,
                        style: style,
                        keyPosition: keyPosition,
                        isSelected: index == selection,
                        palette: palette,
                        onActivate: { if item.isEnabled { onTap(index) } }
                    )
                    .id(item.id)
                    .onHover { inside in
                        if inside { onHover(index) }
                    }
                    .onTapGesture { if item.isEnabled { onTap(index) } }
                }
            }
            .padding(.vertical, 4)
        }
        // One step louder than the palette background, and an edge that survives it: the
        // card has to read as a card at a glance, or the grouping is only a heading again.
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(palette.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .stroke(palette.border, lineWidth: Theme.increaseContrast ? 1.5 : 1)
                .decorative()
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }

    private func scroll(to index: Int, proxy: ScrollViewProxy) {
        for section in sections {
            if let match = section.rows.first(where: { $0.0 == index }) {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(match.1.id, anchor: .center)
                }
                return
            }
        }
    }
}

private struct SearchResultRow: View {
    let item: BindingItem
    let title: String
    /// The title here *is* the chord, so the shortcut column would print it twice.
    let isUnnamed: Bool
    /// A menu item the app currently greys out. Its text uses `palette.disabledText` and
    /// the row carries an explicit marker instead of dimming everything.
    let isEnabled: Bool
    let query: String
    let style: KeyFormatter.Style
    let keyPosition: KeyPosition
    let isSelected: Bool
    let palette: PanelPalette
    let onActivate: () -> Void
    @EnvironmentObject private var localization: Localization

    /// The shortcut column never moves, whichever app the palette is looking at: that is
    /// what lets the eye run down one column and ignore the text beside it.
    private let keyColumn: CGFloat = 78

    private var restriction: Restriction {
        RestrictedActionPolicy.restriction(for: item)
    }

    var body: some View {
        HStack(spacing: 12) {
            if keyPosition == .left { shortcut }
            titleBlock
            Spacer(minLength: 8)
            if restriction.isRestricted {
                // The row is still searchable and selectable — that is the point of showing it
                // — but the trailing text says why pressing it will not run.
                Text(localization.text(.panelRestrictedReason))
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(palette.restrictedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if keyPosition == .right { shortcut }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(Theme.selectedGutterEmphasis) : Color.clear)
        )
        // Same gutter marker as the panel rows: the title must not slide when the selection
        // follows the pointer or the arrow keys.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 2.5, height: 13)
                .padding(.leading, 2)
                .scaleEffect(x: 1, y: isSelected ? 1 : 0.2, anchor: .center)
                .opacity(isSelected ? 1 : 0)
                .decorative()
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(searchRowAccessibilityLabel))
        .accessibilityValue(Text(item.isEnabled ? "" : localization.text(.overlayUnavailableBadge)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onActivate() }
    }

    private var searchRowAccessibilityLabel: String {
        [title,
         item.subgroup ?? "",
         isUnnamed || item.chord.isEmpty ? "" : KeyFormatter.render(item.chord, style: style)]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The menu item, and under it where the item lives — the description that turns
    /// "Copy Style" into a location when three apps have a command by that name.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                highlightedTitle
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(titleColor)
                if !isEnabled {
                    // A disabled item is still listed on purpose, so it needs a visible
                    // reason rather than a dimmed row nobody can read.
                    Image(systemName: "minus.circle")
                        .font(.system(size: TypeScale.micro))
                        .foregroundStyle(palette.disabledText)
                        .help(localization.text(.overlayUnavailableBadge))
                        .accessibilityHidden(true)
                }
            }
            if let subgroup = item.subgroup {
                Text(subgroup)
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(isEnabled ? palette.tertiaryText : palette.disabledText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var titleColor: Color {
        if restriction.isRestricted { return palette.restrictedText }
        return isEnabled ? palette.text : palette.disabledText
    }

    @ViewBuilder
    private var shortcut: some View {
        if isUnnamed {
            // The title already is the chord; printing it twice reads as two different keys.
            Color.clear.frame(width: keyColumn, height: 1)
        } else {
            // A command with no shortcut keeps the column: the dash says "none" without
            // letting the titles beside it shift left.
            Text(item.chord.isEmpty ? "—" : KeyFormatter.render(item.chord, style: style))
                .font(.system(size: TypeScale.callout, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(shortcutColor)
                .lineLimit(1)
                .frame(width: keyColumn, alignment: keyPosition == .left ? .leading : .trailing)
        }
    }

    private var shortcutColor: Color {
        if !isEnabled { return palette.disabledText }
        if item.chord.isEmpty { return palette.tertiaryText }
        return isSelected ? palette.text : palette.key
    }

    /// The row title with the query's characters emphasised.
    ///
    /// Built from runs, not from one `AttributedString` per character: the old version made a
    /// few thousand allocations for a full page of results and rebuilt them on every arrow
    /// key. Contiguous matched and unmatched characters share one run, so the same styling is
    /// produced with a handful of pieces.
    private var highlightedTitle: Text {
        let text = title
        let tokens = query
            .split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        let matched = matchedCharacterOffsets(in: text, tokens: tokens)

        var attributed = AttributedString()
        var run = ""
        var runIsMatched = false
        var offset = 0

        func flushRun() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            piece.font = .system(size: TypeScale.body, weight: runIsMatched ? .semibold : .regular)
            if runIsMatched { piece.foregroundColor = .accentColor }
            attributed.append(piece)
            run = ""
        }

        for character in text {
            let isMatched = matched.contains(offset)
            if isMatched != runIsMatched {
                flushRun()
                runIsMatched = isMatched
            }
            run.append(character)
            offset += 1
        }
        flushRun()
        return Text(attributed)
    }

    /// Every character offset the query covers. One pass per token over a one-line title, so
    /// this stays cheap even though it runs for every visible row.
    private func matchedCharacterOffsets(in text: String, tokens: [String]) -> Set<Int> {
        var matched = Set<Int>()
        for token in tokens {
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(
                      of: token,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: start..<text.endIndex
                  ) {
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                matched.formUnion(offset..<(offset + length))
                start = range.upperBound
            }
        }
        return matched
    }
}

/// The AppKit visual-effect layer behind the surface.
///
/// SwiftUI's `Material` cannot express the two materials this app uses — `.popover` for the
/// light theme and `.hudWindow` for the dark one — so the shell hosts one `NSVisualEffectView`
/// instead. It is decoration only: the palette tint on top of it keeps the text contrast.
private struct PanelSurfaceView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
