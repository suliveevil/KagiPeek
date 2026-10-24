import SwiftUI
import UniformTypeIdentifiers

/// One surface for both the shortcut panel and the search palette.
///
/// They share the window, the title bar (App identity, one search field, actions)
/// and the footer; only the content below the bar swaps. The panel's filter uses the
/// event tap (the panel never takes focus), while the search palette focuses a real
/// text field because its window is allowed to become key.
struct OverlayView: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var localization: Localization
    @State private var hoveredRowID: String?
    /// The row currently being clicked, held for one frame so a press is visible even when
    /// the action closes the panel straight away.
    @State private var pressedRowID: String?
    @State private var hoveredStarID: String?
    @FocusState private var searchFocused: Bool

    private var settings: AppSettingsSnapshot { settingsStore.settings }
    private var palette: PanelPalette { settings.panelTheme.palette }
    private var isSearch: Bool { engine.search.isVisible }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(palette.rule)
                .frame(height: 1)
            if isSearch {
                searchContent
            } else {
                panelContent
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.backgroundSolid)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(palette.border, lineWidth: Theme.increaseContrast ? 1.5 : 0.8)
                .decorative()
        )
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .onAppear {
            if isSearch {
                DispatchQueue.main.async { searchFocused = true }
            }
        }
        .onChange(of: engine.searchFocusToken) { _, _ in
            if isSearch { searchFocused = true }
        }
        .onChange(of: engine.search.isVisible) { _, visible in
            if visible {
                DispatchQueue.main.async { searchFocused = true }
            } else {
                searchFocused = false
            }
        }
        .onChange(of: engine.panel.appName) { _, _ in
            // A stale hover would paint a row for the previous app, which the pointer has
            // never been over.
            hoveredRowID = nil
            hoveredStarID = nil
        }
    }

    // MARK: - Title bar

    private var header: some View {
        GeometryReader { proxy in
            headerContent(layout: HeaderLayout(width: proxy.size.width))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: 54)
    }

    private func headerContent(layout: HeaderLayout) -> some View {
        HStack(spacing: 10) {
            // The palette is a second view of the same window, so it gets a way back. `/`
            // does the same thing, but only while the search field is not taking text — and
            // it usually is.
            if isSearch {
                Button(action: engine.returnToPanelFromSearch) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.hover, size: 20, cornerRadius: 5))
                .help(localization.text(.searchBackToPanel))
            }
            appIdentity(layout: layout)

            Spacer(minLength: 6)
            // The panel has no text field of its own any more: `/` opens the palette, which
            // is where typing belongs. A second, quieter search box in the panel only asked
            // the user to guess which one to use.
            if isSearch {
                searchField(layout: layout)
            }
            Spacer(minLength: 6)

            // Looking at another app and exporting what you see belong in the palette: it is
            // where the question is actually asked.
            if isSearch, layout != .minimal {
                searchScopeMenu
                Button { exportSearchMarkdown() } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.hover))
                .help(localization.text(.exportMarkdown))
            }

            if !isSearch, layout.showsModifierFilter {
                modifierChips
            }

            if !isSearch, layout.showsFavoritesToggle {
                Button(action: engine.toggleFavoritesFilter) {
                    Image(systemName: engine.showsFavoritesOnly ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(engine.showsFavoritesOnly ? Color.yellow : palette.secondaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.hover))
                .help(localization.text(.panelFavoritesFilter))
            }

            Button(action: engine.showSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
            }
            .buttonStyle(IconButtonStyle(hoverFill: palette.hover))
            .help(localization.text(.panelSettings))

            if engine.panel.isScanning {
                ProgressView().controlSize(.small).tint(palette.secondaryText)
            }
            if engine.panel.hasConflicts {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange.opacity(0.9))
                    .help(localization.text(.overlayConflictHint))
            }

            if layout.showsCount {
                Text(isSearch ? "\(engine.search.results.count)" : "\(engine.panel.totalCount)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.tertiaryText)
                    .monospacedDigit()
            }

            Button(action: dismissCurrentSurface) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
            }
            .buttonStyle(IconButtonStyle(hoverFill: palette.hover, size: 20, cornerRadius: 5))
            .help(localization.text(.panelClose))
        }
        .padding(.horizontal, 16)
    }

    /// Checkable ⌃ ⌥ ⇧ ⌘ chips: a sticky way to narrow by modifier.
    ///
    /// Holding a modifier still narrows too (which-key style), but a held key returns to the
    /// full list the moment it is released. A tick does not: it survives, it is visible, and
    /// a tick plus a key composes a stroke. Several ticks mean "carries all of these".
    private var modifierChips: some View {
        HStack(spacing: 1) {
            ForEach(ModifierSet.canonicalOrder, id: \.rawValue) { modifier in
                modifierChip(modifier)
            }
        }
        .help(localization.text(.panelModifierFilterHint))
    }

    private func modifierChip(_ modifier: ModifierSet) -> some View {
        // Ticking a chip narrows the list *and* composes a stroke (⌥ ticked + C pressed =
        // ⌥⌘C): the two readings share one state, which is why a tick reads as "ticked".
        let ticked = engine.panel.latchedModifiers.contains(modifier)
        let held = engine.panel.heldModifiers.contains(modifier)
        return Button {
            engine.toggleModifier(modifier)
        } label: {
            Text(KeyFormatter.symbol(for: modifier))
                .font(.system(size: 11.5, weight: ticked ? .bold : .medium, design: .rounded))
                .foregroundStyle(chipColor(ticked: ticked, held: held))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ticked ? Color.accentColor.opacity(palette.isLight ? 0.16 : 0.26) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(ticked ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
                        .decorative()
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(IconButtonStyle(hoverFill: palette.hover, size: 20, cornerRadius: 5))
        .accessibilityLabel(KeyFormatter.word(for: modifier))
        .accessibilityAddTraits(ticked ? [.isSelected] : [])
    }

    /// Ticked beats held: a chip that filters says so, a chip whose key happens to be down
    /// only hints at what the next key press would do.
    private func chipColor(ticked: Bool, held: Bool) -> Color {
        if ticked { return Color.accentColor }
        if held { return palette.text }
        return palette.secondaryText
    }

    /// The app identity used to be a button that closed the surface, which made a mis-click
    /// on the icon silently dismiss the panel. It now only identifies; closing has its own
    /// button and still works by clicking outside or pressing Esc.
    private func appIdentity(layout: HeaderLayout) -> some View {
        HStack(spacing: 11) {
            if let icon = isSearch ? engine.searchPaletteIcon : engine.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
            }
            if layout.showsAppName || layout.showsSubtitle {
                VStack(alignment: .leading, spacing: 2) {
                    if layout.showsAppName {
                        Text(isSearch ? engine.searchPaletteTitle : appTitle)
                            .font(.system(size: 15, weight: .semibold))
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
        engine.panel.appName.isEmpty ? localization.text(.appName) : engine.panel.appName
    }

    @ViewBuilder
    private var subtitle: some View {
        if isSearch {
            Text(localization.text(engine.search.scopeAppID == nil ? .searchSubtitle : .searchSubtitleScoped))
                .font(.system(size: 11))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
        } else if engine.panel.prefixLabels.isEmpty {
            Text(localization.text(.panelIdleHint))
                .font(.system(size: 11))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
        } else {
            HStack(spacing: 4) {
                ForEach(Array(engine.panel.prefixLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(palette.selection))
                        .foregroundStyle(palette.secondaryText)
                }
                if engine.panel.usedBuiltInCatalog {
                    // The rows are not this app's menus. Say so — and when the scan was
                    // blocked outright, say that too, instead of leaving the user to
                    // wonder why the app's own commands are missing.
                    Text(localization.text(engine.scanState == .permissionDenied ? .scanFallbackHint : .overlayBuiltInBadge))
                        .font(.system(size: 11))
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
            let apps = engine.runningApps.filter { $0.bundleID != Bundle.main.bundleIdentifier }
            if !apps.isEmpty { Divider() }
            ForEach(apps) { app in
                Button(app.name) { engine.selectSearchScope(app.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 11))
                Text(engine.search.scopeName.isEmpty
                     ? localization.text(.frontmostApp)
                     : engine.search.scopeName)
                    .font(.system(size: 11.5, weight: .medium))
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
        let panel = NSSavePanel()
        let title = engine.search.scopeName.isEmpty ? engine.appName : engine.search.scopeName
        panel.nameFieldStringValue = "\(title).md"
        panel.canCreateDirectories = true
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try engine.makeSearchMarkdown().write(to: url, atomically: true, encoding: .utf8)
            engine.showHUD(chord: "✓", title: localization.text(.exportMarkdown))
        } catch {
            engine.showHUD(chord: "!", title: error.localizedDescription)
        }
    }

    private func searchField(layout: HeaderLayout) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            TextField(localization.text(.searchPlaceholder), text: $engine.search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit {
                    engine.confirmSearchSelection()
                }
            if !engine.search.query.isEmpty {
                Button {
                    engine.search.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.selection, size: 18, cornerRadius: 4))
                .help(localization.text(.searchClearHint))
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: CGFloat(layout.fieldMin), idealWidth: CGFloat(layout.fieldIdeal),
               maxWidth: CGFloat(layout.fieldIdeal), minHeight: 28, maxHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(palette.rule, lineWidth: 1)
                .decorative()
        )
    }

    private func dismissCurrentSurface() {
        if isSearch { engine.hideSearch() } else { engine.dismissPanel() }
    }

    // MARK: - Panel content

    @ViewBuilder
    private var panelContent: some View {
        if engine.panel.isScanning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(palette.secondaryText)
                Text(localization.text(.overlayScanning))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        } else if engine.panel.isEmpty {
            // An empty panel and a scan that never happened look identical to the user;
            // the scan state says which one it was (Menu-Bar-Search's initState).
            let emptyKey: L10nKey = engine.scanState == .permissionDenied
                ? .scanPermissionDenied
                : (engine.panel.showsFavoritesOnly ? .panelNoFavorites : .overlayNoCandidates)
            Text(localization.text(emptyKey))
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
        } else {
            GeometryReader { proxy in
                let columns = max(1, min(settings.columnCount, OverlayMetrics.columns(forWidth: proxy.size.width)))
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
                    keyPosition: settings.keyPosition
                )
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: OverlayMetrics.cardGap) {
                        ForEach(engine.panel.groups) { group in
                            groupSection(group, columns: columns, layout: layout)
                        }
                    }
                    .padding(.horizontal, Theme.padding)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    /// One section of the panel, drawn as a card — the same treatment the search palette gives
    /// its categories: a title strip, a hairline under it, and a border around the whole block.
    ///
    /// The panel only ever has two sections (the app's commands and the system's hotkeys), and
    /// they used to be told apart by a heading in the middle of the list. A card makes the
    /// boundary a shape instead of a line of text: it survives scrolling, it survives the
    /// narrow layout, and it matches what the palette already looks like.
    private func groupSection(_ group: PanelGroup, columns: Int, layout: RowLayout.Metrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !group.title.isEmpty {
                HStack(spacing: 7) {
                    Text(group.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(palette.secondaryText)
                    Text("\(group.totalCount ?? group.rows.count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.tertiaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: Theme.groupHeaderHeight, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.selection)
                Rectangle()
                    .fill(palette.rule)
                    .frame(height: 1)
                    .decorative()
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 180), spacing: 18, alignment: .leading),
                               count: max(1, columns)),
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(group.rows) { row in
                    rowView(row, layout: layout)
                }
            }
            .padding(.horizontal, OverlayMetrics.cardHorizontalInset)
            .padding(.vertical, OverlayMetrics.cardVerticalInset)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.border, lineWidth: Theme.increaseContrast ? 1.5 : 1)
                .decorative()
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Three columns of fixed width, so the same field starts at the same x on every row:
    /// the command name, the menu path, and the chord with its trailing slot.
    private func rowView(_ row: PanelRow, layout: RowLayout.Metrics) -> some View {
        // A dimmed row carries index -1, exactly like the "nothing selected" marker, so
        // comparing the two lit up every dimmed row. Only a real position can be selected.
        let isSelected = row.index >= 0 && engine.panel.selectionIndex == row.index
        let isHovered = hoveredRowID == row.id
        let fill: Color = {
            if row.isCompleted { return Color.accentColor.opacity(0.38) }
            if pressedRowID == row.id { return Color.accentColor.opacity(0.28) }
            if isSelected { return palette.selection }
            if isHovered { return palette.hover }
            return .clear
        }()
        return HStack(spacing: Theme.rowColumnGap) {
            if settings.keyPosition == .left {
                keyLabel(row, width: layout.keyWidth, alignment: .leading)
            }
            titleColumn(row, width: layout.titleWidth)
            if settings.keyPosition == .left {
                // Key · command · path — the path and the trailing slot travel together, so
                // the row still has three columns and the chord keeps the opposite end.
                HStack(spacing: Theme.rowColumnGap) {
                    if layout.showsNote { noteColumn(row, width: layout.noteWidth) }
                    gutter(row)
                }
            } else {
                if layout.showsNote { noteColumn(row, width: layout.noteWidth) }
                HStack(spacing: Theme.rowColumnGap) {
                    gutter(row)
                    keyLabel(row, width: layout.keyWidth, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, Theme.rowHorizontalPadding)
        .frame(height: Theme.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill)
        )
        // The selection marker sits in the row's own gutter: appearing and disappearing
        // must never reflow the title or the keycap.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 2.5, height: 12)
                .padding(.leading, 2)
                .scaleEffect(x: 1, y: isSelected ? 1 : 0.2, anchor: .center)
                .opacity(isSelected ? 1 : 0)
                .decorative()
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredRowID = inside ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
            if inside {
                engine.select(rowID: row.id)
            }
        }
        .onTapGesture {
            press(row.id)
            // A click means "run": the run key's action, whatever key that ends up being.
            engine.performPanelRow(rowID: row.id, action: .execute)
        }
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .contextMenu {
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
        let visible = hoveredRowID == row.id || row.isFavorite
        let lit = hoveredStarID == row.id
        return Image(systemName: row.isFavorite ? "star.fill" : "star")
            .font(.system(size: 9.5))
            .foregroundStyle(row.isFavorite ? Color.yellow : palette.tertiaryText)
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

    /// The command name: whatever width is left once every other column is reserved.
    ///
    /// A fixed width, not a natural one — the menu path has to start at the same x on every
    /// row, and that is only true if this column does not grow and shrink with its text.
    private func titleColumn(_ row: PanelRow, width: Double) -> some View {
        Text(row.title)
            .font(.system(size: 13.5, weight: row.isCompleted ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(rowTitleColor(row))
            .frame(width: width, alignment: .leading)
    }

    /// The menu path, with the "has a sub-level" chevron in a slot of its own at the left.
    ///
    /// Truncated in the middle: the head of a path ("File") and its last step are the parts
    /// that tell the user where the command lives, so those are what survive.
    private func noteColumn(_ row: PanelRow, width: Double) -> some View {
        Text(row.note)
            .font(.system(size: 10.5))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(palette.tertiaryText)
            .frame(width: width, alignment: .leading)
    }

    /// The row's trailing slot: conflict badge, sub-level chevron and favourite star, always
    /// the same width.
    ///
    /// The badge used to be added only when there was a conflict, which moved the chord
    /// about 17pt to the left on exactly the rows where the user was being warned about
    /// something. Both markers are now always there and simply go transparent.
    ///
    /// The chevron lives here rather than beside the menu path so that it survives the narrow
    /// panel, where the menu path column is dropped: a row with a level below it must stay
    /// recognisable whichever columns are showing.
    private func gutter(_ row: PanelRow) -> some View {
        HStack(spacing: RowLayout.gutterSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange.opacity(0.85))
                .frame(width: 12)
                .opacity(row.hasConflict ? 1 : 0)
                .accessibilityHidden(!row.hasConflict)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
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
        HStack(spacing: 0) {
            ForEach(Array(row.keySegments.enumerated()), id: \.offset) { _, segment in
                Text(segment.text)
                    .font(.system(
                        size: 12.5,
                        weight: isEmphasized(segment) ? .bold : .semibold,
                        design: .rounded
                    ))
                    .foregroundStyle(keySegmentColor(row, segment))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(width: width, alignment: alignment)
    }

    /// Modifiers whose glyph is lit: the ones physically down and the ones ticked in the
    /// title bar. Both mean "this shortcut is about ⌘"; one is transient, one is deliberate.
    ///
    /// A ticked modifier lights up because the row it affects is about that modifier, whether
    /// the tick was meant as "narrow to these" or as the first half of a stroke.
    private var emphasizedModifiers: ModifierSet {
        engine.panel.heldModifiers.union(engine.panel.latchedModifiers)
    }

    private func isEmphasized(_ segment: KeyFormatter.Segment) -> Bool {
        guard case .modifier(let modifier) = segment.kind else { return false }
        return emphasizedModifiers.contains(modifier)
    }

    private func rowTitleColor(_ row: PanelRow) -> Color {
        if row.isCompleted { return palette.text }
        if !row.isEnabled { return palette.tertiaryText }
        return row.isHighlighted ? palette.text : palette.text.opacity(0.88)
    }

    private func keySegmentColor(_ row: PanelRow, _ segment: KeyFormatter.Segment) -> Color {
        if !row.isEnabled { return palette.tertiaryText }
        if isEmphasized(segment) { return palette.keyHighlight }
        if row.isCompleted { return palette.text }
        return palette.key
    }

    // MARK: - Search content

    private var searchContent: some View {
        VStack(spacing: 0) {
            // A query that spells out a combo gets its own answer above the list. Without
            // it, a combo only one thing owns comes back as an empty list, which reads as
            // "not scanned" rather than "nobody else wants this".
            if let answer = engine.search.comboAnswer {
                ComboLookupBanner(answer: answer, palette: palette)
            }
            Group {
                if engine.search.results.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(palette.tertiaryText)
                        Text(localization.text(.searchNoResults))
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SearchResultList(
                        sections: searchSections,
                        selection: engine.search.selection,
                        query: engine.search.query,
                        style: settings.keyStyle,
                        keyPosition: settings.keyPosition,
                        palette: palette,
                        onTap: { engine.activateSearchResult($0) },
                        onHover: { engine.selectSearchResult($0) }
                    )
                }
            }
        }
    }

    private var searchSections: [SearchSection] {
        var order: [String] = []
        var rows: [String: [(Int, BindingItem)]] = [:]
        for (index, item) in engine.search.results.enumerated() {
            let key = item.displayGroup
            if rows[key] == nil { order.append(key) }
            rows[key, default: []].append((index, item))
        }
        return order.map { SearchSection(id: $0, title: $0, rows: rows[$0] ?? []) }
    }

    // MARK: - Footer

    private var footer: some View {
        GeometryReader { proxy in
            footerContent(layout: HeaderLayout(width: proxy.size.width))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: 32)
    }

    private func footerContent(layout: HeaderLayout) -> some View {
        HStack(spacing: 8) {
            if isSearch {
                Text(engine.search.results.count == 1
                     ? localization.text(.searchResultCountOne)
                     : localization.format(.searchResultCount, engine.search.results.count))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(palette.tertiaryText)
            } else if engine.panel.pageCount > 1 {
                Button(action: engine.previousPage) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.hover, size: 22, cornerRadius: 5))
                .disabled(engine.panel.pageIndex == 0)
                .help(localization.text(.panelPreviousPage))

                Text(localization.format(.overlayPageFormat, engine.panel.pageIndex + 1, engine.panel.pageCount))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryText)

                Button(action: engine.nextPage) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(IconButtonStyle(hoverFill: palette.hover, size: 22, cornerRadius: 5))
                .disabled(engine.panel.pageIndex >= engine.panel.pageCount - 1)
                .help(localization.text(.panelNextPage))
            } else {
                Text(engine.panel.appName)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
            }

            Spacer()
            Text(footerHint(layout: layout))
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryText)
                .lineLimit(1)
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
        guard engine.panel.isPinned else { return localization.text(.overlayHint) }
        let run = KeyFormatter.render(settings.runRowKey.chord, style: settings.keyStyle)
        let copy = KeyFormatter.render(settings.copyRowKey.chord, style: settings.keyStyle)
        switch layout {
        case .full:
            return localization.format(.panelActionHintSearch, run, copy)
        case .tight:
            return localization.format(.panelActionHint, run, copy)
        case .minimal:
            return localization.format(.panelActionHintCompact, run, "")
        }
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
    let query: String
    let style: KeyFormatter.Style
    let keyPosition: KeyPosition
    let palette: PanelPalette
    let onTap: (Int) -> Void
    let onHover: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(sections) { section in
                        sectionCard(section)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .onChange(of: selection) { _, newValue in
                scroll(to: newValue, proxy: proxy)
            }
        }
    }

    private func sectionCard(_ section: SearchSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(section.title.isEmpty ? "—" : section.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                Text("\(section.rows.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
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
                        query: query,
                        style: style,
                        keyPosition: keyPosition,
                        isSelected: index == selection,
                        palette: palette
                    )
                    .id(item.id)
                    .onHover { inside in
                        if inside { onHover(index) }
                    }
                    .onTapGesture { onTap(index) }
                }
            }
            .padding(.vertical, 4)
        }
        // One step louder than the palette background, and an edge that survives it: the
        // card has to read as a card at a glance, or the grouping is only a heading again.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.border, lineWidth: Theme.increaseContrast ? 1.5 : 1)
                .decorative()
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    let query: String
    let style: KeyFormatter.Style
    let keyPosition: KeyPosition
    let isSelected: Bool
    let palette: PanelPalette

    /// The shortcut column never moves, whichever app the palette is looking at: that is
    /// what lets the eye run down one column and ignore the text beside it.
    private let keyColumn: CGFloat = 78

    var body: some View {
        HStack(spacing: 12) {
            if keyPosition == .left { shortcut }
            titleBlock
            Spacer(minLength: 8)
            if keyPosition == .right { shortcut }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
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
    }

    /// The menu item, and under it where the item lives — the description that turns
    /// "Copy Style" into a location when three apps have a command by that name.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            highlightedTitle
                .lineLimit(1)
                .truncationMode(.tail)
            if let subgroup = item.subgroup {
                Text(subgroup)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var shortcut: some View {
        // A command with no shortcut keeps the column: the dash says "none" without
        // letting the titles beside it shift left.
        Text(item.chord.isEmpty ? "—" : KeyFormatter.render(item.chord, style: style))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(item.chord.isEmpty
                             ? palette.tertiaryText
                             : (isSelected ? palette.text : palette.key))
            .lineLimit(1)
            .frame(width: keyColumn, alignment: keyPosition == .left ? .leading : .trailing)
    }

    private var highlightedTitle: Text {
        let text = item.title
        var matched = Set<Int>()
        let tokens = query
            .split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        for token in tokens {
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                for position in offset..<(offset + length) {
                    matched.insert(position)
                }
                start = range.upperBound
            }
        }
        var attributed = AttributedString()
        for (position, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            piece.font = .system(size: 13.5)
            if matched.contains(position) {
                piece.font = .system(size: 13.5, weight: .semibold)
                piece.foregroundColor = .accentColor
            }
            attributed.append(piece)
        }
        return Text(attributed)
    }
}
