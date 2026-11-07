# STATUS

[English](STATUS.md) · [中文](../zh-CN/STATUS.md)


as of **2026-11-06** (Asia/Shanghai).

**Stale means void: this file records only what was true at the moment it was written.** Before
taking over, run `git log -1`, run `swift test` once, then re-run the commands under "Last
verification" below; wherever any item disagrees with the current output, the current output wins —
update this file before relying on it again.

## Current code state

- Code HEAD: `b53c252` (`feat(trigger)`: writes `kaname_panel` into Karabiner while the panel is
  open, so a rule bound to the trigger key stands down), version **2.3.1 (build 231)**, tag
  `v2.3.1` created locally. Below it: `63b3bbb` (`docs(status)`) records the 2.3.0 Homebrew install,
  and `bf79a82` (`fix(cask)`) plus `87ebff4` (2.3.0 release prep: rename, four-page settings
  restructure, design-review fixes, build-script hardening).
  `/Applications/Kaname.app` was built and installed from `63b3bbb-dirty` on 2026-11-06 22:57 —
  **the behaviour is the new one, but `KanameCommit` reads `63b3bbb-dirty` and the version string
  is still 2.3.0 (230)**; showing 2.3.1 requires another `./scripts/install.sh` run.
- Tags: annotated tag `v2.3.0` exists locally and on the remote (tag object `014d4531`, pointing at
  `87ebff4`). The pre-rename `v1.0.0` / `v1.1.0` / `v1.2.0` / `v2.0.0` / `v2.2.0` were deleted,
  leaving only `v2.1.0` and `v2.3.0`; reachability from `main` was confirmed before deleting, and no
  historical tags were force-pushed to the remote.
- Branches: `main` is pushed (`origin/main` = `bf79a82`). This round's short-lived branches
  `chore/cask-render`, `chore/homebrew-tap` and `fix/cask-app-stanza` were merged and deleted.
  Locally there remain the development branch `feature/panel-sections` and the old-history backup
  `backup/pre-squash-20261104-192838`.
- `swift test --disable-sandbox` was last recorded at `b53c252` as 850/0 (including the five new
  `KarabinerPanelSignalTests`); `scripts/build_release.sh` (`KANAME_SKIP_DMG=1`, external terminal)
  reported `BUILD SUCCEEDED` on the same code, with a product plist of `2.3.1` / `231`.
- Settings schema: 11. v11 added `karabinerPanelSignalEnabled` (default `true`, no migration step);
  v10's `usageSortField` (default `shortcut`, `sortMode` removed), v9's `showConfigToolsInPanel`
  (default `false`) and `scanConfigFiles` keep their original values.

## Completed this round

- **Karabiner panel signal (option 3, `b53c252`, tag `v2.3.1`)**: writes the Karabiner variable
  `kaname_panel=1` while the panel is visible, 0 when it closes, and 0 on start and exit (so a
  crash cannot leave behind a 1 that suppresses the user's rule). `Core/Pure/KarabinerPanelSignal`
  owns only the variable name, the payload and the "panel visible and switch on" decision;
  `Core/Services/KarabinerBridge` is the transport layer: private serial queue, coalescing debounce,
  `lastWritten` dedupe, `Process` calling `karabiner_cli --set-variables` (stdout/stderr to
  `nullDevice`), a single `[settings]` warning on failure, and `clearAndWait()` writing 0
  synchronously on the exit path (each child wait capped at `writeTimeout` = 0.8 s, then
  terminated and logged). `ShortcutEngine` calls `signalKarabiner()` from `start()` /
  `activatePanel()` / `dismissPanel()` / `stop()` and on a switch flip. The settings page gained the
  "Trigger → Tell Karabiner when the panel is open" switch plus a not-installed notice, and three
  L10n strings in each language. On the user's side their own rule still needs
  `conditions: [{"type": "variable_unless", "name": "kaname_panel", "value": 1}]` — `variable_unless`
  rather than `variable_if`, because the latter fires *only* while the panel is open, exactly
  backwards. Option 1 (recording-style trigger key) and option 2 (conflict detection covering bare
  modifier rules) were explicitly rejected by the user and are not implemented.

- **Settings restructure (four batches of changes; "four pages" in the branch names and commit
  messages means four batches, not four pages)**: the General page's "use built-in shortcuts when
  menus are unavailable" and "include the Apple menu when scanning" merged into the "ignored menu
  items" card; the execution toast was renamed "show a shortcut-fired notice after execution". The
  Trigger page's two switches moved to the left of the card headers, and the "enable" row and
  "replay the trigger tip" were removed. The Appearance page's two numbers became typed inputs
  (6–60 / 8–80, committed on Return or focus loss, out-of-range keeps the old value and warns for
  three seconds), and the two favourites options became their own card. The Statistics page became
  one flat row per `usageKey`, the shortcut first and the app plus command description as the
  row's note, sortable by shortcut / app / command. Added `UsageSorting`, `NumericSettingInput`,
  `UsageBreakdown.entries(records:known:)` and `EngineState.usageBreakdownAllCache`; removed
  `Ranker`, `UsageOrdering`, `RankMode`, `summariesByApp()` and their tests.

- **Config tool section: per-tool folding plus hidden by default** (`c696f0c`, `321cf2a`): the
  fold state went from a single `toolSectionExpanded: Bool` to `expandedTools: Set<ConfigTool>`,
  with `PanelGroup.tool` carrying the tool identity onto the card, so a click toggles only the card
  that was clicked; when `narrowing = !filter.isEmpty`, `ToolSectionFold` opens every tool card
  temporarily, `expandedTools` is never written by filtering, and clearing the filter restores the
  user's manual folds. Added `showConfigToolsInPanel` (default `false`; the settings page puts it
  under "Conflicts → Config files", copy: "show config tools in the panel and search palette" plus
  "affects display only: these config files are still scanned and conflict detection still works");
  when off, the panel generates no tool cards and spends no row budget, the panel's inline filter
  corpus and the palette's corpus exclude tool rows, and the combo answer still reads
  `configBindings`. `apply(settings:)` invalidates `searchCorpus` / `panelFilterCorpus` /
  `rowBudgetCache` together. Added `ToolSectionFoldTests`,
  `PanelSectionsTests.testHiddenConfigToolsContributeNoRowsOrCards` and the `SettingsDefaultsTests`
  migration case; `swift test` 844 → 849.

- **Panel modifier + letter mixed filtering** (`428c925`): `Core/Pure/PanelFilter` keeps the
  filter condition in an ordered token queue — a modifier enqueues once on the press edge, a letter
  key appends a lowercase token; `⌫` pops the tail (delete the letter if the letter came last,
  remove that modifier if a modifier did), pressing the same modifier again removes it from any
  position in the queue, and a third press enqueues it as a new tail (a pure toggle). A release
  never flips anything, holding enqueues once and the condition stays (latched); the trigger key's
  own press is not enqueued. `Core/Pure/PanelFilterPlan.matchingIDs` reuses `SearchCorpus.search`
  with `PanelFilter.query` (modifier glyphs + lowercase letters) instead of building a second
  matcher; an empty queue returns the full list on page one, and when the result shrinks
  `panelPage` clamps the page to the last one. Shift remains only the `0–9` / `a–z` hint layer;
  outside `.active` (the search palette, for instance) letters stay in the field; the arrows and
  the four paging pairs are unaffected, and the `PanelTriggerNarrow` rule that the trigger key does
  not narrow is unchanged. Added `PanelFilterTests`, `PanelFilterPlanTests`; `swift test`
  726 → 741. A later fix narrowed the letter rule: only a *bare* letter becomes a token, so
  ⌥⌘M / ⌥⌘F stay chords while their modifiers narrow the list, and a leading three-state
  dot from `PanelTriggerAudit` shows each row's execution status — red only when both paths fail.
- **Focus-loss dismissal and trigger self-heal** (working tree, uncommitted): `activatePanel()`
  records the owner pid; `NSWorkspace.didDeactivateApplicationNotification` closes the panel
  when that app is no longer in front. `Core/Pure/FocusChangeGate.swift` holds both
  `FocusDismissPolicy` (live menu-bar owner, ignores self hand-offs and previews) and
  `FocusRescanGate` (one dismiss and one merged rescan per episode). `healStalePanelOwner()`
  on the trigger path covers switches that delivered no notification, so the first press
  opens a fresh panel. Added `FocusChangeGateTests`; `swift test` 900 → 913.
- **Panel geometry invalidation and Space rescan (G1–G4)**: `containedFrame` now clamps the size to
  the visible area first, then decides per direction whether the 8 pt `screenMargin` still fits —
  taking 0 for that direction when it does not, so a screen-sized frame is no longer pushed off
  the display (`80d5810`). Added the pure type `PanelAnchorCache` (`invalidate` /
  `beginRead(pid:)` / `apply`, with results for a stale pid dropped);
  `SurfacePanelController.hide()` cancels the in-flight `geometryTask`, resets
  `isRefreshingGeometry` and clears the snapshot, and the controller observes Space and screen
  parameter changes itself to clear the snapshot and re-read in the background on the next
  presentation; while there is no snapshot, `OverlayPlacement.coverSize` falls back to the whole
  visible area, so the first frame already covers (`29f1f8f`). Added
  `topInset(safeAreaTop:) = max(safeAreaTop, screenMargin)`, `fillScreenFrame` (shrinks height only,
  leaves the origin alone) and `clampedTop`; `.fillScreen` avoids the top safe area, and
  `.fixedSize` / `.coverWindow` no longer push into the menu bar or the notch after
  `containedFrame` (`c28895e`). Added `SpaceRescanGate` (0.75 s, debounced per pid) and
  `CatalogPublishPolicy`: switching Space calls `dismissEverything()` first, then forces a rescan
  of the current frontmost app, logging `space changed → forced rescan <app>`;
  `CatalogCoordinator.reload`'s `preserveOnEmpty` keeps the previous catalog and resets the loading
  state when the list is empty and there is no menu bar (`bd2b6b0`). Added
  `PanelAnchorCacheTests`, `SpaceRescanGateTests` and `OverlayGeometryTests`; `swift test`
  708 → 726.
- **Panel readability, settings window and material pass** (baseline `553fcca`, three groups of
  commits this round): the selected menu item gets a 3 pt highlight bar on its leading edge and a
  brighter title, VoiceOver exposes `.isSelected`, the reading order is "menu item name → shortcut
  → state", the row container went from `.ignore` to `.contain`, and decorative elements are
  `accessibilityHidden`; an unavailable menu item gets a trailing `lock.slash`, its context menu
  opens with "this menu item is unavailable right now", clicking shows an explanatory HUD, and
  `DisabledNoticeGate` (a pure type) limits the same menu item to one notice per three seconds.
  Added `PanelEmptyKind` (a pure enum) unifying the four empty states with the priority "permission
  not ready > scanning > no match", the permission state carrying "open the permission guide".
  `maxItemsPerPage` is now explicitly an upper bound, with the actual value
  `min(setting, geometric capacity)`; the settings copy became "每个分组最多显示 N 个菜单项 /
  Max menu items per group"; a group heading is drawn only under "by menu bar group" and counted
  separately into the height. The shortcut column uses a monospaced face, a fixed width and
  trailing alignment by default, blank when there is no shortcut; a pure selection writes only
  `panelSelectionIndex` without rebuilding the panel, the selected state transitions over 0.1 s,
  and `MenuTrigger.press` leaves the main thread with `@concurrent` and a 250 ms timeout. Switching
  the panel sort order flashes one HUD line instead of a permanent label. First launch shows one
  `KanameTriggerTipShown` tip, replayable from the Trigger page. The settings window's `styleMask`
  drops `.miniaturizable`, and the permission guide attaches as a sheet while Settings is visible.
  Materials became `.popover` for light and `.hudWindow` for dark, with a 16 pt outer margin, 8/10
  content padding and a 12 pt corner radius. Added `DisabledNoticeGateTests`,
  `PanelEmptyKindTests`; `swift test` 693 → 708.
- **The footer no longer covers menu items** (`fix/panel-footer-clearance`): `OverlayMetrics`
  folds the 54 pt header, 1 pt divider, 32 pt footer and 18 pt list padding into `chromeHeight`, and
  the three fixed SwiftUI heights read the same constants, so the footer is a sibling of the
  content area rather than an overlay. Added `rowsPerColumn` / `fittedPageSize`: rows per page is
  `min(setting, geometric capacity)`, so 60 rows in a 720 pt two-card window drops to 36; integer
  rounding carries a 1e-4 tolerance so an exact N rows is not scaled into N−1; even when not one
  row fits, one row is still shown. `OverlayPlacement.containedFrame` moves a panel hugging the
  bottom of the screen up as a whole instead of clipping the last rows. Removed the 18 pt fade at
  the bottom of the content area — it covered the last row. `swift test` 684 → 693.
- **Paging key pairs became configurable (`feature/paging-key-pair`, merged into main)**: added
  `Core/Pure/PagingKeyPlan`, with four pairs (`,`/`.`、`[`/`]`、`-`/`=`、`;`/`'`) decided by the
  character actually produced, the physical key code serving only as a fallback when the event has
  no decoded character; Settings → General → Menu item actions now holds four checkboxes, several
  pairs can be on at once or none at all, and only `;`/`'` is checked by default (the pair that
  used to be hard-coded); ←/→ work permanently and are not part of the settings group. While the
  search field has focus, all eight characters pass through as input; when the Shift hint layer is
  active, `+` (Shift+=) is neither a paging key nor a `0-9/a-z` hint label and lands in the front
  app as ordinary input. Settings schema 7→8: a missing field → default `;`/`'`, unknown members of
  the set dropped rather than rolling the whole file back; `apply(settings:)` and
  `logSettingsDelta` keep the set field in sync. `swift test` 768 → 789.
- **Panel placement fixes** (commits in `git log`): the shortcut panel's `coverWindow` height is no
  longer replaced wholesale by the content height, but takes the larger of the cover height and
  the content height clamped into the visible area; horizontally it is still centred on the
  screen's visible area. The search palette changed from "centred on screen, 680×460, 140 pt from
  the top" to "centred on the front window": width fixed at 680, height at least the front
  window's height (clamped into the visible area), the frame based on the window's centre and
  clamped back into the visible area, falling back to the screen centre when there is no window
  frame; the front pid is read before `NSApp.activate()`. Added `Core/Pure/OverlayPlacement` to
  carry this geometry, `swift test` 672 → 682; two more fullscreen boundary assertions (with the
  front window filling the screen, `visibleFrame == screen.frame`, the 24 pt margin clipped, the
  shortcut panel exactly the screen, the palette's height taking the screen height) brought it to
  684.
- **First-frame coverage after a front-app switch**: the window frame in `SurfacePanelController`
  is read asynchronously, so after switching to a new app the first modifier hold finds
  `anchorWindowFrame` still nil and draws the panel at the 0.8×0.7 fallback size, after which
  `refreshGeometry` only moves it and keeps the fallback size — coverage therefore waited for the
  modifier release and another `presentPanel`. The fallback size is now the whole visible area
  (every window is inside it), and once the geometry arrives the size is recomputed by the same
  rules `presentPanel` uses before positioning, so the first frame already covers.
- **Settings copy and trigger cards** (`d4321ea`): `rankingModeHint` became "panel order is set on
  the Appearance page; the search palette sorts by match quality"; the panel-tip footnote wrongly
  attached to the Trigger page was removed. The Trigger page split into two cards, "修饰键触发 /
  Modifier trigger" and "快捷键触发 / Shortcut trigger", each with its own enable switch.
- **Preset shortcuts can be deleted** (`d4321ea`): the five binding slots (the three global
  hotkeys — panel, search, switch — plus row run and copy) became `HotkeySpec?`, with `nil`
  meaning unset; `L10n` gained "unset / delete / enable". Each row on the settings page has a
  delete button; once cleared, routing and swallow rules skip that slot and the panel footer
  degrades to the remaining keys; JSON writes `null`, a missing field still falls back to the
  default, and the schema stays at 7. `swift test` stays at 672.
- **Signing key moved into its own keychain** (`a0b1401`): added
  `~/Library/Keychains/kaname-signing.keychain-db`, passphrase at
  `~/Library/Application Support/Kaname/signing/keychain-pass` (600, directory 700); the `.p12`
  backup sits in the same directory (600). The identity is still the original certificate (SHA-1
  `6c0ac5…a929`), the copy in the login keychain was deleted, and
  `security find-identity -v -p codesigning` returns exactly one. `build_swiftc.sh` unlocks it
  automatically and passes an explicit `--keychain`; `setup_signing.sh` now creates the identity
  directly in the new keychain.
- **Unpushed history cleanup**: the 72 commits above `origin/main` (59 ordinary commits plus 13
  merges) were squashed into one; no code content was lost, and only stale test counts and commit
  examples in STATUS, ARCHITECTURE and the design draft were cleared along the way. The old
  history is kept locally as `backup/pre-squash-20261104-192838` (tag and branch, neither pushed);
  the rewritten `main` was force-pushed to `origin/main` with `--force-with-lease`.
- **Engine collaboration modules split out (R-3)**: `ShortcutEngine` went from 2,761 lines / 139
  functions to 1,541 lines / 103 functions; added `BindingEditor`, `RowRunner`,
  `CatalogCoordinator`, `SearchSession`, `LiveTestCoordinator`, `DiagnosticsReporter`,
  `PanelSession`, and pushed the recording rules and search-scope switching down into
  `Core/Pure/RecordingPolicy` and `Core/Pure/SearchScopePlan`. InputRouter stays in the engine
  permanently, as planned. Details in `outputs/refactor-engine.md`.
- **Panel paging closed loop**: `Core/Pure/PaginationPlan` implements wrap-around and page
  clamping; with a single page neither key acts, nothing is rebuilt and nothing flashes. The page
  semantics are unchanged; the key source later moved to `PagingKeyPlan` (see this round's entry).
- **Settings diagnostics merged**: the About page's diagnostics block (Accessibility, Input
  Monitoring, listening state, menu item count, export diagnostics report, explanation) moved
  wholesale onto the Diagnostics page, after the log folder and before the privacy note; the About
  page keeps only icon/version, system version, update check, data folder, repository and licence.
  `exportDiagnostics()` moved to the diagnostics block; behaviour and file name
  (`kaname-diagnostics.json`) unchanged.
- **Backup and signing conventions landed (scripts and docs only, not built, not installed)**: added
  `scripts/backup_app.sh` (backs up to `~/Library/Application Support/Kaname/backups/`, named
  `Kaname-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app`, keeping 5 by default);
  `scripts/install.sh` now calls it, refuses to install an ad-hoc bundle, and rolls back by
  restoring from backups.
- **Panel sort order became switchable (`feature/panel-sort`, fast-forwarded into main)**: the
  Appearance page added a "面板排序 / Panel order" segmented control after "key position", with two
  mutually exclusive options: "按修饰键 / By modifier" (the default, behaving exactly as before)
  and "按菜单栏分组 / By menu group". Added `Core/Pure/PanelSortOrder`: by menu bar group, the
  first component of `axPath` (the menu bar index) is the group order, menu items of the same
  top-level menu appear contiguously, and inside a group the shortcut order still applies; groups
  without an `axPath` sort after indexed groups, with an empty group last. The Shift hint layer's
  `0-9/a-z` is assigned from the displayed sequence on every rebuild, so after a reorder the same
  key points at the menu item in its new position instead of being pinned to an entry. Settings
  schema 5→6: a v5 file missing `panelOrder` migrates to the default "by modifier", and hand-written
  old JSON and corrupt-file fallback both go through the same `decodeIfPresent` path;
  `apply(settings:)` and `logSettingsDelta` keep the new field in sync, the sort cache key
  (`OrderedHitsKey`) gains `panelOrder`, and an already open panel re-sorts immediately.
- `swift test`: 656 → 666 (10 new cases covering both orders, group contiguity, the group-order
  source, no-group/empty-group fallbacks, Shift labels following the order, defaults and the
  schema 5→6 migration, encoding and round trip, and corrupt JSON).
- **Double tap became an automatic window (`feature/auto-double-tap`, fast-forwarded into main)**:
  removed the "double-tap interval" slider and the `doubleTapWindow` field from the settings page;
  added `Core/Pure/DoubleTapTiming`, whose window follows the system "double-click speed"
  (`NSEvent.doubleClickInterval`) clamped to 0.25–0.6 s. The test became "two clean presses with no
  other key in between, timing only the gap between them": a slow press still counts, a long second
  press still completes on release; pressing another key still cancels. Settings schema 6→7, the
  old field is ignored and dropped on the next save; the Diagnostics page shows the currently
  effective window read-only. `swift test` 666 → 672.
- **Terminology unified on "menu item"** (commit `05c775f`): the object itself is now called
  "菜单项 / menu item", "快捷键" refers only to a menu item's keyboard shortcut (blank when there
  is none, no longer "no shortcut"), and "行 / row" is used only for layout; counts read
  "菜单项数". The change touched both columns of `L10n`, the shortcut-less rendering in
  `PanelSession`, and README, ARCHITECTURE, FAQ, TROUBLESHOOTING, RELEASING, PERMISSIONS, STATUS
  and the design draft; code identifiers (`RowID`, `rowKey`, `RowRunner`, …) were not touched.
- **`install.sh` signing gate fix** (commits `a31044d`, `05e424e`): `codesign -dv` cannot read
  `Authority`, so it became `-dvvv`; then `codesign | grep -q` under `pipefail` was found to
  misjudge through SIGPIPE, so output is captured and matched with `case` instead. A stably signed
  bundle is no longer wrongly rejected.

## Last verification

Everything below is a command actually run and its output, not an inference.

| Command | Result |
| --- | --- |
| `swift test` (before this install) | `Executed 684 tests, with 0 failures (0 unexpected)`; exit code 0 |
| `swift test` (before this round's UI batch commits) | `Executed 708 tests, with 0 failures (0 unexpected)`; exit code 0 |
| `swift test` (G1–G4 code batch) | `Executed 726 tests, with 0 failures (0 unexpected)`; exit code 0 |
| `swift test` (panel filter commit `428c925`) | `Executed 741 tests, with 0 failures (0 unexpected)`; exit code 0 |
| `swift test` (panel three-source sections + restricted actions) | `Executed 768 tests, with 0 failures (0 unexpected)`; exit code 0 |
| `swift test` (after merging the paging key pair `feature/paging-key-pair`) | `Executed 789 tests, with 0 failures (0 unexpected)`; exit code 0 |
| `swift test` (per-tool folding `c696f0c`) | `Executed 844 tests, with 0 failures (0 unexpected)`; exit code 0 |
| `swift test` (display switch `321cf2a`, 2026-11-06) | `Executed 849 tests, with 0 failures (0 unexpected)`; exit code 0 |
| `swift test` (after rename B5–B7, 2026-11-06) | `Executed 855 tests, with 0 failures (0 unexpected)`; exit code 0 |
| `scripts/build_swiftc.sh Release` (2026-11-06 09:28) | `==> Signing with Kaname Local`; `codesign --verify --strict` passes |
| `security find-identity ... kaname-signing.keychain-db` | Only `E40CFAA44DE724347FA66BB0BF84E2D58953C17E "Kaname Local"` |
| `codesign -d -r- /Applications/Kaname.app` | `identifier "com.suliveevil.kaname" and certificate root = H"e40cfaa4…c17e"` |
| `codesign -dvvv /Applications/Kaname.app` | `Authority=Kaname Local`; `Identifier=com.suliveevil.kaname`; `flags=0x10000(runtime)` |
| `scripts/install.sh` (`KANAME_SKIP_BUILD=1`, 2026-11-06 09:29) | Signed with `Kaname Local`; the old `Kaname.app` backed up to the new directory, then removed |
| `KanameCommit` / version string | `00cc7bf` / `2.2.0 (220)` |
| `pgrep -lf Kaname.app/Contents/MacOS` | `74955 /Applications/Kaname.app/Contents/MacOS/Kaname` (single instance) |
| `scripts/build_release.sh` (external terminal, 2026-11-06) | exit 0; `Kaname-2.3.0.dmg` 5,923,984 bytes; sha256 `0cdcc82c…938d` |
| `gh release create v2.3.0` | Assets `Kaname-2.3.0.dmg` (digest `sha256:0cdcc82c…938d`) and `Kaname-2.3.0.dmg.sha256` |
| `brew install --cask kaname` (external terminal) | exit 0; `kaname was successfully installed!` |
| Info.plist after install | `com.suliveevil.kaname` / `2.3.0` / `230` / `KanameCommit=87ebff4` |
| `codesign --verify --strict /Applications/Kaname.app` | Passes; `Authority=Kaname Local`; `TeamIdentifier=not set` |
| `pgrep -lf Kaname.app/Contents/MacOS` | Single instance (PID 10769) |
| `spctl -a -vv /Applications/Kaname.app` | `rejected` (not notarized, expected) |
| `brew list --cask kaname` | `2.3.0` (`/opt/homebrew/Caskroom/kaname/2.3.0/Kaname.app`) |

The currently installed Info.plist carries the commit stamp `87ebff4`, the 2.3.0 release commit.
The build goes through `scripts/build_release.sh` (xcodebuild Release, product universal
x86_64 + arm64), run in an external terminal to stay out of the tool sandbox; signing uses
`Kaname Local` from `kaname-signing.keychain-db`.

A note on signing: the rename changed both the bundle id and the certificate, and the designated
requirement is now `identifier "com.suliveevil.kaname" and certificate root = H"e40cfaa4…c17e"`.
This overwriting install therefore **requires re-authorizing Accessibility**; the old `Kaname Local`
certificate and the old keychain are kept, as a rollback.

**Ad-hoc is for verification only**: `scripts/build_swiftc.sh` ad-hoc signs when no stable identity
is available, and such a bundle can only be checked with `codesign --verify --deep --strict` in a
temporary directory; `scripts/install.sh` refuses to install an ad-hoc bundle outright. Whatever
lands in `/Applications/Kaname.app` must be `Kaname Local` (or a future Developer ID).

## Installed build

- Path: `/Applications/Kaname.app` (the only copy under `/Applications`, with no old
  `KagiPeek.app`)
- Version string, verbatim: `v2.3.0 (87ebff4)`
- `CFBundleIdentifier`: `com.suliveevil.kaname`
- `CFBundleName` / `CFBundleExecutable`: `Kaname` / `Kaname`
- `CFBundleShortVersionString` / `CFBundleVersion`: `2.3.0` / `230`
- `KanameCommit` (Info.plist): `87ebff4`
- Installed via: the Homebrew cask, tap `suliveevil/tap`, `brew install --cask kaname`;
  `brew list --cask kaname` reports `2.3.0`, Caskroom path
  `/opt/homebrew/Caskroom/kaname/2.3.0/Kaname.app`
- Signature: `Authority=Kaname Local`; `flags=0x10000(runtime)`; `TeamIdentifier=not set`;
  designated requirement root hash `e40cfaa4…c17e`, with the private key only in
  `kaname-signing.keychain-db`
- Running process: single instance (`pgrep -lf Kaname.app/Contents/MacOS` returns one line,
  PID 10769)
- `spctl -a -vv`: `rejected` (not notarized, expected)
- Old bundle backup: taken by `scripts/backup_app.sh` before the overwrite into
  `~/Library/Application Support/Kaname/backups/`
- Data directory: `~/Library/Application Support/Kaname/`; logs, menu cache and usage as before
- Migration result: `settings.json`, `usage.json`, `conflicts-cache.json`, `menu-cache/`, `logs/`,
  `crash/`, `signing/` copied over; log file names now come from `kaname-*.log`;
  `backups/` is 178 MB, copied asynchronously with a completion marker written
- Old logs, old crash reports and old backup file names remain in their original directory,
  undeleted

## Known environment pitfalls

1. **`xcodebuild` is unstable on this machine.** The build system wraps every compile in
   `sandbox-exec`, and nested sandboxing is sometimes denied:
   `sandbox-exec: sandbox_apply: Operation not permitted`. This is not a code problem. In this
   round's 2026-11-04 22:54 `install.sh`, xcodebuild passed first time; the 22:50 run first reported
   `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found` plus a
   cascade of `'self' is immutable` errors, and a rerun recovered — a build-cache problem, not a
   source problem. On failure you can still fall back to `scripts/build_swiftc.sh Release|Debug`,
   which uses the same source and the same Swift 6 flags and loads the SwiftUI macro plugin
   explicitly.
2. **`agent-desktop` cannot see the windows of an `LSUIElement` app.** There is no Dock icon and no
   main window by default; the panel or settings window has to be genuinely on screen before
   anything capturable appears in the Accessibility tree.
3. **Screen recording permission affects screenshots.** Without it, the system screenshot still
   captures the screen, but some automated screenshot or window-capture paths return a blank
   image; this has nothing to do with the app's own permissions.
4. **Git operations trigger sandbox notices.** Local tools report temporary files such as
   `.git/*.lock` as "moved to Trash" while the commit, branch switch or merge itself succeeds; do
   not go restoring them from the Trash by hand.
5. **The keychain authorization for the `Kaname Local` private key cannot be scripted.**
   `codesign`'s first use of the key pops a SecurityAgent dialog (Always Allow / Deny / Allow),
   which is system-protected: AppleScript's `click` returns success without taking effect, and
   `codesign` sits at 0% CPU. On 2026-11-04 the user clicked "Always Allow" by hand, after which
   test signing returns normally; a new machine or a rebuilt keychain hits it again. Try signing a
   throwaway file before building to confirm.
6. **`diskutil unmount` fails for any DMG inside the tool sandbox.** After unpacking,
   `brew install --cask` calls `diskutil eject`; inside the tool sandbox it returns "at least one
   volume could not be unmounted", after which `Dir.mktmpdir` cleaning the mount point raises
   `Read-only file system @ apply2files`. The same command is fine in an external terminal. Run
   install-class cask operations through `open -a Terminal`; do not go editing the DMG over it.
7. **Homebrew 7 requires third-party taps to be trusted explicitly.** Untrusted, installation
   reports `Refusing to load formula/cask from untrusted tap`; use
   `brew trust --cask suliveevil/tap/kaname` (trusting that one cask only), not the whole tap.
8. **Homebrew 7 removed `--no-quarantine`.** Both download and upgrade stamp quarantine on the
   cask, so the first launch must be allowed in System Settings, or the installed copy cleared with
   `xattr -dr com.apple.quarantine`.
9. **The cask's `app` stanza needs the extension.** `app "Kaname"` is read as an entry named
   `Kaname`, and installation reports
   `App source '…/Caskroom/kaname/2.3.0/Kaname' is not there`; it must be `app "Kaname.app"`.

## Unfinished / next steps

At most 5, each starting with its first action:

1. **The release chain is complete; notarization is next**: `main`, `v2.3.0`, the GitHub release and
   `suliveevil/homebrew-tap` are all live, and installation goes through the brew cask. To spare
   users the first-launch Gatekeeper prompt, a Developer ID certificate and
   `KANAME_NOTARY_PROFILE` are needed; with them `build_release.sh` notarizes and staples
   automatically. Do not pretend to support it before the certificate exists.
2. **`ShortcutEngine` has had one split round (R-3)**: seven collaboration modules and two Pure
   policies are in place, and InputRouter stays in the engine as planned. If slimming continues,
   the next cut is the `CatalogQuery` parameter object (architecture report H1/M1); do not hard-split
   InputRouter away.
3. **Panel VoiceOver reachability** (HIG report H2): this round added the selected state
   `.isSelected`, the row's `.contain` container, hidden decorative elements and the
   "menu item name → shortcut → state" reading order; what remains is on-device VoiceOver
   acceptance of the root container and the in-row buttons.
4. **Settings page information architecture** (HIG report M4 / §7.1): first draw the 8-section →
   sidebar interaction and confirm the window size, then touch `SettingsView`; this round
   explicitly leaves it alone.
5. **Menu bar extras HIG behaviour** (HIG report H3): first confirm whether left-click opening the
   panel and right-click opening the menu is the product intent, then change
   `NSStatusItem`'s `sendAction(on:)`.

## Known unfixed issues

By review-report number, the items this round **deliberately downgraded or left alone** (fix notes
in `/Users/suliveevil/.trae-cn/assistant/2026-11-04/kaname-code-review-2/outputs/fix-round2.md`):

- **The settings page's live preview of the panel (the "press and try" test area) is not
  implemented**: reusing `OverlayView` would require decoupling the engine first, which is high
  risk; downgraded this round, and the docs do not claim it exists.
- Concurrency report: M3 (`ShortcutTester`'s taps not split out), M5 (cache and crash reports with
  no eviction), M6 (logs containing menu titles), M7 (the exit path writing to disk on the main
  thread), M8 (the preview loading state never reset), L1–L5. M1 (an injection task may still post a
  key after cancellation) and M2 (two delayed Tasks with no owner) are fixed this round (Unreleased):
  every replay registers `injectionTask`, the palette hand-off holds `searchRunTask`, and both are
  cancelled on close and on `stop()`.
- Architecture report: H1 (the god object) has been split into seven collaboration modules by R-3,
  with the engine still owning InputRouter and lifecycle; H2 (two implementations of menu item
  execution) has a single entry point in `RowRunner`, though the search surface's difference
  remains; H3 (the settings field list written twice), H4 (business decisions left in the engine),
  M1–M10 and L2–L9 are untouched. Only L1 (13 dead L10n keys deleted) had been done before.
- HIG report: H2 (VoiceOver; the config-tool fold header now has a button role, an expanded value
  and a toggle action), H3 (menu bar extras), H4's "ask for the save path before doing the work"
  (this round fixed only the success feedback and the failure notice), M3's permission status colours
  (the green "granted" branch is still a bare `.green`), M4, M5 (accessible names on Slider/Stepper),
  M6's keyboard deletion (only the copy that contradicted the implementation was changed), M7's
  Continue-disable explanation / Esc / detail truncation, M9–M11, L1 (the doubled `v` in the version),
  L2 (bare ✓/— with no alternative text), L5/L6 (hard-coded English), L7 (this round changed only the
  prompt copy). M3's yellow star and M8's orange failure-text contrast are fixed this round
  (Unreleased): `Theme.favoriteStar`/`Theme.warning` use a darker measured variant in light mode, and
  the bare `.orange` text and badges now route through the token.

## Waiting on your decision

- **Whether the excluded-apps list should support keyboard deletion** (HIG M6): this round only
  changed the "press −" copy to "click −"; no `onDeleteCommand` was added. Doing it is a separate
  interaction change.
- **The wording direction for the favourites switch** (HIG §6 `favoritesFilterable`): the report's
  suggested "Include hidden favourites" has the opposite meaning to the current implementation
  (switch on = favourites can be hidden by filtering); this round followed the implementation and
  changed it to "Let filters hide favorites / 允许搜索和过滤隐藏收藏". Reversing the behaviour
  would mean changing `FavoritesPolicy` first.
- **Terminology and sentence-pattern consistency**: the object itself is settled as
  "菜单项 / menu item" (commit `05c775f`), with "行 / row" kept for layout only; purely stylistic
  pairs such as execute/run/Run and panel/window/Panel are still not unified.

## Do not touch

The implementations below were judged by the review reports as "looks dangerous but is fine" or
"not recommended to change"; this round left them alone, and later rounds should not refactor them
in passing:

- Concurrency report §"looks dangerous but is fine" 1–12: `CatalogLoader.Reply`'s resume-once,
  `InputMailbox`'s drop policy, `KeyboardMonitor`'s dedicated tap thread, `ShortcutTester`'s
  `.listenOnly`, the press guard after the panel closes, `Diag`'s lock box, `RingBuffer`,
  `ConflictDetector`'s bucketing, the search corpus cache, `ResolvedAXElement` isolation, crash
  signal handling, and `MainActor.assumeIsolated`'s callback precondition.
- Architecture report §"not recommended to change" 1–10: the `KANAME_PREVIEW` backdoor and
  `beginPreview()`, `Diag`'s static façade, `CatalogLoader`'s `@unchecked Sendable` + two queues +
  semaphore, `KeyboardMonitor`'s tap timing and watchdog, `enterNextLevel`/`descend` not merged,
  `triggerMode`/`LegacyKeys`, the two-layer menu cache, `Core/Pure` depending on `CoreGraphics`,
  `EngineState` as a single ObservableObject, and the two HUD windows each building their own
  `NSWindow`.
- HIG report §"suggested but leave alone for now" 1–8 (already folded into the next steps above,
  not changed on their own).

## 2026-11-07: window level for native fullscreen Spaces (static)

- `SurfacePanelController.swift` now sets `panel.level = .statusBar` (25) instead of
  `.floating` (3), matching `HUDPanelController`. A native fullscreen app owns a separate
  Space whose windows the WindowServer orders above anything at `.floating`;
  `.canJoinAllSpaces` / `.fullScreenAuxiliary` only grant Space membership, and
  `orderFrontRegardless()` cannot cross a level difference. The panel was already being
  presented — it was simply underneath, which read as "the trigger did nothing".
- **The level stays static; do not make it dynamic.** macOS exposes no public "is this Space
  fullscreen" query, and one switch fires several `activeSpaceDidChangeNotification`s
  (`SpaceRescanGate` already debounces them). Changing `level` at runtime forces a
  WindowServer reorder that races `dismissEverything()` / `invalidateAnchorGeometry()`,
  adding a second cross-Space state machine to the same window.
- Convention: **a Space change is an invalidation signal only** (dismiss the panel, clear the
  anchor geometry snapshot, debounce a rescan), never a state input.
  `SurfacePanelController.spaceChangeObserver` and `ShortcutEngine`'s Space handling are unchanged.
- Left alone: `PopupGate` (`.statusBar` 25 is far below `popUpMenuWindow` 101, so it neither
  covers system pop-up menus nor self-matches), `HUDPanelController`,
  `PermissionGuidePanelController` (anchored inside a System Settings window, still
  `.floating`), `SpaceRescanGate`, and `OverlayPlacement`.
- No visible cost on ordinary Spaces: `visibleFrame` already excludes the menu bar and Dock,
  and `topInset` / `fillScreenFrame` / `clampedTop` avoid the safe area. The panel is a
  short-lived, `.nonactivatingPanel` overlay card the user invokes explicitly.
- Verification: `swift test --disable-sandbox` green, 867 tests. Visual confirmation inside a
  real fullscreen app is left to the integrator after reinstalling per AGENTS.md step ④
  (this branch commits source and docs only; no build, no install).
