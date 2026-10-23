# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Marketing version is now 2.2.0.

### Added

- **Running a shortcut is a recorded key pair.** The panel and the browser list share one row contract: `runRowKey` (↩ by default) closes the surface and replays that row's chord into the app that should receive it, `copyRowKey` (⌘↩ by default) only writes the chord to the clipboard and leaves the surface open. Both are recorded under **Settings → General → Row actions**, a bare Return is allowed, a bare letter is refused (it would break chord entry and filtering), and the footer hints render the keys you actually chose instead of assuming Return.
- **Keep the browser open after running**, next to the row keys: with it on, running a row from the browser list leaves the window in place.
- **The browser window's rows are live.** Hover selects, a click runs, ↑/↓ walk the list, the row keys run and copy, Esc closes — driven by a window-level key monitor that leaves input-method composition alone. The row carries the same gutter marker and press flash as the panel, and the list scrolls only when the keyboard moves the selection, never out from under the pointer.
- **A responsive panel title bar.** The header is measured and lays itself out in three densities — full at 600 pt and above, tight above 460 pt, minimal below — so the settings and close buttons stay clickable in a one-column panel instead of being pushed out of it.
- **Click feedback everywhere.** Every glyph-only control answers the pointer: a soft fill on hover, a quick dip while held, a dimmed body when disabled, plus a press flash on rows. Tooltips on the pager, the clear buttons and the close button.
- **An explicit close button** (`✕`) in the panel title bar for both surfaces, so a mouse user no longer has to guess how the panel goes away.
- **Export diagnostics…** in **Settings → About** writes one JSON report (permissions, listener state, scan result, settings, the command that prints the matching log lines) to attach to a bug report. `KAGIPEEK_SELFTEST=1` writes the same report and now works while the app is already running.
- **Categorised logging** (`os.Logger`, subsystem `com.voltline.kagipeek`, categories `scan`, `input`, `storage`, `ui`), so a failed scan, a refused write or a dropped injection leaves a trace instead of looking like "it stopped working".
- **Conflicts say who wins, not just that something clashes.** Every binding now sits on a layer of the macOS event stack — `driver` (Karabiner) → `eventTap` (skhd, Keyboard Maestro, BetterTouchTool) → `system` → `globalHotKey` (Hammerspoon, Alfred) → `otherGlobal` → `menuItem` — and lower wins. `ShortcutLayer` reads the *tool*, not just the source, because all six config scanners share `BindingSource.configFile` and would otherwise be ranked next to a menu item. Findings are graded `.definite` (two always-on sources), `.shadowed` (an always-on source covers this app's menu items) and `.appOverlap` (only menu items overlap, so nothing is broken), and the verdict is `.winner`, `.tied` or `.menuOrder` — where the honest answer is "same layer, registration order decides, and no file records it", it says that rather than guessing. **Settings → Ranking → Conflicts** shows the badge, the verdict with the layer's own explanation, a scope filter (all / real conflicts / definite only) and a rescan.
- **Third-party shortcut config files are scanned**, so a conflict list can say "⌘⇧4 will never reach Safari" instead of just "two things want ⌘⇧4": Karabiner-Elements (`karabiner.json`, complex modifications with a mandatory modifier), skhd (`skhdrc`), Keyboard Maestro (hot key triggers, inactive macros and groups skipped), BetterTouchTool (newest `btt_data_store.version_*`, opened read-only through SQLite), Hammerspoon (`hs.hotkey.bind` with literal arguments; a variable modifier table is dropped rather than half-resolved) and Alfred (workflow hotkeys, following `prefs.json` for synced preferences). On by default, switchable in **Settings → Ranking**, scanned at launch and on demand but deliberately not on every app switch. Each parser is a pure function over text/data/plist so it is tested against fixtures.
- **Combo lookup.** Typing a combination into search (`cmd shift 4`, `⌘⇧4`, `opt cmd t`) answers *who owns this* or *it is free*, instead of returning an empty list that reads as "not scanned". A query is only a combo when every token is a modifier or a key, with exactly one key and at least one modifier — which is what keeps `cmd safari` a plain text search. It matches on the same chord key the conflict detector groups by, so the two can never disagree.
- **Live shortcut test.** **Test this combo** in the conflict list watches one real keypress: two listen-only event taps, one at the head of the chain and one at the tail, so a key that arrives at the head and never reaches the tail was swallowed by another app's tap — a fact, not an inference. Above the tap layer it falls back to what came to the front. `LiveTestVerdict` names one of six outcomes with an explicit tone (`confirmed` / `informative` / `inconclusive`) and states its own blind spot: past the tap layer a system shortcut can take a key without leaving a trace. While listening, the engine suspends every panel behaviour and all swallowing, so KagiPeek can never be the thing that ate the key.

### Changed

- **A held modifier narrows the panel again.** Summoning by long-pressing ⌃/⌥/⌘ pushes that set onto the prefix, so the panel narrows which-key style; the hotkey and double-⌘ summon it with an empty prefix, where every row is a complete combination. This is the behaviour the code had since v2.1, and the code comments and the documentation now say so instead of describing the opposite.
- **Esc closes the panel whatever the modifiers are**; ⌫ still backs out one chord stroke and is only handled with no other modifier held.
- **Switching apps or desktops closes the panel** rather than refreshing it in place; summon it again for the new app.
- **The app no longer treats its own activation as a frontmost-app change.** Activating for the search palette, the browser window or Settings made KagiPeek the frontmost app, and the catalog was rescanned from its own (empty) menu bar — the panel fell back to the built-in catalog and the browser window renamed itself "KagiPeek". A scan result from an older request can also no longer overwrite a newer one.
- **Settings and statistics are written once, after a pause, by one writer.** Settings changes coalesce (350 ms) and the write reads the snapshot at fire time; a press is recorded in memory and flushed 1.2 s later on a utility queue, then once more at quit. A failed write is logged instead of silently lost.
- **Key events are decoded lazily.** The tap reads the Unicode string only while a surface is taking keys or a binding is being recorded, and the panel's ranked rows are cached until the prefix, catalog, sort mode or press count changes.
- **The settings conflict list is graded rather than flat.** It used to print "%d chords are bound more than once" and a bullet per member, which invites the question *so which one fires?* and could not answer it. It now carries a category badge, the layer verdict, a per-member badge, the scope filter and a **Test this combo** button.
- **Row interactions moved into testable pure code**: `RowKeyRouter` (run before copy, one implementation for the panel, the filter and the browser), `ListSelection`, `PanelRowBuilder`, `HeaderLayout`, `KeyAliases`, and `PanelState`.

### Fixed

- **Clicking away no longer clicks through.** Dismissing the panel by clicking outside it closed it *and* clicked whatever sat behind it in the app you were working in — moving the insertion point, changing the selection, pressing a button you never aimed at. That one press is swallowed now. Only presses that would land in the front app's window are: a click on the menu bar, the Dock, the desktop or another app's window is you reaching for something else, and eating it would make the panel feel like it had frozen the screen. Presses on the panel itself are the panel's, as before.
- **The pointer comes back.** Summoning the panel never moved the pointer, but leaving it did: clicking a row to run it, or clicking away to dismiss the panel, left the pointer wherever the panel sent it, and the place you were working in the app behind it was gone. The position is remembered when the panel opens and restored when it closes — by Esc, by running a command, by clicking away, by switching apps, all of them. If the pointer never moved (opened by hotkey, dismissed by Esc) nothing is warped, because moving it to where it already is only announces a jump. Opening the search palette from the panel keeps the pointer where it is; that surface is about to want it.
- **Tapping a modifier ticks it.** Only *holding* a modifier narrowed the list, so the Emacs spelling — ⌥, ⌘, C, one key at a time — never worked; releasing the key put the full list back. A press-and-release inside 0.35 s, with nothing typed while it was down, now leaves the modifier ticked, and each further tap narrows on top of the last. Holding still narrows temporarily: holding is looking, tapping is composing. A modifier that was used *with* a key (the ⌘ of ⌘C) is not a tap, and neither is the one still down when the panel opens — that one is the trigger.
- **⌫ undoes the tick you made last.** It removed whichever modifier came last in ⌃⌥⇧⌘ order instead of the most recently ticked one, so ticking ⌘ then ⌥ and pressing ⌫ dropped the wrong one. The ticks keep their order now. Nothing else changes: with no tick left, ⌫ still goes up one level of a chord, and the panel stays open either way.
- **The menu bar icon is visible on a dark menu bar.** `Image(nsImage:)` does not inherit `NSImage.isTemplate`, so the glyph was drawn in its own colour — black — and vanished into a dark menu bar. It is explicitly marked as a template now.
- **Escape closes the panel again** — on the built-in key and on a Caps Lock remapped to Escape by Karabiner. Escape, Tab, Return and Delete each carry a control character (`U+001B`, `U+0009`, `U+000D`, `U+007F`), and the key mapper preferred the character over the virtual key code, so Escape resolved to `U+001B` and was never equal to `esc`; the tap swallowed the press and nothing happened. Tab and Return had the same bug from the other direction — both resolved to `space`. Control characters now fall through to the key code, and the panel recognises Escape by key code, which is also how the tap claims it.
- **⌫ undoes a tick and pops a level again.** Its token is `delete`, which never matched while the key was resolving to `U+007F`, so the key had been inert since it was written.
- **The panel no longer changes height while you narrow the list.** Holding a modifier removes rows, and the window was sized from the rows on screen, so it shrank on every press and grew back on release. It is sized from the session's widest list now.
- **The panel title is no longer a close button.** Clicking the app icon or the app name dismissed the surface silently; the identity block is static now and closing has its own button.
- **Dimmed rows no longer show a selection marker.** They carry `index == -1`, which is also the "nothing selected" sentinel, so `selectionIndex == row.index` lit up every dimmed row whenever nothing was selected.
- **Rows no longer shift when hovered.** The marker and the pin star were inserted into the row's stack, pushing the title and keycap sideways as the pointer moved; both now sit in reserved space.
- **The pin star can no longer fire the shortcut.** A star click inside a row with a tap gesture could also run the row and inject its chord; it is a bounded child gesture now.
- **Pager buttons are clickable** (22 × 22 instead of the glyph's own ~10 pt), and decorative strokes are explicitly out of the click path.
- **The inline filter clears in the snapshot too.** Leaving the filter left `isFiltering`/`filterText` set, so the UI kept drawing a filter bar for a filter that was no longer active.
- **The search palette no longer swallows ⌃⌥P or ⌃⌘P.** It passed a hard-coded ⌃ to the navigation matcher, so any combination containing ⌃ plus P/N was treated as navigation and consumed; the browser window let the same keys through.
- **Held keys no longer leak or repeat.** Repeats of a key the panel consumes are consumed too, running a row no longer repeats while the key is held, and ⌘⌫ / ⌥⌫ are consumed while the inline filter is open instead of deleting in two places.
- **A refresh in the browser window refreshes what it is showing.** It called the frontmost-app reload, which (with the window key) reloaded KagiPeek's own menu bar.
- **Settings no longer lose a change to a concurrent write** (two writers within the debounce window used to be last-wins).
- **The panel highlights the rows on the page.** `highlightedIDs(for:)` discarded its page argument and recomputed the same prefix over the whole catalog.

### Removed

- **Both "Execute menu commands" switches.** `allowPanelExecute` (v2.2) and `allowSearchExecute` (this release) never controlled anything after rows started replaying their chord: the first had no callers, the second only switched one footer sentence — and it was wrong, telling users Return copies while Return ran. With them go `PanelState.allowsExecution`, `PanelState.appCanExecute`, `execute(rowID:)`, `HotkeySpec.isValid`, `.searchHint`, `.searchCopied` and `.browserExportDone`.
- **Dead state and dead keys.** `PanelState.highlightedRowIDs` had no readers, and `KeyToken("fdelete")` became a constant.

## [2.1.0] - 2026-10-21

v2.1.0 makes the panel persistent and stops treating the keys that trigger it as a shortcut prefix. The panel lists every shortcut for the frontmost app as a full combination, highlights progressively while modifiers are held and when a shortcut is completed, and stays until you press a complete shortcut, press Esc, or toggle it off. Four panel placement modes, tokenized and pinyin-aware search, Hyper-key hotkey matching, per-app statistics in plain JSON files, guided permission onboarding, a dedicated About tab, and a panel/search switch hotkey round out the release. macOS 14.0 and the bundle identifier are unchanged.

### Added

- **Persistent panel.** Summoning the panel — with the hotkey (⌃⌥⌘K), by double-tapping ⌘, or by holding a modifier — no longer treats those keys as a prefix. The panel lists **all** of the frontmost app's shortcuts as complete combinations (for example ⌘C) instead of narrowing to the held modifiers, and it stays open until you press a complete shortcut, press Esc, or press the panel hotkey again. Releasing the modifiers no longer dismisses it.
- **Progressive highlight.** While modifiers are held, every row whose shortcut starts with them is highlighted. The moment a complete shortcut is pressed, that row's description is emphasised in the accent color for about 0.4 s, then the panel closes. Row selection with ↑/↓ and key highlighting are two different visual states.
- **Hyper-key support.** Hotkey matching now allows an event to carry a **superset** of the recorded modifiers when the recorded hotkey has three or more modifiers. A Karabiner-style hyper combination (⌃⌥⇧⌘) therefore matches a recorded ⌃⌥⌘ hotkey. Hotkeys with fewer than three modifiers stay strict.
- **Tokenized search.** Space-separated terms are matched in any order (AND), and `+` works as a separator, so `com op x`, `op cm x`, and `cmd+opt+x` all find ⌘⌥X. Modifier aliases are understood: com/cmd/command/cm/⌘, op/opt/option/alt/⌥, ct/ctl/ctrl/control/⌃, sh/sft/shift/⇧.
- **Pinyin and initials search.** Chinese titles match by full pinyin (jian qie) and by pinyin initials (jq); English titles match by word initials (fs → Find Similar). All terms must match, and better matches still rank first.
- **Panel placement options** under **Settings → Appearance → Panel placement**: cover the front window (default), a fixed width/height, fill the visible screen, or beside the front window (the v1.x/v2.0 behaviour). The cover mode makes the panel larger than the front window in both dimensions and centres it on screen.
- **JSON storage in Application Support.** Settings and statistics now live in `~/Library/Application Support/KagiPeek/settings.json` and `usage.json`, written atomically. A file that cannot be decoded is renamed to `*.corrupt-<timestamp>.json` and kept rather than silently discarded. The first launch migrates the previous UserDefaults data, including the 1.x `com.Voltline.KagiPeek` domain, exactly once.
- **Per-app statistics.** Usage keys are `bundleID|chord` (`*` for system and built-in rows), so statistics are grouped by app. **Settings → Ranking** gains a per-app list with the press count and the number of shortcuts per app, plus **Show data folder**.
- **Guided permission onboarding.** **Request Access** now both shows the system authorization prompt and opens the matching System Settings pane (Accessibility or Input Monitoring). The Permissions tab also offers a draggable KagiPeek icon that can be dropped straight into the list in System Settings.
- **Dedicated About tab.** Settings now has six tabs — General, Triggers, Appearance, Ranking, Permissions, About. The About tab shows the app icon, version and build number, system version, the manual update check, the data folder (with an open button), the repository and license, and diagnostics (Accessibility, Input Monitoring, listener state, and the number of scanned menu items).
- **Switch panel/search hotkey.** A new global hotkey, ⌃⌥⌘S by default and recordable in Settings, swaps between the panel and the search palette.
- New sources: `Core/Pure/PanelPlacement.swift`, `Core/Pure/HotkeyMatcher.swift`, `Core/Storage/DataDirectory.swift`; `SearchIndex` gains the precomputed `SearchCorpus` and the `Pinyin` helper.

### Changed

- **Rows show the complete shortcut.** The panel no longer renders only "the next key": each row lists the full combination, so the display is stable while modifiers are pressed and released.
- **The trigger is not a prefix.** Holding ⌘ before the panel opens, or the modifiers used to summon it, no longer narrows the list; progressive highlighting replaces prefix narrowing. Chord prefixes still descend one level when a stroke is pressed, and ⌫ still goes back one step.
- **Every panel is persistent.** The pinned/browse panel distinction is gone; there is no idle timer and no auto-hide. Panels opened by a hold, by double-⌘, and by the hotkey all behave the same way.
- **Completing a shortcut lets it through.** KagiPeek highlights the completed row, closes the panel, and lets the key event continue to the front app unchanged; it never synthesizes keystrokes.
- **Panel and search are mutually exclusive.** Only one is visible at a time: opening search closes the panel and vice versa. The new switch hotkey moves between them: search visible → panel, panel visible → search, neither → panel.
- **New default placement.** The panel now covers the front window by default instead of sitting beside it; the old placement remains available as **Beside the front window**. `attachToFrontWindow` is replaced by the four-value panel placement setting.
- **Settings/statistics no longer use UserDefaults.** Both are plain JSON files in Application Support; the preference domain is read once for migration and is not written any more. Uninstalling or reinstalling the app no longer depends on the preference domain, so data survives unless the folder is deleted.
- **Settings reorganized into six tabs.** The old **Ranking → About** area moved to its own About tab, and permission onboarding, appearance, ranking, and statistics each have a dedicated place.
- Marketing version is now 2.1.0. The bundle identifier (`com.voltline.kagipeek`) and the macOS 14.0 minimum are unchanged.

### Removed

- **The auto-hide delay is gone / 自动关闭延时已移除。** The `autoHideDelay` setting and its model field are removed from the app, not hidden behind a default: no panel times out any more. A panel closes only when you press a complete shortcut, press Esc, or press the panel (or switch) hotkey again.
- **Modifier-prefix narrowing.** Holding a modifier no longer filters the panel to that prefix; every shortcut stays listed and matching rows highlight instead.
- **The "next key only" row label.** Rows render the complete combination.
- **The pinned/unpinned panel distinction**, including the separate auto-close rules for browse panels.
- **UserDefaults as the settings and statistics store**, and `attachToFrontWindow` as a setting.

### Upgrade notes

- **The panel no longer closes by itself.** If you expected it to disappear after a few seconds, press Esc (or complete a shortcut). The auto-hide setting is gone, so there is nothing to configure.
- **The trigger is not a prefix.** The panel always lists the app's full shortcut set and highlights the rows that start with the modifiers you hold. To execute a row with the keyboard, use ↑/↓ and Return, or just type the complete shortcut.
- **Your placement may have changed.** The default is now **Cover the front window**. Pick **Beside the front window** in **Settings → Appearance** to restore the v2.0 behaviour, or choose a fixed size or full screen.
- **Settings and statistics move on first launch.** KagiPeek reads `settings.json`/`usage.json` if present, otherwise migrates the previous `settings.v2`/`usage.v2` UserDefaults payloads, otherwise the 1.x `com.Voltline.KagiPeek` domain. The old defaults are left in place and can be deleted with `defaults delete com.voltline.kagipeek` and `defaults delete com.Voltline.KagiPeek`.
- **Statistics are now grouped by app.** Existing `bundleID|chord` keys are reused, so history carries over; the Ranking tab lists presses per app, and system/built-in shortcuts appear as **System / built-in**.
- **Hyper keys need no extra setup.** Record a three-modifier hotkey as usual; a tool that adds a fourth modifier still matches it.
- **Permissions do not need to be re-granted for a signed upgrade.** The bundle identifier did not change, so a Developer ID-signed v2.0.0 → v2.1.0 update normally keeps its Accessibility grant. Ad-hoc local builds may still need re-approval after a rebuild.
- macOS 14.0 Sonoma or later is still required.

## [2.0.0] - 2026-10-21

v2.0.0 makes the panel usable rather than only readable. A pinned panel can now be driven from the keyboard and clicked, conflicts include macOS system hotkeys, the browser can look at any running app, and the shortcut sheet exports to Markdown. The default ordering becomes a smart review order, and Settings gains a manual update check. macOS 14.0 and the bundle identifier are unchanged.

### Added

- **Actionable panel.** While the panel is pinned, ↑/↓ move the row selection, ←/→ page, Return acts on the selected row (execute or copy, per the setting below), and Esc closes the panel. When the panel consumes these keys they do not reach the front app. Clicking a row does the same thing as Return. The pinned panel stays open after a row runs, so several commands can be run in a row, and a row that still has further steps opens the next level.
- **Execute from the panel (opt-in).** A new setting, *Execute menu commands from the panel*, is **off by default**. When it is on, Return or a click presses the menu item through `AXPress`. When it is off, Return or a click copies the shortcut to the clipboard instead. The HUD reports either outcome. Only live menu items can be executed; built-in catalog rows always copy.
- **System hotkey conflict detection.** `CopySymbolicHotKeys` (Carbon) is read to collect the enabled system-wide shortcuts (Spotlight, Mission Control, screenshots, input-source switching, …) and compare them with the current app's menu shortcuts. A matching chord is marked ⚠︎, and **Settings → Ranking → Conflicts** lists every source; system-wide entries are grouped under "System hotkeys" / "系统热键".
- **Multi-app browsing.** The main window has an app selector listing the frontmost app plus every running regular app. Any of them can be scanned and browsed in the window, while the panel itself keeps following the real frontmost app.
- **Export Markdown.** *Export Markdown* in the main window opens an `NSSavePanel` and writes the currently browsed shortcut sheet as Markdown: grouped by menu, table columns `Shortcut` / `Action`, and unavailable items marked `(unavailable)`.
- **Smart review ordering** — the new default sort order. Context first, then usage frequency decayed over time, plus a small boost for shortcuts that were used before but not for more than 30 days. The boost resurfaces stale-but-known rows; it never outranks frequent recent ones and never lifts never-used rows above used ones.
- **Check for updates.** **Settings → Ranking → About** gains a *Check for updates* button. It requests `https://api.github.com/repos/suliveevil/KagiPeek/releases/latest`, compares the tag with the running version, and shows a link to the release page when a newer version exists, or a short failure message. It is manual only: no automatic download and no background polling.
- New sources: `Core/Services/UpdateChecker.swift`, `Core/AX/SystemHotkeyReader.swift`, `Core/AX/AppDirectory.swift`, `Core/Pure/SemanticVersion.swift`, `Core/Pure/MarkdownExporter.swift`.
- `PanelState` gains `selectionIndex`, `flatRowIDs`, `allowsExecution`, and `appCanExecute`; `KeyboardMonitor` gains `updateCapturedKeys` so the panel can consume its navigation keys.
- Tests for smart review ordering (stale entries beat never-used ones, context still wins), `SemanticVersion` parsing and comparison, Markdown table rendering, system-hotkey conflicts, and settings that default to smart review with panel execution off.

### Changed

- The default sort order is now **Smart review** instead of *Context, then frequency*. Every previous order is still available.
- A pinned panel now consumes ↑, ↓, ←, →, Return, Enter, and Esc while it is open.
- Conflict detection also considers enabled macOS system shortcuts, and the conflict list shows where each clash comes from.
- The main window header gained an app selector, *Export Markdown*, and *Refresh*.
- Marketing version is now 2.0.0. The bundle identifier (`com.voltline.kagipeek`) and the macOS 14.0 minimum are unchanged.
- The privacy text now states the single manual network request (the update check); everything else remains local.

### Upgrade notes

- **Default order changed to Smart review.** If you preferred context-then-frequency, select it again in **Settings → Ranking → Sort order**.
- **Pinned panels consume more keys.** While a pinned panel is open, ↑/↓/←/→/Return/Esc are swallowed instead of reaching the front app. An unpinned browse panel behaves as before.
- **Executing from the panel is opt-in.** With *Execute menu commands from the panel* off (the default), Return and clicks only copy the shortcut; turn it on for click-to-run.
- **Permissions do not need to be re-granted for a signed upgrade.** The bundle identifier did not change, so a Developer ID-signed v1.2.0 → v2.0.0 update normally keeps its Accessibility grant. Ad-hoc local builds may still need re-approval after a rebuild.
- macOS 14.0 Sonoma or later is still required.

## [1.2.0] - 2026-10-21

A ground-up rewrite of the shortcut engine. v1.2.0 replaces the static list with live menu-bar scanning, adds prefix/chord navigation, search, conflict detection, and a tested pure-logic core.

### Added

- Live scanning of the frontmost app's menu bar through the macOS Accessibility API (`AXMenuBar` → `AXMenuBarItem` → `AXMenu` → `AXMenuItem`), reading key equivalents and `AXEnabled` state recursively. Works with any app that exposes a standard menu bar; no per-app shortcut list is required.
- A built-in fallback catalog of roughly 100 system, text-editing, Finder, and screenshot shortcuts, used when an app has no menu bar or a scan cannot run. The catalog can be disabled in Settings.
- Per-app scan cache with a 20 s TTL. Switching the frontmost app forces a fresh scan, app launch/quit clears the cache, and changing the language or built-in-catalog setting refreshes it. There is no live menu observer. Scans run on a background queue with a 0.35 s Accessibility messaging timeout, so the main thread never blocks on a slow app.
- Four trigger modes:
  - hold a ⌃/⌥/⌘ combination and pause (default, 0.1–1.5 s delay, 0.5 s by default);
  - double-tap ⌘ (under 300 ms);
  - a global hotkey (default ⌃⌥⌘K), which keeps the panel pinned until Esc or the hotkey again; switching apps refreshes the pinned panel in place;
  - off.
- Browse panels opened by holding modifiers or double-⌘ auto-close after 4 seconds without interaction by default (configurable 1–15 s). Pinned hotkey panels are exempt.
- Which-key style panel:
  - shows the next key to press, not the whole combination;
  - adding a modifier narrows the prefix (⌘ → add ⇧ → ⌘⇧ bindings) instead of closing the panel;
  - supports multi-stroke chords (for example `⌘K ⌘C`) with a breadcrumb, ⌫ to go back one level, Esc to close, and the panel staying in place between strokes (⌫ and Esc apply only when no other modifier is held);
  - groups rows by menu path (File, Edit, View, …);
  - paginates long lists with `n/m` and clickable ‹ ›, and supports scroll-wheel paging, so the panel never grows past the screen;
  - truncates long descriptions to a configurable length with an ellipsis.
- A 0.75 s "executed" HUD (for example `⌘C Copy ✓`) when a shortcut is completed. A key with no matching binding closes the panel without a HUD. Can be disabled.
- Conflict detection: bindings that claim the same key combination are marked with ⚠︎, and **Settings → Ranking → Conflicts** lists them.
- Menu items reported as disabled (`AXEnabled == false`) are greyed out, and can optionally be hidden.
- Ranking: context first (frontmost-app bindings before generic catalog rows), then usage frequency, then key order. Alternative modes: frequency, review/auto-recall (least recently used first), key order, alphabetical.
- Local usage statistics: use count and last-used time per binding, stored as JSON in `UserDefaults` under the versioned key `usage.v2`, with an 800-entry LRU cap and a reset button in Settings. No raw key events or text are stored.
- Global search panel (default ⌃⌥⌘F) and a search field in the main window:
  - fuzzy search over the current app's menu shortcuts and the built-in catalog;
  - ↑/↓ to select;
  - Return copies the shortcut to the clipboard;
  - optional **Execute menu commands from search** (off by default) makes Return press the selected menu item via `AXPress`.
- Panels are anchored to the frontmost window (beside or below it) instead of the fixed top-left corner, and try to avoid the focused control.
- Dark translucent panel that honours **Reduce Transparency** and **Increase Contrast**.
- Appearance settings for key style, column count, rows per page, and description length.
- General settings for launch at login and for excluding apps by bundle identifier.
- English and Simplified Chinese interface, following the system language with a manual override in Settings.
- Accessibility is the required permission (menu reading, the global key tap, and opt-in `AXPress` execution). Input Monitoring is offered as an optional fallback when a system does not deliver key events with Accessibility alone. Each is detected and explained separately. The panel hides automatically while macOS secure input is active.
- The app is an `LSUIElement` menu bar agent (no Dock icon). Its main window opens at launch and can be reopened from the menu bar icon; ⌘, opens Settings.
- Pure-logic SwiftPM target `KagiPeekCore` with XCTest coverage for chord parsing, key mapping, prefix matching, ranking, key formatting, description cleanup, conflict detection, search indexing, localization, the built-in catalog, and usage statistics.
- GitHub Actions CI on `macos-15`: `xcodebuild` build with signing disabled plus `swift test`.
- `scripts/build_release.sh`: Release build, Developer ID signing and `notarytool` notarization when available, ad-hoc fallback otherwise, DMG packaging at `build/KagiPeek-<version>.dmg`.
- `scripts/install.sh`: build and replace `/Applications/KagiPeek.app` for local use.
- `Distribution/kagipeek.rb`: Homebrew cask template for a tap.

### Changed

- Shortcut data source: the primary source is now the live menu bar of the frontmost app; the static list is a fallback.
- Bundle identifier changed from `com.Voltline.KagiPeek` to `com.voltline.kagipeek`.
- Minimum macOS version is now 14.0 (Sonoma). The previous project mixed 15.7 and 14 deployment targets; v1.2.0 uses 14.0 consistently.
- Marketing version is now 1.2.0.
- The overlay is now positioned relative to the focused window rather than at a fixed screen corner.
- Menus are rendered as grouped, paginated rows instead of one unsorted or frequency-only list.
- The app is a menu bar agent; its main window opens at launch and can be reopened from the menu bar icon.

### Removed

- The hard-coded 100-entry list is no longer the only shortcut source.
- The fixed top-left overlay placement.

### Upgrade notes

- **Accessibility must be granted again.** The bundle identifier changed, so macOS sees 1.2.0 as a new app. Open **System Settings → Privacy & Security → Accessibility**, remove the stale KagiPeek entry if present, and enable the new app. Grant Input Monitoring too only if the panel does not appear after that. See [docs/PERMISSIONS.md](docs/PERMISSIONS.md).
- **macOS 14.0 is required.** v1.2.0 does not run on macOS 13 or earlier.
- Replacing an existing install with an ad-hoc signed local build invalidates the privacy grant because the signature changes; remove the old Accessibility entry and re-add the new app. The same applies when replacing one build with another signed by a different identity.
- The app remains sandbox-free and is not distributed through the Mac App Store.

## [1.1.0]

### Added

- Static catalog of about 100 common macOS shortcuts.
- Hold-modifier overlay with frequency-based ordering.
- Multi-column overlay layout and usage statistics.
- Menu bar controls for triggering the overlay and opening settings.

## [1.0.0]

### Added

- Initial MVP: global key listening via `CGEventTap`, modifier state machine, prefix trie, and a floating overlay panel.

[Unreleased]: https://github.com/suliveevil/KagiPeek/compare/v2.1.0...main
[2.1.0]: https://github.com/suliveevil/KagiPeek/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/suliveevil/KagiPeek/compare/v1.2.0...v2.0.0
[1.2.0]: https://github.com/suliveevil/KagiPeek/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/suliveevil/KagiPeek/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/suliveevil/KagiPeek/releases/tag/v1.0.0