# Architecture

This document describes the v2.2.0 architecture. A development branch (the v2.3.0 refactor) has since pulled the engine's decision logic into pure, unit-tested modules — see [Engine state and key routing](#engine-state-and-key-routing-development-after-v220). KagiPeek 2.1.0 builds on the v2.0.0 actionable panel — the v1.2.0 rewrite replaced the v1.1 static list with live Accessibility (AX) menu scanning, a chord resolver, a search index, and a set of small SwiftUI panels; v2.0 made the panel keyboard-driven and clickable; and v2.1.0 makes it **persistent**. The panel is persistent: it stays open until you press Esc or toggle it off. Holding the trigger key to summon it seeds a prefix, so the list narrows which-key style; the hotkey and the trigger-key double tap summon it with an empty prefix, where every menu item is a complete combination. v2.1.0 added four placement modes, tokenized/pinyin search, Hyper-key hotkey matching, JSON storage in Application Support with per-app statistics, guided permission onboarding, a dedicated About tab, and a panel/search switch hotkey. v2.2.0 removes the separate browser window — the search palette took over its two jobs, app scope and Markdown export — puts the panel's menu items in two cards ordered by the shortcut itself, gives the menu items one contract with two recorded action keys, makes the title bar responsive, drops the two no-op "execute menu commands" switches, splits Settings into eight tabs, and isolates the app's own activation from the frontmost-app input. The panel is ordered by the shortcut itself — the menu path is a note on the menu item instead of a section heading — the title bar carries checkable ⌃ ⌥ ⇧ ⌘ chips that narrow the list, and a modifier held down is lit inside every surviving menu item's chord rather than stripped from it. The update check is still the only network code, and it runs only when you press the button.

The governing constraints are:

- **Observational by default, with one deliberate exception.** KagiPeek observes the menu bar and key events; it does not remap shortcuts or read text. The events it consumes are its own panel, search, and switch hotkeys plus the panel's navigation and action keys. A completed shortcut closes the panel and is **not** swallowed: the front app receives it as usual. The exception is *running a menu item*: pressing the run key, clicking a menu item, or pressing Return in the palette posts that one chord to the front app through `ShortcutInjector` (`CGEvent`, HID tap). Nothing is injected while merely browsing, and the copy key never injects.
- **One manual network call.** The only outbound request is the update check you trigger yourself; there is no polling and no background traffic.
- **The UI thread never waits on Accessibility.** AX calls can block for seconds in a hung app. Every scan runs off the main thread with a per-call timeout.
- **Pure logic is testable.** Chord parsing, prefix matching, ranking, formatting, description cleanup, conflict detection, search (corpus, tokenizer, pinyin), hotkey matching, panel placement, usage statistics, Markdown export, and semantic versions live in a SwiftPM target with no AppKit dependency.
- **Writes are deliberate and atomic.** Search queries are transient. Settings and statistics are written as JSON files with atomic replacement, and a corrupt file is preserved rather than overwritten. What else touches the disk is derived or diagnostic and can be deleted: menu scans (10 minutes), the conflict cache, the daily log and the crash reports.
- **Degrade, never fail.** No menu bar, no permission, or a slow app should still leave a usable fallback catalog and an explanatory UI.

## Contents

[Source layout](#source-layout) · [Runtime overview](#runtime-overview) · [Menu scanning](#menu-scanning-accessibility) · [Fallback catalog](#fallback-catalog) · [Data model](#data-model-and-indexing) · [System hotkeys and conflicts](#system-hotkeys-and-conflicts) · [Config file sources](#config-file-sources) · [Ordering](#ordering) · [Trigger pipeline](#trigger-pipeline) · [Panel content](#panel-content-and-highlighting) · [Panel interaction](#panel-interaction-and-execution) · [Search panel](#search-panel) · [Palette scope and export](#search-palette-app-scope-and-markdown-export) · [Settings window](#settings-window) · [Update check](#update-check) · [Presentation](#presentation) · [Permissions](#permissions) · [Persistence](#persistence) · [Testing and CI](#testing-and-ci) · [Release](#release) · [Known limitations](#known-limitations)

## Source layout

```
KagiPeek/
├── App/
│   ├── AppDelegate.swift          # lifecycle, single instance, diagnostics, login item, main menu
│   └── Main.swift                 # AppKit entry point (no SwiftUI App/scene, so no window at launch)
├── Core/
│   ├── Pure/                      # SwiftPM target KagiPeekCore (Foundation only)
│   │   ├── KeyChord.swift         # keys, modifiers, normalization, parsing
│   │   ├── RowKeys.swift          # key codes, Enter alias, RowKeyRouter
│   │   ├── BindingItem.swift      # one shortcut/action binding
│   │   ├── PrefixResolver.swift   # prefix → child bindings, chord traversal
│   │   ├── ChordComposition.swift # one pure decision: build a stroke, classify it, swallow?
│   │   ├── Ranker.swift           # the four sort modes' shared maths (decayed usefulness)
│   │   ├── UsageOrdering.swift    # sort order applied to search results and statistics
│   │   ├── KeyFormatter.swift     # ⌘⇧C formatting, glyphs, localization
│   │   ├── KeyMapper.swift        # virtual key codes ↔ characters
│   │   ├── NavigationKey.swift    # arrows, ⌃F/⌃B/⌃N/⌃P
│   │   ├── PagingKeyPlan.swift    # four optional paging pairs, character-first decision
│   │   ├── DescriptionCleaner.swift # whitespace, trailing chord hints, the "—" placeholder
│   │   ├── SearchIndex.swift      # SearchCorpus + Pinyin + tokenized scoring
│   │   ├── ConflictDetector.swift # same chord claimed by multiple bindings, typed findings
│   │   ├── ShortcutLayer.swift    # driver → eventTap → system → global → menu
│   │   ├── ConfigTool.swift       # the six config sources, their paths and layers
│   │   ├── ConfigFileScanner.swift# one scan over every tool + shared file guards
│   │   ├── KarabinerScanner.swift # karabiner.json complex modifications
│   │   ├── SkhdScanner.swift       # skhdrc
│   │   ├── KeyboardMaestroScanner.swift # macro library hot key triggers
│   │   ├── HammerspoonScanner.swift # hs.hotkey.bind calls in init.lua
│   │   ├── AlfredScanner.swift    # workflow hotkey triggers
│   │   ├── BetterTouchToolScanner.swift # btt_data_store (SQLite, read-only)
│   │   ├── ComboLookup.swift      # "who owns this combo?" for a combo query
│   │   ├── LiveTestVerdict.swift  # what one real keypress proved
│   │   ├── HotkeyMatcher.swift    # global hotkey matching, Hyper superset rule
│   │   ├── PanelPlacement.swift   # cover / fixed / fill / beside the front window
│   │   ├── PanelSections.swift    # app card + system card, and where the boundary is
│   │   ├── PanelState.swift       # immutable panel snapshot (menu items, groups, prefix)
│   │   ├── PanelRowBuilder.swift  # one menu item/group builder for both rebuild paths
│   │   ├── PanelHighlighter.swift # which menu items belong to the shortcut in progress
│   │   ├── PanelOrdering.swift    # the panel's chord order and modifier filter rule
│   │   ├── PanelSortOrder.swift   # which order the panel uses: by modifier or by menu group
│   │   ├── PendingModifiers.swift # held (transient) vs latched (ticked) modifiers
│   │   ├── ModifierTapTracker.swift # a press-and-release of a modifier becomes a tick
│   │   ├── LatchedTicks.swift     # tick/untick, and which one ⌫ undoes
│   │   ├── PanelKeyIntake.swift   # keys the panel consumes as itself, read by the tap too
│   │   ├── PanelSelection.swift   # the only menu item is selected; a stale index is dropped
│   │   ├── RowLayout.swift        # the row's three column widths, as arithmetic
│   │   ├── PanelTheme.swift       # panel palettes
│   │   ├── HeaderLayout.swift     # responsive title-bar thresholds
│   │   ├── SystemHotkeyNames.swift# names for the system hotkeys macOS leaves unnamed
│   │   ├── IgnoredCommands.swift  # a title ignored globally or for one app
│   │   ├── MenuCachePolicy.swift  # when a cached menu scan is still valid
│   │   ├── L10n.swift             # English / Simplified Chinese strings
│   │   ├── AppSettingsModel.swift # settings values, defaults, normalization
│   │   ├── SettingsPayload.swift  # schema envelope + versioned migration hook
│   │   ├── UsageStatistics.swift  # pure usage model, 800-entry LRU, per-app rollup
│   │   ├── UsageBreakdown.swift   # per-app press and shortcut counts
│   │   ├── MarkdownExporter.swift # shortcut sheet rendered as Markdown
│   │   ├── SemanticVersion.swift  # tag parsing/comparison for the update check
│   │   ├── LogLevelFilter.swift   # diagnostic log levels
│   │   ├── LogRotationPolicy.swift# when the daily log file is rotated
│   │   ├── CrashLogFormatter.swift# crash report text
│   │   ├── SentinelState.swift    # clean-exit sentinel, so a crash is not mistaken for a quit
│   │   ├── Sanitizer.swift        # strips identifiers from exported diagnostics
│   │   └── BuiltInCatalog.swift   # 100 fallback shortcuts
│   ├── AX/
│   │   ├── MenuScanner.swift      # AXMenuBar recursion, key equivalents, axPath
│   │   ├── MenuTrigger.swift      # AXPress on a menu item (primary trigger)
│   │   ├── MenuScanCache.swift    # menu-cache/ on disk + control.json fingerprint
│   │   ├── CatalogLoader.swift    # background scan + per-app cache
│   │   ├── AppContextService.swift# frontmost app (never itself), bundle id, icon
│   │   ├── AppPermissions.swift   # grant checks
│   │   ├── PermissionCenter.swift # Accessibility / Input Monitoring state
│   │   ├── WindowGeometry.swift   # panel placement next to the focused window
│   │   ├── SystemHotkeyReader.swift # Carbon system shortcuts + SystemHotkeyNames
│   │   └── AppDirectory.swift     # running regular apps for the search scope
│   ├── Input/
│   │   ├── KeyboardMonitor.swift  # global CGEventTap, swallow rules, lazy decoding
│   │   ├── ModifierFlags.swift    # NSEvent.ModifierFlags → ModifierSet
│   │   ├── ShortcutInjector.swift # replays one chord into the front app
│   │   └── ShortcutTester.swift   # head/tail listen-only taps for "test this combo"
│   ├── Storage/
│   │   ├── DataDirectory.swift    # Application Support folder + JsonFileStore
│   │   ├── SettingsStore.swift    # settings.json, single debounced writer, preview session
│   │   └── UsageStore.swift       # usage.json, debounced background writes
│   ├── Services/
│   │   ├── AppLog.swift           # os.Logger categories: scan/input/storage/ui
│   │   ├── Diag.swift             # the in-app diagnostic log
│   │   ├── FileLogStore.swift     # logs/kagipeek-<date>.log, rotation, redaction
│   │   ├── ActionRecorder.swift   # last 30 action names, for a crash report
│   │   ├── CrashReporter.swift    # signal handlers, crash/, clean-exit sentinel
│   │   ├── DiagnosticsExporter.swift # one JSON/zip report for a bug report
│   │   ├── ConflictCache.swift    # conflicts-cache.json, read at launch
│   │   └── UpdateChecker.swift    # manual GitHub release check
│   └── Engine/
│       ├── ShortcutEngine.swift   # input router + lifecycle + collaborator wiring
│       ├── EngineState.swift      # @Published state container
│       ├── PanelSession.swift     # panel menu items, ordering, paging, menu item actions
│       ├── SearchSession.swift    # palette open/close, scope, results
│       ├── CatalogCoordinator.swift # what to scan, stale-result guards, config files
│       ├── RowRunner.swift        # resolve element → press menu → replay chord
│       ├── BindingEditor.swift    # recording target + binding writes
│       ├── LiveTestCoordinator.swift # shortcut test listening and verdict
│       ├── DiagnosticsReporter.swift # support report assembly
│       └── ConflictCenter.swift   # conflict ownership index
├── UI/
│   ├── Surface/                   # one NSPanel hosting panel + search palette
│   ├── Overlay/                   # panel and palette views, cards, rows, footer
│   ├── HUD/                       # 0.75 s "executed" toast
│   ├── Permissions/               # first-run permission guide
│   ├── Settings/                  # eight tabs: general, trigger, appearance, statistics,
│   │                              # conflicts, permissions, diagnostics, about
│   ├── MenuBar/                   # self-owned NSStatusItem and its menu
│   └── Design/                    # Theme, Localization, Interaction, TextComposition
└── Assets.xcassets/

Package.swift                      # KagiPeekCore library + KagiPeekCoreTests
Tests/KagiPeekCoreTests/           # XCTest coverage for Core/Pure
scripts/build_release.sh           # build → sign → notarize (optional) → DMG
scripts/build_swiftc.sh            # fallback build for hosts where xcodebuild cannot run
scripts/install.sh                 # atomic install, refuses ad-hoc; backups go to Application Support
scripts/backup_app.sh              # dated, commit-tagged pre-install backups; keeps the newest 5
scripts/publish_release.sh         # upload the DMG as a GitHub release
scripts/setup_signing.sh           # create the stable "KagiPeek Local" identity
Distribution/kagipeek.rb           # Homebrew cask template
```

`KagiPeek/Core/Pure` is compiled twice: as part of the app target and as the `KagiPeekCore` library in `Package.swift`. That is what lets `swift test` exercise the engine without launching an AppKit app or granting permissions.

## Runtime overview

```
                       ┌──────────────────────────┐
  frontmost app ──────►│ AppContextService        │
  (pid, bundle id,     │ NSWorkspace activation   │
   focused window)     └────────────┬─────────────┘
                                    │ scan request
                       ┌────────────▼─────────────┐
                       │ MenuScanner (AX)         │
                       │ AXMenuBar → items        │
                       │ 0.35 s per AX call       │
                       └────────────┬─────────────┘
                                    │ [menu entries]
                       ┌────────────▼─────────────┐
                       │ ShortcutEngine           │
                       │ + BuiltInCatalog         │
                       │ 20 s in-memory cache     │
                       └──────┬────────────┬──────┘
                              │            │
                 ┌────────────▼──┐   ┌─────▼─────────────────┐
                 │ PrefixResolver│   │ SearchCorpus          │
                 │ Ranker        │   │ tokenizer + pinyin    │
                 └────────┬──────┘   └─────┬─────────────────┘
                          │                │
                 ┌────────▼──────┐  ┌──────▼────────────┐
                 │ OverlayPanel  │  │ SearchPanel       │
                 │ phase: idle/  │  │ (mutually         │
                 │ armed/active  │  │  exclusive)       │
                 └────────▲──────┘  └──────▲────────────┘
                          │                │
                 ┌────────┴────────────────┴────────────┐
                 │ ShortcutEngine / PanelState          │
                 │ heldModifiers, highlightedRowIDs,    │
                 │ completedRowID, selectionIndex       │
                 └────────▲─────────────────────────────┘
                          │ events
                 ┌────────┴─────────────────────────────┐
                 │ KeyboardMonitor → HotkeyMatcher      │
                 │ gesture / 3 hotkeys / secure input  │
                 └──────────────────────────────────────┘

  JsonFileStore ◄── SettingsStore ──► every component
                ◄── UsageStore    ──► Ranker (per-app statistics)
  PanelPlacement ──► OverlayPanelController geometry
  SystemHotkeyReader (Carbon) ──► ConflictDetector ◄── scan entries
  AppDirectory (running apps) ──► search scope / conflict scan
  MarkdownExporter            ──► Export Markdown (NSSavePanel)
  UpdateChecker               ──► api.github.com releases/latest
                                  (manual, Settings → About)
```

## Menu scanning (Accessibility)

`MenuScanner` starts from the frontmost application's `AXUIElement` and walks:

```
AXMenuBar
└── AXMenuBarItem ("File")
    └── AXMenu
        ├── AXMenuItem ("New", ⌘N)
        ├── AXMenuItem ("Open…", ⌘O)
        └── AXMenuItem ("Open Recent") → AXMenu → …
```

For each `AXMenuItem` it reads:

| Attribute | Use |
| --- | --- |
| `AXTitle` | Menu item label |
| `AXMenuItemCmdChar` | Key character of the key equivalent |
| `AXMenuItemCmdVirtualKey` | Virtual key code, used when no character is exposed |
| `AXMenuItemCmdModifiers` | Modifier mask for the equivalent |
| `AXEnabled` | Whether the item is currently actionable |
| `AXChildren` | Submenu (recursed) |

Design notes:

- **Menu path is data.** The breadcrumb "File → Open Recent → …" and the note on each menu item in the panel both come from the traversal itself, so they follow whatever language and structure the app uses.
- **No key equivalent still means a menu item.** A menu item without `AXMenuItemCmdChar` or `AXMenuItemVirtualKey` becomes a menu item with an *empty chord*: KagiPeek still does not guess a shortcut the app does not advertise, but the menu item is reachable — it is triggered by pressing it (`MenuTrigger`), which is the only way to reach it. Such menu items sort after every chorded menu item, carry a `—` in the shortcut column, and never match a modifier prefix (they carry no modifiers to narrow by). The one structural rule borrowed here from Menu-Bar-Search: an item that has children is a submenu parent and is walked, not recorded — unless it also carries a key equivalent of its own.
- **The Apple menu is off by default.** Its items belong to the system, not to the app in front, and would pad every list with menu items the app does not own — so `showAppleMenu` defaults to `false` (Menu-Bar-Search's `showAppleMenu` setting). Turning it on includes them; the menu bar index is counted either way, so cached menu paths do not shift when the setting flips.
- **AX index path.** Every recorded item carries its position in the menu tree (`axPath`, e.g. `"2,0,5"` — again from Menu-Bar-Search's `pathIndices`). An empty chord has no chord to make an id or a usage key unique, and two dynamic entries can share a path and a title; without the index they would silently merge into one menu item with one click target and one set of statistics.
- **Depth and count are capped.** Recursion is bounded and guarded against cycles (a menu that contains itself); oversized menus are truncated rather than scanned forever.
- **Timeouts.** `AXUIElementSetMessagingTimeout` is set to 0.35 s for the application element. A hung app cannot stall the scan queue indefinitely.
- **Threading.** Scanning happens on a dedicated serial queue. Results are delivered to the main actor; UI state is main-actor only.
- **Whose menus are read.** The menu bar has exactly one owning app, and during a switch it is not always the frontmost one: `AppContextService` prefers `NSWorkspace.menuBarOwningApplication` and falls back to `frontmostApplication` (Menu-Bar-Search's `menuBarOwningApplication`). KagiPeek itself is still never a source — activating its own window would otherwise replace the real app's shortcuts with the fallback catalog.
- **Scanning says why it came back empty.** `MenuScanner` checks `AXIsProcessTrusted()` before walking, and every result carries a `ScanState`: `.ok`, `.noMenus` (the app exposes nothing), or `.permissionDenied` (nothing could be read at all — Menu-Bar-Search's `initState`). An empty list and a read that never happened look identical to the user, so the panel's empty state and the "built-in" badge say which one it was instead of both reading "no matching shortcuts".
- **Cache, two layers.** In memory, results are keyed by app identity and kept for 20 seconds. On disk, one JSON entry per app (`menu-cache/menus-<identity>.json`) plus a control file recording the settings the entries were written under (Menu-Bar-Search's cache). Switching apps is the moment the disk cache exists for: it hands back the menu items the user last saw for that app instead of walking the menu bar again. Its rules are `MenuCachePolicy`:
  - **Fingerprint.** An entry is only used when it was written under the current settings; a scan-shaping setting (today `showAppleMenu`) and the entry schema go into the fingerprint, so changing either invalidates every entry without reading one.
  - **Ten-minute cap.** Menus change while an app runs. Ten minutes is long enough that re-opening the panel for the same app — or relaunching KagiPeek — skips the AX walk, and short enough that a stale list refreshes quickly. A press inside the window re-walks the menu item's `axPath` and verifies its title, so a menu that changed under the cache resolves to nil, never to the menu item that took its place.
  - **A forced reload is an explicit refresh.** The palette scope refresh, a settings change, and a permission grant bypass both caches and rescan. App launch/quit only drops the in-memory snapshots: one app starting up says nothing about the menus of the app the user is working in. There is still no live menu-bar observer, so menu edits inside the app are picked up on the next scan.

A snapshot restored from disk carries menu items but no elements — `AXUIElement` cannot be serialised — so pressing such a menu item re-walks its `axPath` against the snapshot's pid with `MenuScanner.element(atAxPath:pid:expectingTitle:)`, a handful of AX calls rather than a scan, and memoises the result on the snapshot.

`MenuScanner` retains the `AXUIElement` behind every recorded item in `CatalogSnapshot.elements`, keyed by the menu item id. That map is what execution reads: pressing the item is the primary trigger, and replaying the chord is the fallback (see [Panel interaction and execution](#panel-interaction-and-execution)). Fallback-catalog entries have no AX element, so they can only ever replay their chord.

## Fallback catalog

`BuiltInCatalog` contains 100 common macOS shortcuts (system, text editing, Finder, and screenshots). It is used when:

- the frontmost app has no menu bar (some overlays, games, and custom-drawn UIs), or
- Accessibility permission has not been granted, or
- a scan fails or times out.

The catalog can be disabled in Settings. Catalog entries are marked `builtIn` and have no AX target, so they are never executed, from search or from the panel; they only copy. Live menu items and catalog entries are still reported together when they claim the same chord.

## Data model and indexing

`KeyChord` is the normalized representation of one or more key strokes. A stroke is a key plus a modifier set; a chord is a sequence of strokes (for example `⌘K ⌘C`). Normalization sorts modifiers, resolves left/right variants, and maps virtual key codes to display characters.

`BindingItem` is one menu item shown to the user:

- a display identity, plus a `usageKey` of the form `bundleID|chord` for statistics (`*` marks system and built-in entries that have no app)
- chord
- title and cleaned description
- menu path (group headers) and source app
- source: live menu, built-in catalog, or a read-only system-wide shortcut
- enabled state (from `AXEnabled`)

The AX layer keeps the element reference needed for opt-in execution; `BindingItem` itself stays pure.

`PrefixResolver` groups bindings by their next stroke for the current prefix. It answers three questions cheaply:

1. What can follow this prefix?
2. Does this prefix itself have completions (so a chord should stay open)?
3. Is the pressed key absent (so the panel closes and the HUD can show)?

`ConflictDetector` groups bindings by normalized chord. Entries with the same title, group, and source are treated as duplicates rather than conflicts. A group with genuinely different bindings marks every affected entry with ⚠︎ and feeds **Settings → Conflicts**. Conflicts are informational: macOS, not KagiPeek, decides which menu item actually receives a key equivalent.

`SearchCorpus` is built once per catalog and precomputes every haystack a query can hit: the lowercased title, its pinyin forms, its Latin word initials, the menu path, the rendered chord, the raw key tokens, and modifier words/symbols. `SearchIndex` remains a thin, backward-compatible entry point that builds a corpus per call.

The tokenizer lowercases the query, treats `+` as a separator, and splits on whitespace, so terms are **unordered**: `com op x`, `op cm x`, and `cmd+opt+x` all search the same way. Every term must match (AND); a term can match a modifier alias (`com`/`cmd`/`command`/`cm`/`⌘`, `op`/`opt`/`option`/`alt`/`⌥`, `ct`/`ctl`/`ctrl`/`control`/`⌃`, `sh`/`sft`/`shift`/`⇧`), an exact key token, or any haystack via exact/prefix/substring/subsequence scoring. `Pinyin` adds full pinyin (`jian qie`), spaced syllables, and initials (`jq`) for Chinese titles, which is why Chinese menu items can be found without typing their characters. Results are returned in score order and capped; `total = Σ per-term best score`. Nothing is persisted.

**The menu path is weighted per level.** The corpus keeps one haystack per menu level, nearest ancestor first, and a match in level *n* counts at `1 / 2^(n+1)` of its fuzzy score — Menu-Bar-Search's `levelAdjust *= 2`, with one step added so that even the nearest ancestor is discounted. The leaf always wins: a top-level name like "View" is an ancestor of dozens of menu items, so searching `view` ranks "View Source" (title prefix) above "Show Sidebar" (inside the View menu), and the word in the direct parent outranks the word in the top-level menu. A joined path haystack gave every level the same weight as the menu item's own title, which is how a menu name ended up outranking the menu item it contains.

## System hotkeys and conflicts

macOS registers its own system-wide shortcuts (Spotlight, Mission Control, screenshots, input-source switching, …) with the window server. They are not part of any app's menu bar, so `MenuScanner` never sees them. `SystemHotkeyReader` reads them through Carbon's `CopySymbolicHotKeys`, which returns an array of dictionaries:

| Key | Use |
| --- | --- |
| `kHISymbolicHotKeyCode` | Virtual key code of the shortcut |
| `kHISymbolicHotKeyModifiers` | Carbon modifier mask (⌘, ⇧, ⌥, ⌃) |
| `kHISymbolicHotKeyEnabled` | Disabled entries are skipped |
| `kHISymbolicHotKeyDescription` | Documented as a title — **empty for every entry on every current Mac** (233 of 233 on the machine this was written on) |

Rules:

- Only **enabled** shortcuts are collected, and only those with a recognized modifier combination and key code.
- System entries use `BindingSource.system`, carry no bundle identifier, and are grouped under the localized "System hotkeys" / "系统热键" title.
- **Names come from `SystemHotkeyNames`, not from the system.** The description field is a documented constant that macOS never fills, so the reader looks the chord up in a table of the assignments a stock Mac ships with (⌘Space → Spotlight, ⇧⌘3 → Screenshot, ⌃↑ → Mission Control, ⌘M → Minimize, …) and answers in the interface language. A chord that is not in the table — because the user reassigned it, or because it is one of the ~55 entries macOS lists as enabled with no function behind it (⌃F4, ⌃↩, ⇧A, …) — gets the placeholder "—" rather than the chord repeated as its own title.
- **The list is deliberately consulted, not trusted.** The Carbon table also contains stale slots; a chord being present means "macOS registered something here", which is exactly the claim the conflict list makes about it — no more.
- They live in `ShortcutEngine.systemBindings` rather than in the app's catalog, so an app's own scan stays a clean picture of its menus. They appear in the panel as the second card (`PanelSections`) — a chord the system owns belongs next to the app's menu items, where the question "why does nothing happen when I press this" is asked — and the unscoped palette searches them alongside the frontmost app's items (`searchItems`), because "who owns ⌘Space" is a searchable question too.
- The list is read at startup, when the interface language changes (the group title is localized), and whenever the app is re-activated, so edits made in System Settings are picked up without a relaunch.
- `ConflictDetector.conflicts(in:external:)` groups app entries, system entries and config-file entries by normalized chord. Identical titles are treated as duplicates; genuinely different bindings become a conflict. Every member — including the system entry — is flagged ⚠︎ in the panel.
- **Read-only.** KagiPeek never binds, changes, disables, or remaps a system shortcut; it only reports the collision. Reading the list needs no additional permission.

### How much a conflict bites

A flat list of "two things want ⌘⇧4" invites the next question — *so which one fires?* — and cannot answer it. Three pure types supply the answer, all testable without a keyboard:

**`ShortcutLayer`** places every binding on the macOS event stack: `driver` (Karabiner) → `eventTap` (skhd, BetterTouchTool, Keyboard Maestro) → `system` → `globalHotKey` (Hammerspoon, Alfred) → `otherGlobal` → `menuItem`. Lower wins. `ShortcutLayer.classify(_:)` reads the *tool*, not just the source: all six config scanners share `BindingSource.configFile`, so the source alone would rank a Karabiner rule next to a menu item.

**`ConflictCategory`** sorts findings by consequence, and names the two things that collide rather than a severity:

| Category | Meaning |
| --- | --- |
| `.menuOrder` | Two menu items of the same app claim the chord. macOS matches in menu order; nothing is broken, but one of them is unreachable. |
| `.systemShadow` | An enabled system shortcut covers this app's menu item, so the menu item never fires. |
| `.toolShadow` | A third-party tool's rule covers a menu item or a system shortcut. |
| `.systemVsSystem` | Two macOS shortcuts claim the same chord. |
| `.systemVsTool` | A system shortcut and a tool's rule collide. |
| `.toolVsTool` | Two tools claim the chord. |
| `.toolSelfOverlap` | One tool binds the same chord twice. |

**`LayerVerdict`** says who wins: `.winner` when one binding sits strictly lower, `.tied` when several share the lowest layer — registration order decides, and no config file records it, so it says so rather than guessing — and `.menuOrder` when every binding is a menu item of the frontmost app, where the stack has nothing to say.

`ConflictFilter` narrows the list in **Settings → Conflicts → Findings** on two independent axes: the *kind* of clash (`ConflictCategory` — same app's menu, blocked by macOS, blocked by a tool, one tool's own two rules, two system shortcuts, macOS vs tool, two tools) and the *owner* (any app that appears in the findings, global only, or all apps). The list is built across every running app — a per-app scan each, cache first — because "which app is this clash about" is a question you ask when you are not in that app. Because the kind names which two things collide, it also says where the fix lives: System Settings, a tool's config file, or nowhere at all. Each row shows the category badge, the verdict with the layer's own explanation, a badge per member, and a **Test this combo** button.

### Live shortcut test

`LayerVerdict` reasons from files and can be wrong. `ShortcutTester` (`Core/Input`) settles it by watching a real keypress: it installs **two listen-only event taps**, one at the head of the tap chain and one at the tail. A key that reaches the head and never arrives at the tail was swallowed by another app's tap in between — a fact, not an inference. Above the tap layer nothing is observable, so it falls back to whether an app came to the front.

`LiveTestVerdict` turns that observation into one of six outcomes with an explicit tone (`confirmed` / `informative` / `inconclusive`), and names its own blind spot: past the tap layer a system shortcut can take a key without leaving a trace. While a test is listening, `ShortcutEngine` suspends every panel behaviour and all swallowing, so KagiPeek can never be the thing that ate the key.

## Config file sources

Tools that rewrite the keyboard keep their shortcuts in a file, not in a menu bar, and every one of them hooks the keyboard *below* where an app's menu lives. Without them a conflict list can only say "two things want ⌘⇧4", never "⌘⇧4 will never reach Safari".

`ConfigFileScanner` knows the list; each tool has a scanner whose `parse` takes text, data or a decoded plist and whose `scan` finds the file. That split is what makes the parsers testable against fixtures instead of a real `~/.config`.

| Tool | File | Layer |
| --- | --- | --- |
| Karabiner-Elements | `~/.config/karabiner/karabiner.json` — complex modifications only, and only manipulators with a *mandatory* modifier (a bare key is a remap, not a shortcut) | `driver` |
| skhd | `~/.config/skhd/skhdrc` | `eventTap` |
| Keyboard Maestro | `Keyboard Maestro Macros.plist` — `MacroTriggerType == "HotKey"`, inactive macros and groups skipped | `eventTap` |
| BetterTouchTool | newest `btt_data_store.version_*`, opened **read-only**; `BTTTriggerClass == "BTTTriggerTypeKeyboardShortcut"`, app-scoped entries skipped | `eventTap` |
| Hammerspoon | `~/.hammerspoon/init.lua` — `hs.hotkey.bind` with literal arguments; a variable modifier table is dropped rather than half-resolved | `globalHotKey` |
| Alfred | `Alfred.alfredpreferences/workflows/*/info.plist`, following `prefs.json` for synced preferences; a trigger with an empty `hotstring` is unassigned and skipped | `globalHotKey` |

Config bindings carry `configTool`, which feeds `ShortcutLayer` and keeps the id unique per owner. They are **not** added to the panel, the search results or the catalog: there is no menu item to press and no element to trigger, so a menu item would only be clickable-looking decoration. They feed conflict detection, the combo lookup and the settings list.

Scanning is **on** by default, and **Settings → Conflicts → Config file sources** can turn it off entirely, which forgets what was found and opens no file outside KagiPeek's own data folder afterwards. A scan runs at launch and on demand, deliberately *not* on every app switch: these files change when the user edits them, not when they change apps.

### Combo lookup

The conflict list only shows clashes, so a combo one thing owns alone used to come back empty, and an empty list reads as "not scanned" rather than "nobody else wants this". `ComboQuery` parses a query that spells out a combo (`cmd shift 4`, `⌘⇧4`, `opt cmd t`) — every token must be a modifier or a key, there must be exactly one key and at least one modifier, which is what keeps `cmd safari` a plain text search — and `ComboLookup` answers who owns it or that it is free, matched on the same chord key `ConflictDetector` groups by so the two can never disagree.

## Ordering

Three different questions, three different orders, and mixing them up was a real bug once:

- **The panel is in its chosen order** (`PanelSortOrder`). The default, **By modifier**, is the reference-card order (`PanelOrdering`): fewer strokes first, then the modifier set by significance (⌘, ⌥, ⌃, ⇧), then the key, with a function key sorting as the word it is named after (`f`, `f1`, `f2`, … `g`) and a menu item with no shortcut after every chord. **By menu group** keeps every top-level menu contiguous in menu-bar order (the first component of `axPath`), and inside a menu the same shortcut order applies. Items with no Accessibility path follow the ranked menus, and an empty group is last. `sortMode` does not touch either order.
- **The search palette is in match order** — `SearchCorpus` scores, described under *Search panel*. Selecting a sort order there would mean discarding the ranking that answers the query.
- **The statistics page is in the chosen order** (`RankMode` + `UsageOrdering`), for both the per-app list and the rows inside an app. `sortMode` used to be read by the panel (through the old `Ranker.rank`) and by nothing on the statistics page that displayed the picker; both were wrong, and the page now honours the setting it shows.

`Ranker` itself keeps only the shared maths: `decayedUsefulness` weights a press count by an exponential decay with a roughly 60-day scale, so recent use counts most and old use fades gradually. It is what `smart` means, in the statistics list and nowhere else.

| Mode | Meaning for a statistics list |
| --- | --- |
| Smart order (default) | Decayed usefulness first, then raw press count. |
| Most used first | Press count, then menu item name. |
| Key order | `PanelOrdering`, so the page and the panel agree on what "along the keyboard" means; apps fall back to name order. |
| Alphabetical | Localized menu item name. |

Disabled menu items keep their place in the order — the comparator looks at the chord, not at `AXEnabled` — they are only drawn greyed out, and hidden entirely when **Show unavailable menu items** is off.

While modifiers are held, the menu items that can be reached from them keep the same order among themselves, which is what makes the narrowed list re-sort as more modifiers go down. Favourites float above everything when **Pin favourites to top** is on. The Shift hint layer (`ShiftHintLayer.labels(for:)`) is rebuilt from the displayed sequence on every rebuild, so `0`–`9` / `a`–`z` follow whatever order is on screen instead of staying bound to a menu item. The menu path travels with the menu item as a small note between the title and the chord instead of a section heading, which is why ordering can no longer cut the ⌘ block in half.

`UsageStore` records a count and a last-used timestamp keyed by `bundleID|chord`, so the same shortcut in two apps is tracked separately and a localized title change does not lose history. System and built-in entries use `*|chord` and are reported as **System / built-in** / **系统 / 内置**. `UsageStatistics.summariesByApp()` rolls the records up into `AppUsageSummary` values (bundle id, press count, distinct shortcut count, last used); `UsageOrdering.apps` orders them by the chosen mode (it falls back to the app name where a mode needs a chord), which is what the **Statistics** tab renders. Frequency is exponentially decayed (a roughly 60-day scale), so recently used shortcuts rise and stale ones fade instead of dominating forever. The model keeps a running `totalPresses` and caps records at 800, pruning the least recently used entries. It never stores raw key events, typed text, or window contents. Resetting statistics clears the records; settings are unaffected. Persistence is described under [Persistence](#persistence).

## Trigger pipeline

`KeyboardMonitor` installs one global event tap under the Accessibility grant. It observes `flagsChanged` and `keyDown` (plus tap-disabled notifications) and passes events through unchanged, with these exceptions:

- the three recorded hotkeys (panel, search, switch) are consumed so the front app does not also receive them — through the same `HotkeyMatcher` rule used for activation, including the Hyper superset tolerance;
- while a panel is active, its navigation keys (↑/↓/←/→, ⌃F/⌃B/⌃N/⌃P), the characters of every enabled paging pair (`,`/`.`, `[`/`]`, `-`/`+`, `;`/`'`), whatever the two action keys are recorded to (including the keypad-Enter alias), Esc and a bare `/` are captured through `updateCapturedKeys`. `/` is captured so the app behind never also sees it — in a browser that key is *quick find*, which would otherwise open on top of the palette KagiPeek just opened;
- a key that **completes** a shortcut is not swallowed: the panel closes and the event continues to the front app.
- repeats of a captured key are swallowed too. Letting them through would move the panel selection and scroll the front app at the same time; the engine separately ignores repeats for actions that should not fire twice.

Characters are decoded lazily: `KeyboardMonitor` only reads the Unicode string while a surface is taking keys or a binding is being recorded (`updateDecodesKeyEvents`), because the tap sees every key press in the session. While the panel is active, `ShortcutEngine` also publishes the enabled paging characters with `updateCapturedCharacters`, so the swallow check compares the character the layout actually produced (`；` on a Pinyin layout) instead of hard-coded ASCII key codes; the key codes remain the fallback for events with no decoded character. Hotkey matching is done on the virtual key code, so it works without decoding.

It never records events. The one thing it synthesises is a single chord, on request: `ShortcutInjector` posts it when a menu item runs (see [Panel interaction](#panel-interaction-and-execution)). The run-loop source is attached to the main run loop, so callbacks arrive on the main thread and must stay fast. If the tap cannot receive events on a particular system, `PermissionCenter` offers Input Monitoring as the fallback.

`ShortcutEngine` runs a three-phase state machine. v2.1.0 renamed the old `browsing`/`pinned` pair to a single `active` phase, because every panel is now persistent:

| Phase | Meaning | Entered by | Left by |
| --- | --- | --- | --- |
| `idle` | Nothing is showing | dismissal, a released hold, Esc | hold delay, trigger-key double tap, a hotkey |
| `armed` | A hold is being timed; the panel is not visible yet | the trigger key being released, or another key being pressed | the delay elapsing (→ `active`) |
| `active` | The panel is visible and persistent | `activatePanel()` | a complete shortcut (after ~0.4 s highlight), Esc, the panel hotkey again |

| Trigger | Detection |
| --- | --- |
| Modifier gesture, hold | `modifierTriggerEnabled`; the chosen `triggerKey` is held for `holdDelay` (0.5 s by default, 0.3–0.9 s in 0.1 s steps) with no other key during the interval |
| Modifier gesture, double tap | `modifierTriggerEnabled`; two clean presses and releases of `triggerKey`, with no other key between. Only the gap between the taps is timed: `DoubleTapTiming` derives it from the system double-click speed, clamped to 0.25–0.6 s. A slow press still counts, and a long second press still completes |
| Trigger key | One of any non-Shift modifier, left Control, left Option, left Command, right Command (default), or right Option. `flagsChanged`'s key code tells left from right; combinations are not supported |
| Panel hotkey | Global hotkey, default ⌃⌥⌘K; toggles the panel and refreshes it in place when the frontmost app changes |
| Search hotkey | Global hotkey, default ⌃⌥⌘F; opens or closes the search palette |
| Switch hotkey | Global hotkey, default ⌃⌥⌘S; swaps between the panel and search (see below) |
| Hotkey switch | `hotkeyTriggerEnabled` gates all three hotkeys independently of the gesture; with both switches off nothing triggers (the pause state) |

Additional rules:

- **The gesture owns its key.** While `modifierTriggerEnabled` is on, the tap swallows the press and release of `triggerKey`'s physical key code, so the front app never sees the modifier edge that may fire the panel; a cancelled hold is not replayed. Shift and Caps Lock are never swallowed. While recording a hotkey, no modifier is swallowed. The hotkey path publishes its own swallow rules only while `hotkeyTriggerEnabled` is on.
- **Holding modifiers to summon the panel seeds the prefix.** `activatePanel(seedPrefix:)` pushes the held set onto `prefix` when the long-press path calls it, so the panel narrows which-key style; the hotkey and double-tap paths pass `seedPrefix: false` and start empty, which is where every menu item is a complete combination. While the panel is open, a modifier change re-seeds a modifier-only prefix (`handleModifiers`); a chord prefix that already contains a key (⌘K of ⌘K ⌘C) survives the modifier being released between strokes. A lone ⇧ never counts. `panel.heldModifiers` records the same set, and while the prefix is still modifier-only it is also what highlighting matches against. The title bar's ⌃ ⌥ ⇧ ⌘ chips are a second, sticky way to narrow: a tick narrows exactly like holding the key (`panel.latchedModifiers`), and it also composes — a ticked ⌥ plus a pressed C is ⌥⌘C. Ticks survive until unticked or until the panel is dismissed.
- Pressing a non-modifier key cancels a pending hold; in `active` the key is routed to the completion/chord resolver.
- **Releasing modifiers does not dismiss the panel.** There is no idle timer and no auto-hide task; the panel is dismissed by Esc, the panel/switch hotkey, or a completed shortcut. Switching the frontmost app or the active Space dismisses it as well, because its contents belong to the app it was opened over.
- Secure input is checked before showing anything; if it is active, the panel is hidden and the trigger is ignored.
- **Panel and search are mutually exclusive.** `showSearch()` dismisses the panel, and `activatePanel()` (via the panel hotkey) is not allowed to stack on top of search; the switch hotkey encodes the rule: search visible → panel, panel visible → search, neither → panel.

### Engine state and key routing (development, after v2.2.0)

The decision half of the engine has been moving into `Core/Pure`, where the XCTest suite can reach it:

- **`KeyEventRouter` replaces the inline decision tree in `handleKeyDown`.** The engine now calls `KeyEventRouter.route(...)` and executes the returned `KeyDownAction`; routing order is unchanged (hotkeys in any phase → the phase transition → the panel's own keys → chord composition), so the panel behaves as before, but every branch is a named, tested action instead of nested `if`s inside a long method. The characterize tests pin the pre-existing behaviour branch by branch.
- **`ModifierDoubleTap`, `DoubleTapTiming` and `HyperEscape` are the two gesture state machines.** The trigger-key double-tap pin and the hyper-tap-as-Escape gesture used to keep three date/flag fields on the engine (`lastCommandDownAt`, `hyperArmedAt`, `hyperUsedKey`) with the timing rules inline; each is now one pure struct with its own tests. `ModifierDoubleTap` reads the trigger key's pressed state, so the same machine serves any of the six trigger keys; `DoubleTapTiming` derives its window from the system double-click speed (clamped to 0.25–0.6 s), which is why there is no double-tap slider; `HyperEscape` still owns the 1 s release window and the "a key was used meanwhile" flag.
- **`FavoritesPolicy` aggregates the three favorites booleans.** The star toggle (`showsFavoritesOnly`) and the two settings (`pinFavoritesToTop`, `favoritesCanBeFiltered`) used to be passed into every rebuild separately and repeated in both cache keys (`OrderedHitsKey`, `RowBudgetKey`); a cache key now holds one `FavoritesPolicy` value, so a change to any of the three invalidates the order and budget together.
- **`SearchSnapshot` is the palette's state.** `comboAnswer`, the `searchQuery`/`searchResults`/`searchSelection` trio, `isSearchVisible` and the three scope publishers are one `@Published var search` snapshot; the scope icon stays engine-side because it is an `NSImage`. Only a `query` change re-runs the search — `refreshSearch()` writes results/selection/visibility back into the snapshot without looping.
- **`EnginePhase` replaces the engine's private `Phase` enum** so the pure router can read the panel phase without importing the engine.

### Engine/state split: `EngineState` as the state container (development, P0-2)

`ShortcutEngine` used to be one `@MainActor` class holding ~40 `@Published` values, session state, caches, gesture machines and in-flight tasks next to every collaborator and every behaviour method. The P0-2 step splits that in two, without changing any behaviour:

- **`Core/Engine/EngineState.swift`** is a new `@MainActor final class EngineState: ObservableObject` holding everything the UI binds or the coordination reads and writes: the 29 published values (`panel`, `settings`, `search`, `conflicts`, `catalogSize`, …), the session state (`phase`, `prefix`, `previousModifiers`, the `ModifierDoubleTap`/`HyperEscape`/`ModifierTapTracker` machines, `lastSecureInputLog`), the catalog and caches (`catalog`, `catalogGeneration`, `orderedHitsCache`, `rowBudgetCache`, `usageBreakdownCache`, `conflictIDs`), the search scope (`searchScopeCatalog`, `searchCorpus`, `searchCorpusKey`), and the in-flight task handles. It also computes the palette title/icon (`searchPaletteTitle`, `searchPaletteIcon`) and the filtered Conflicts list (`visibleConflicts`, `conflictTypeOptions`) from that state.
- **Two collaboration injection points keep the container pure.** `defaultTitle` is set by the engine from the localised app name; `searchChangeHandler` is the engine's `refreshSearch`, installed so that a query change re-searches without the container knowing about the catalog. `search`'s `didSet` only fires the handler when the *query* changed, so `refreshSearch()` writing results/selection/visibility back cannot loop.
- **`ShortcutEngine` is now the coordinator**: collaborators (`settingsStore`, `usageStore`, `surface`, `hud`, `appContext`, …) plus all behaviour methods, and a single `let state = EngineState()` in place of the former declaration block. The engine seeds `state.settings`/`state.defaultTitle`/`state.searchChangeHandler` in `init` and writes state as before; SwiftUI surfaces bind straight to the container.
- **UI wiring.** `OverlayView`, `SettingsView` and `ConflictRowView` gain `@EnvironmentObject private var state: EngineState` and read `state.panel` / bind `$state.search.query`; the hosting controllers (`SurfacePanelController`, `SettingsWindowController`) inject `.environmentObject(engine.state)`, so the `engine` environment object remains for collaborators only.
- **Types shared between engine and state moved to file scope**: `HotkeyTarget` is now a file-level enum, and the cache keys `OrderedHitsKey`/`RowBudgetKey` live at the bottom of `EngineState.swift` (they no longer nest inside the engine). `EngineState` is part of the AppKit target, not the SwiftPM `KagiPeekCore` target, so the pure layer stays AppKit-free.

### Engine collaborators split (development, R-3)

After `EngineState` took the state, `ShortcutEngine` was still one file holding every
collaborator next to the input router. R-3 splits the collaborators out without changing
behaviour: the engine keeps the state machine, the event tap calls and the pointer, and
delegates everything else.

| Module | Owns | Depends on |
| --- | --- | --- |
| `Core/Engine/ShortcutEngine.swift` | `handleKeyDown` routing, phase/prefix, panel open/close, tap capture, pointer return | all collaborators |
| `PanelSession.swift` | menu items, ordering, pagination, selection, favourites, copy, activate/descend, completion | `EngineState`, `RowRunner`, `UsageStore`, `Presenters` |
| `SearchSession.swift` | palette open/close, scope switch and load, result ranking, Markdown export | `EngineState`, `RowRunner`, `CatalogCoordinator` |
| `CatalogCoordinator.swift` | frontmost catalog scans, generation guard, exclusion, system hotkeys, config scans | `CatalogLoader`, `AppDirectory`, `EngineState` |
| `RowRunner.swift` | element resolution (including restored-snapshot re-walk), menu press, chord replay, HUD/failure | `CatalogLoader`, `UsageStore`, `Presenters` |
| `BindingEditor.swift` | recording target, `RecordingPolicy` application, settings writes | `EngineState`, `SettingsStore`, `RecordingPolicy` |
| `LiveTestCoordinator.swift` | shortcut test start/cancel/verdict/polling | `EngineState`, `ShortcutTester` |
| `DiagnosticsReporter.swift` | support report fields | `EngineState`, stores |

Dependency direction stays inward: `Core/Pure` (policy, plans, state shapes) knows nothing
about AppKit, I/O or `Core/Engine`; the collaborators above hold AppKit only because they
perform effects, and `Ports/PresentationPorts` keeps their outward calls behind protocols.
The engine's public surface is kept as one-line forwarders so the UI and
`PreviewScenarios` call sites did not move.

Deliberate boundaries:
- **Input routing stays in the engine.** `handleKeyDown`, the phase transitions, the
  captured-key set, the double-tap/hyper machines and pointer return are one state machine;
  splitting them across modules would turn every key into a distributed transaction.
- **Open/close stays with routing.** `activatePanel`/`dismissPanel` manipulate the phase,
  the tap and the pointer, so they remain next to the router, while `PanelSession` starts
  from "the panel is visible".
- **Recording rules are pure.** `RecordingPolicy` and `SearchScopePlan` live in
  `Core/Pure`; their tests pin the branches the settings UI can reach.

### Live shortcut test as a pure session machine (development, P1-3)

The live test's orchestration used to be private inside `ShortcutTester` (AppKit): the nested `State` enum, the pending-press/early-tail fields, the pairing windows and the observation construction were all untestable next to the `CGEvent` taps. The P1-3 step splits that the same way the engine split:

- **`Core/Pure/ShortcutTestSession.swift`** is a pure event machine: `begin(chord:permissionGranted:)`, `abortTapsUnavailable()`, `tick(remaining:)`, `keyAtHead(...)`, `keyAtTail(...)`, `appActivated(...)`, `settle()` and `verdict(for:items:ownerNameForBundleID:)`. It owns the `ShortcutTestState` enum (idle / unavailable(reason) / listening(secondsRemaining) / finished(observation)) and the timing constants (`listenWindow`, `settleNanoseconds`, `tailPairingNanoseconds`), so the head/tail pairing window and the activation attribution are pinned by unit tests without a keyboard.
- **`ShortcutTester` keeps the AppKit half only**: the head/tail event taps, `NSWorkspace` frontmost-app reads, the activation observer, the countdown/settle `Task`s and `PermissionCenter`. Every decision is a delegation to the session machine; `ShortcutTester.State` is now a `typealias` to `ShortcutTestState`, so the engine's `liveTestState` typing is unchanged.

### OverlayView sliced by state (development, P2-2)

The surface used to be one ~1000-line `OverlayView` whose `body` read most of `EngineState`
directly, so any published change — a selection move, a scan-progress update, a search
result — invalidated and recomputed the whole tree. The P2-2 step splits it into four
sub-views, each subscribing to its own slice of state through `@EnvironmentObject`:

- **`OverlayHeaderView`** — the shared title bar: app identity, search field, scope menu,
  modifier chips, favorites toggle, scan/conflict indicators, count, close. Owns the search
  field's `@FocusState` and the focus-on-token/visibility logic.
- **`OverlayPanelContentView`** — the shortcut list (scanning/empty states, row grid) plus
  the row-level interaction state (`hoveredRowID`, `pressedRowID`, `hoveredStarID`). Reads
  `panel.*` and `scanState`; the hover reset on an app-name change lives here too.
- **`OverlaySearchContentView`** — the combo banner and the results/empty state, reading
  `search.comboAnswer/results/selection/query`.
- **`OverlayFooterView`** — count, paging, and the action hint.

`OverlayView` stays a thin shell (frame, background, corner radius, and the
panel↔palette switch), so a change inside one area no longer redraws the others. Behaviour
and appearance are unchanged; the Debug app build and the 656 tests pass.

### Concurrency boundaries

- The event tap is attached to the main run loop's `.commonModes` (see [Trigger pipeline](#trigger-pipeline)): callbacks arrive on the main thread, and `KeyEventRouter` + `ChordComposition` must stay fast enough to run there. No blocking work is done in the tap path.
- AX menu scanning runs off the main thread on a background queue with concurrency two (a slow scan for the previous app can finish after a fast one for the current app); a generation counter lets only the newest request publish. The update check and the cross-app conflict scan are likewise cancellable `Task`s publishing back onto the main actor.
- `PanelState` and the search snapshot are mutated only on the main thread, and `PanelState` remains a wholesale-replaced immutable snapshot — the engine never mutates one in place.
- The `completionTask` that keeps the row highlight visible after a completed shortcut is cancelled on dismissal, so the highlight cannot outlive the panel that showed it.

## Panel content and highlighting

`PanelState` is an immutable snapshot replaced wholesale on every rebuild. The fields that matter here are `prefixLabels` (the chord breadcrumb), `heldModifiers` (the modifier set currently down; while the prefix is still modifier-only it is what narrows the list and what `PanelHighlighter` matches against), `latchedModifiers` (the modifiers ticked by tapping one or clicking its chip — sticky, and folded into the next stroke), `completedRowID` (the shortcut being completed), `selectionIndex`/`flatRowIDs` (keyboard selection) and `showsFavoritesOnly`. The menu items are built by `PanelRowBuilder` — one path, one builder. Highlighting is not a stored field: it is recomputed per rebuild and carried on `PanelRow.isHighlighted`.

The shortcut list is one flat list ordered by the chord (`PanelOrdering`); the menu path is a note under each menu item between the title and the chord, so nothing reorders a block. It has exactly two sections — the app's menu items and the system's hotkeys — and each is drawn as a **card** (`groupSection`): a title strip with the section's name and its full count, a hairline under it, and a border around the block. The boundary between the two is therefore a shape rather than a line of text, and it survives scrolling and the narrow layout.

**The order is by modifier significance: ⌘, then ⌥, then ⌃, then ⇧.** A stroke compares its modifier set from the most significant down, a set that runs out first comes first, and only then the key: `⌘X`, `⌥⌘X`, `⌃⌘X`, `⇧⌘X`, `⌥X`, `⌃⌥X`, `⇧⌥X`, `⌃X`, `⇧⌃X`, `⇧X`. ⌘ leads because it is the modifier people actually press; the canonical print order (⌃⌥⇧⌘) is how a chord is *drawn*, not how it should be found. Chords with no modifier at all (`F5`, `⌫`) lead the list. (Counting modifiers first — the rule of two revisions ago — put every two-modifier shortcut after every one-modifier shortcut, which split `⌃⌥C` away from `⌃C`.)

Keys compare as words: `f`, `f1`, `f2` … `f12`, then `g`, because a function key is named after a letter and that is where a reader looks for it; digits, punctuation and the named keys (Return, Tab, arrows) follow. `UsageOrdering.keyOrder` sorts the Statistics tab with this same comparator, so one shortcut cannot sit in two different places in two views.

```
empty prefix (hotkey summon)   ⌘ held (hold summon)      chord prefix ⌘K
  ⌃A   Beginning of Line        ⌘A  Select All            ⌘C  Copy
  ⌃B   Move Backward            ⌘C  Copy                  ⌘S  Save
  ⌥D   Delete Char Right        ⇧⌘A  …                    ⌘K ⌘C  Copy
  ...                          (rows narrowed; the ⌘ in   (breadcrumb ⌘ ⌘K)
                                every row is lit, not
                                stripped)
```

A narrowed menu item keeps its full chord: holding ⌘ lights the ⌘ in `⌘C` instead of hiding it and printing a bare `C`. Only after a key has actually been typed does a menu item drop back to the which-key view and show the stroke still missing, because the breadcrumb already names what was typed. The key column is built from `KeyFormatter.segments`, one glyph per segment, so the emphasis is a colour change on the held modifier — never a re-parse of the formatted string.

**Highlight data flow.** The menu items and their visual state are recomputed together, so there is no partial highlight state to go stale:

1. `flagsChanged` → `panel.heldModifiers = modifiers`, and a modifier-only `prefix` is re-seeded (a lone ⇧ is ignored) → `rebuildPanel()`.
2. `rebuildPanel()` orders and pages the rows (`PanelOrdering`, favourites first when pinned), then `highlightedIDs(for:)` marks the menu items in play: at a chord prefix every menu item `PrefixResolver` reaches from it, while only modifiers are held every menu item whose first stroke's modifier set is a **superset** of them. Because the visible set is narrowed by the same superset rule, the two coincide at that level — the held modifier glyph in each surviving menu item is also emphasised, so the information is in the key labels as well as the glow.
3. A `keyDown` that exactly matches a binding calls `complete(_:probe:)`: it records usage, ensures the menu item's page, sets `panel.completedRowID`, and rebuilds, so the menu item's **description** renders in the accent color.
4. A completion task sleeps for ~0.4 s (380 ms), then clears `completedRowID` and dismisses the panel. The key event is not consumed, so the front app receives the shortcut.
5. Esc or the panel/switch hotkey dismisses immediately through `dismissPanel()`.

**Two distinct states.** `selectionIndex` (↑/↓) is a keyboard cursor and persists across rebuilds; `isHighlighted` follows the physically held modifiers; `isCompleted` is the short accent flash. `OverlayView` renders selection, key highlight, and completion independently, so a selected menu item and a modifier-matched menu item do not look the same.

**Chord descent still exists** for multi-stroke shortcuts. Pressing a stroke that is the first step of a chord pushes it onto `prefix` and rebuilds one level down; a breadcrumb shows the prefix. ⌫ pops one stroke and is handled only when no other modifier is held, so ⌘⌫ remains an ordinary shortcut; Esc dismisses whatever the modifiers. Pressing a key with no match leaves the panel open instead of closing it.

**A stroke can be assembled from two sources.** `PendingModifiers` keeps `held` (physically down, transient) and `latched` (ticked in the title bar, sticky) apart, and only `effective` — their union, minus a lone held ⇧ — narrows the list and lights the menu items. So `⌥⌘C` is reachable three ways: hold all three (the original behaviour), tick ⌥ and ⌘ and press `C`, or mix the two. `ChordComposition.resolve(prefix:physical:pending:key:in:)` is the single pure decision: it builds the probe chord from `physical ∪ latched`, classifies it (`complete` / `descend` / `noMatch`) and reports `composed` — true when part of the chord came from the panel rather than from the event.

The consequence is that **swallowing and injecting are the same decision**. `KeyboardMonitor.shouldSwallow` asks `ChordComposition` before the engine sees the key, and `handleKeyDown` asks it again while handling it, so the tap and the handler cannot disagree and run a shortcut twice:

| `composed` | Outcome | Tap | Engine |
| --- | --- | --- | --- |
| false | any | lets the event through | the front app performs the shortcut; the panel only flashes the menu item |
| true | `complete` / `descend` | consumes the key (and its release) | replays the **assembled** chord through `ShortcutInjector`, or pushes the prefix one level down and clears the tick |
| true | `noMatch` | lets the event through | nothing; the tick is kept, the user is mid-sequence |

Two seams had to close for that table to hold. `PanelKeyIntake.isConsumedBeforeComposition` lists the keys the panel consumes as *itself* — `/`, Escape, the arrows, `;`/`'` and the action keys — because with a ticked modifier those arrive carrying nothing, and `⌥;` being a real binding would otherwise let the tap eat a `;` that only ever pages the list; the tap and `handleKeyDown` read the one list. And the tap remembers a key-down it consumed and consumes the release too, which matters exactly when the modifiers change under the key — a composed stroke makes that certain, because the panel dismisses itself on the key-down and by the release there is no tick left to recognise.

⌫ undoes one tick, last first, and only then pops a level. A half-built sequence is dropped when the panel is dismissed and when Esc closes it.

The panel has no text field of its own. `/` swaps it for the search palette (`showSearchFromPanel()`), and in the palette `/` swaps back (`returnToPanelFromSearch()`) — but only while the field is **empty**: with nothing typed there is nothing to lose, so `/` closes the round trip; once there is a query, `/` is an ordinary character, because a search box that refuses a slash mid-word is the worse bug. macOS's ⌘/ (Help) is never touched: the toggle requires a bare slash.

The round trip starts a fresh search every time. `openSearch()` resets the query, the results, the selection, the scroll request, the combo answer and the scope before the palette is shown (`SearchSnapshot.beginNewSession()`), so a query typed ten minutes ago cannot masquerade as today's search. The palette's header carries a back chevron, because the field takes focus immediately and `/` would otherwise be a one-way door.

Pagination is a presentation concern, not a data concern: the page size is configurable (default 24 rows, 6–60) and bounded by what fits the current screen. The overlay renders page `n/m` and pages via clickable ‹ › or scroll wheel. Rows can be laid out in one to three columns (default two), and description text is truncated to a configurable length (default 30 characters) with an ellipsis before layout. Page keys form a loop: next on the last page returns to the first, previous on the first jumps to the last. A one-page list ignores both keys — `PaginationPlan.moved` reports no movement, so the panel is not rebuilt and shows no "turned a page" state.

## Panel interaction and execution

Because every panel is persistent, it is usable without the shortcut that opened it. Key handling lives in `ShortcutEngine.handleKeyDown`:

| Input | Action |
| --- | --- |
| ↑ / ↓ | Move the selection by one row, clamped to the current page |
| ← / → | Previous / next page, wrapping at the ends; the selection returns to the first row. A one-page list does not move |
| `;` / `'` | Same paging loop by typed character (ANSI key code only for undecoded events) |
| Run key (`settings.runRowKey`, Space by default) | Run the selected menu item |
| Copy key (`settings.copyRowKey`, Return by default) | Copy the selected menu item's chord |
| Esc | Close the panel |
| ⌫ | Undo the most recently ticked modifier, then pop one chord level. With nothing left to undo the key is let through — it never closes the panel |
| Click | Same as the run key |
| Click a modifier chip | Tick it: narrows the list and composes a stroke |
| `/` | Swap the panel for the search palette (and back, from the palette while its field is empty) |
| Complete shortcut | Highlight the menu item's description for ~0.4 s, then close and let the event through |

- **A shortcut is run, not swallowed, whenever the panel can be the one that runs it.** A complete shortcut pressed with modifiers the panel supplied is consumed by the tap and replayed in full through `ShortcutInjector`, with the HUD showing the assembled chord rather than the bare key. A complete shortcut pressed normally is left alone, so the front app performs it itself and the panel only flashes the menu item — that path is byte-for-byte what it was before composition existed. Narrowing to a single menu item is enough for the run key and for a click to work, because `PanelSelection.resolved` selects the only row there is; the last stroke of a chord is never drilled into, so clicking it replays the whole chord instead of emptying the panel.

- **The navigation keys are captured only while the panel is active, with no modifier held.** `updateCapturedKeys` registers the arrows with an empty modifier set, plus whatever the two action keys are recorded to (`HotkeySpec.capturedIdentifiers`; Return and the keypad Enter are one key in both directions), and `KeyboardMonitor` swallows those key-downs so the front app never sees them. The set is cleared when the panel is dismissed. A modifier-plus-key combination that is not a action key (⌥⌘Esc, …) is not in the set, so it stays an ordinary shortcut.
- **The menu item contract is two recorded keys, one surface (the search palette is a run-only second surface).** `RowAction` (`.execute` / `.copy`) is applied by `performPanelRow`: `.execute` sends the menu item through `activate(rowID:)` — a group row descends one level, a disabled menu item is ignored, everything else records usage, closes the surface and triggers the menu item — while `.copy` writes the rendered chord to the pasteboard and shows the "Copied" toast without closing anything (a menu item with no shortcut has nothing to copy and says so instead of clearing the pasteboard). `RowKeyRouter.action(for:modifiers:run:copy:)` is the single implementation of that rule, shared by the panel and the palette's list; run is matched before copy, so recording both to the same chord degrades to the primary action instead of leaving one unreachable. The footer hints render the two recorded chords, so remapping cannot leave a lying hint.
- **Triggering the menu item is the primary goal, so every run surface presses the menu item first.** `MenuTrigger.press(_:)` performs `AXPress` on the `AXUIElement` the scan retained for the menu item. That is the only way to reach a menu item with no keyboard shortcut, and for the ones that do have one it is exactly what clicking the menu would do — the app's own validation and current state apply, and a chord that was decoded wrong never gets replayed. Replaying the chord through `ShortcutInjector` is the fallback, used when the press fails (a stale element after the menu changed, an app that refuses the action) or when the menu item has no element at all (system hotkeys, fallback-catalog entries). The element does not have to belong to the frontmost app, so the panel can trigger without stealing focus; the search palette, which does take the keyboard, hands it back to the app it is scoped to afterwards.
- **Recording is stricter for global hotkeys than for action keys.** A global hotkey must carry ⌘/⌥/⌃ or typing would fire it; a action key is only read while the panel owns the keyboard, so a bare Return is fine. Bare characters and the panel's navigation keys (Esc, arrows) are refused either way — a bare letter would break chord entry and filtering.
- Selection, key highlighting, and completion are separate visual states, as described above; a completed shortcut is not executed by KagiPeek, so the front app still receives it. Running a menu item is the explicit exception: it closes the surface and triggers the menu item — pressing it when there is one, replaying the chord otherwise.

Selection is index-based over `flatRowIDs` so grouped two- or three-column layouts move in reading order without flattening rows in the view. Every rebuild and page change clamps `selectionIndex` to the current page.

## Search panel

Search is a separate, global panel (default ⌃⌥⌘F), reachable from its hotkey or by pressing `/` in the panel. It searches the scoped app's live menu bindings plus the system's hotkeys (unscoped) or that one app's bindings (scoped), using one `SearchCorpus` per scope identity — rebuilt when the scope, the catalog, the key style or the language changes, which is why the scope id is part of the corpus key.

- **Tokenized, unordered matching.** The query is lowercased, `+` is treated as a separator, and the rest is split on whitespace. Every term must match — `com op x`, `op cm x`, and `cmd+opt+x` are equivalent. There is no phrase requirement and no order requirement.
- **Modifier aliases.** `com`/`cmd`/`command`/`⌘`, `op`/`opt`/`option`/`alt`/`⌥`, `ct`/`ctl`/`ctrl`/`control`/`⌃`, `sh`/`sft`/`shift`/`⇧`. A recognized alias scores high when the chord actually has that modifier.
- **Key tokens and text.** Exact key tokens, title, menu path, rendered chord, and modifier words/symbols are all haystacks. Exact/prefix/substring/subsequence scoring, weighted toward the title, chooses the ranking.
- **Chinese pinyin.** `Pinyin.forms(of:)` converts a Chinese title with `.mandarinToLatin`, then adds full pinyin (`jianqie`), spaced syllables (`jian qie`), and initials (`jq`). Typing `jq` or `jian qie` finds 剪切 without switching input methods.
- **English initials.** Multi-word titles also contribute their Latin word initials, so `fs` finds Find Similar.
- ↑/↓ moves the selection; Return acts on it.
- **The palette runs, it does not copy.** `confirmSearchSelection()` → `activateSearchResult(_:)` hides the palette, activates the app the palette is scoped to, records usage and triggers the menu item: pressing it when there is one, otherwise posting the chord through `ShortcutInjector`. Return here is always Return: the recorded action keys belong to the panel, which is why the palette footer reads `↵ run` instead of rendering `settings.runRowKey`.
- **There is no copy path in this surface.** `RowAction` is applied by the panel only. To copy a chord without running it, use the copy key there.
- Running a search result can trigger destructive actions (Delete, Empty Trash, Quit) immediately, which is why the first match is selected but nothing runs until you press Return.
- **The panel and search are mutually exclusive.** `showSearch()` dismisses the panel first, and the switch hotkey (⌃⌥⌘S by default) moves from search to panel, from panel to search, or opens the panel when neither is visible.

- **The palette's state is one snapshot.** `SearchSnapshot` carries the query, results, selection, visibility, combo answer and scope identity as one `@Published` value on the engine; only a query change re-runs the search, and `refreshSearch()` writes results/selection/visibility back without looping. The scope icon is the one thing that stays engine-side (an `NSImage`).

Search never records queries. It runs over the current in-memory catalog; nothing is persisted.

## Search palette: app scope and Markdown export

The palette searches the frontmost app's catalog plus the system's hotkeys. Its results are
rendered **one card per menu category** (`SearchSection`): the category is the card's header
and nothing inside repeats it, the shortcut has a fixed column of its own, and the menu item
fills the rest of the row with its deeper menu path underneath when there is one. The three
kinds of content therefore never share a line, and the boundary between two categories is a
border rather than a heading in the same stream. Ordering, selection, hover, click and
scroll-to-selection are unchanged: a card is rendering only, the results array is still the
engine's flat, ranked list.

Two things that used to live in a separate window are now in its title bar:

- **App scope.** `runningApps` (from `AppDirectory`) feeds a menu whose first entry is
  *Frontmost app* and clears the scope; picking another running app loads its catalog through
  `CatalogLoader` with `force: false` — the 20 s cache answers when it can — and searches that
  instead. The scope resets to the frontmost app every time the palette opens, so it never
  answers a question left over from last time. The panel is unaffected: it always follows the
  real frontmost app.
- **Export Markdown.** `makeSearchMarkdown()` delegates to the pure
  `MarkdownExporter.render(appName:items:style:language:)` and writes the matches when there is
  a query, the scope's full list when there is not. The palette presents an `NSSavePanel`
  (default file name `<App>.md`), writes UTF-8, and confirms through the HUD.

The document contains a `# KagiPeek — <App>` title with a timestamp and menu item count, one
`## <menu group>` section per first-level menu, a `| Shortcut | Action |` table per section
(pipes escaped, disabled menu items suffixed `_(unavailable)_`), and a footer link. The exporter does
no file I/O, which is why it is unit tested without AppKit.

## Settings window

`SettingsView` is one SwiftUI window with eight tabs (`SettingsTab`): **General**, **Trigger**, **Appearance**, **Statistics**, **Conflicts**, **Permissions**, **Diagnostics**, **About**. Statistics and conflicts used to share one "Ranking" page, which made each of them hard to find and the page long enough that the numbers at the top were never seen.

| Tab | Contents |
| --- | --- |
| General | Interface language, launch at login, executed HUD, built-in catalog, *Include the Apple menu*, *Show Dock icon*, **Menu item actions** (the two recorded action keys), **excluded apps** (a selectable list filled from an `NSOpenPanel`, not a text field of bundle identifiers), ignored menu items (one disclosure group per scope) |
| Trigger | Two independent switches: **Modifier gesture** (hold still / press twice, one trigger key, and the hold delay; the double-tap window follows the system double-click speed) and **Global hotkeys** (the three recordable hotkeys: panel, search, switch). Both can be on, either one alone, or both off — both off is the pause state |
| Appearance | Key style, panel theme (System / Light / Dark), key position, columns, rows per page, description length, disabled items, favourite pinning and filtering, **panel placement** (cover / fixed size / fill screen / beside), fixed width and height when *Fixed size* is selected |
| Statistics | Sort order, per-app statistics (press count and shortcut count per app, one collapsible section per app, *Show data folder*, *Reset statistics*), *Restore defaults* |
| Conflicts | Config file sources (what was read, counts, rescan), type filter, related-app filter, scan timestamp, manual rescan, paged findings with **Test this combo** |
| Permissions | Accessibility and Input Monitoring status, **Request Access** (system prompt + opening the matching System Settings pane), and a draggable KagiPeek icon |
| Diagnostics | Logging on/off, verbose logging, log folder, **Export diagnostics archive…** (.zip), live status (Accessibility, Input Monitoring, listening, catalog count), **Export diagnostics report…** (.json) |
| About | Icon, version with commit (`v2.2.0 (836e3c3)`), system version, manual update check, data folder (open button), repository and license |

The statistics tab is fed by `UsageStore.summariesByApp()`: one row per bundle identifier with the total presses and the number of distinct shortcuts, plus **System / built-in** for `*`, ordered by `UsageOrdering.apps` and expanded per app through `usageEntries(for:)` (which puts `sortMode` in its cache signature so changing the picker cannot serve the previous list). **Show data folder** opens `~/Library/Application Support/KagiPeek` in Finder.

The conflicts tab reads `ConflictCache` at launch and only scans when you press **Rescan** (or when nothing has been cached yet): the scan walks every running app's menus, and doing that on each visit is the "it hangs when I open the page" complaint. Findings are rendered in pages of 40 because a `Form` builds every row it is handed.

The permissions tab's icon is a real drag source (`NSItemProvider` / file URL): dropping it into the Accessibility or Input Monitoring list in System Settings adds the running app, which is handy when the list has no entry yet. **Request Access** calls the system prompt and then opens the corresponding pane, instead of only doing one of the two.

## Update check

The About tab of **Settings** offers a manual release check, and it is the only network code in the app.

- `UpdateChecker` is a main-actor `ObservableObject` with states `idle`, `checking`, `upToDate`, `available(tag, url)`, and `failed`.
- `check(currentVersion:)` sends one GET to `https://api.github.com/repos/suliveevil/KagiPeek/releases/latest` with `Accept: application/vnd.github+json`, a `KagiPeek-update-check` user agent, and a 12 s timeout.
- The response must contain `tag_name` and `html_url`. `SemanticVersion` strips a leading `v` and any pre-release/build suffix, then compares `major.minor.patch` against the running `CFBundleShortVersionString`.
- A newer tag → `.available`, and the row becomes a link that opens the release page in the default browser. Equal or older → "You're up to date". Any network, HTTP, or parse failure → a short failure message.
- **No polling, no automatic download, no installation.** Nothing runs until the button is pressed, and the request carries no user, app, or shortcut data.

## Presentation

- `SurfacePanelController` owns one non-activating `NSPanel` that hosts both the panel and the search palette (one surface at a time), so keystrokes continue to reach the frontmost app until the palette needs the field.
- `WindowGeometry` reads the frontmost window and focused-element frames (AX, 0.2 s timeout) and converts them to Cocoa coordinates. `OverlayPanelController` then resolves **`PanelPlacement`** (a pure enum with four cases) against the screen that contains the front window, falling back to the screen under the pointer:

  | Placement | Size | Position |
  | --- | --- | --- |
  | Cover the front window (default) | At least large enough to cover the window in both dimensions (never below its natural size, capped at the visible frame); the content height for the widened column count is only used when it is taller than the cover height; 80% × 70% of the screen when no window frame exists | Centred on the visible frame |
  | Fixed size | `fixedPanelWidth` × `fixedPanelHeight` (default 720 × 620, clamped to the visible frame) | Centred on the visible frame |
  | Fill the screen | The visible frame | The visible frame |
  | Beside the front window (v2.0 behaviour) | The panel's natural size | Beside the window, flipping sides as needed, and avoiding the focused element; top-right fallback when there is no window |

  Placement is recalculated each time the panel is shown or resized, so moving the window and reopening the panel picks up the new frame. In native fullscreen the front window fills the screen and the visible frame equals the screen frame, so the 24 pt margin is clipped away: the panel matches the screen exactly and still covers the window.
- **The search palette sits on the front window, not on the screen.** Its width is fixed at 680 pt and its height is at least the window's height (clamped to the visible frame), so it spans the front window vertically instead of a fixed 460 pt near the top edge. The frame is centred on the window's centre and clamped into the visible frame; with no window frame it falls back to the screen centre. The front app's pid is read before `NSApp.activate()`, because afterwards the frontmost app is KagiPeek itself.
- **The panel is sized for the widest list of the session, not for the page on screen.** Pressing a modifier narrows the list by definition, so a window sized from the current page changed height on every press and again on release — on screen that read as the panel jumping. `PanelState.rowBudget` / `headingBudget` carry how many rows and headings the un-narrowed list shows (nothing composed, paginated, with one heading reserved for the system section), and `OverlayMetrics` sizes from the larger of that budget and the rows actually drawn, so the frame holds while the list moves inside it and can never clip a row. The budget is recomputed when the catalog, the chips, the favourites-only toggle, the ignored titles or the page size change — never per keystroke. An inline filter used to have a budget of its own; the filter is gone, and with it the question of what "the list before the query" means.
- `PanelTheme` stores System / Light / Dark, resolves against the window's
  `effectiveAppearance`, and decodes old Graphite / Midnight / Paper files onto the dark and
  light palettes so an existing panel does not change look.
- `Theme` uses a dark translucent material, honours **Reduce Transparency** (opaque background) and **Increase Contrast** (stronger borders and text), and keeps keycaps legible in both.
- `HUDPanelController` renders the short "executed" toast; it can be disabled in Settings.
- The app is an `LSUIElement` agent: no Dock icon, no app switcher entry, and no window at launch. `Main.swift` builds the app as plain AppKit rather than a SwiftUI `App` with scenes, because a `Settings` scene opened an empty window on launch and a `MenuBarExtra` made the status item impossible to own. `showDockIcon` switches the activation policy to `.regular` and `applicationShouldHandleReopen` then opens Settings; ⌘, opens Settings at any time.
- Interface language follows the system and can be overridden in Settings. `L10n`, `KeyFormatter`, and `BuiltInCatalog` provide English and Simplified Chinese strings; live menu titles come from the scanned app and are already localized by that app.

## Permissions

`PermissionCenter` tracks two independent grants:

| Grant | API | Required for |
| --- | --- | --- |
| Accessibility | `AXIsProcessTrustedWithOptions` | Menu scanning, creating the global event tap, `AXPress` execution |
| Input Monitoring | `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` | Optional fallback when key events are not delivered with Accessibility alone |

Accessibility is required. Input Monitoring is a fallback, not a second mandatory gate: KagiPeek checks it separately and points to it only when the key tap is not receiving events. Missing Accessibility leaves the fallback catalog and disables triggering; missing Input Monitoring only matters on systems that gate key delivery. **Request Access** in the Permissions tab calls the system prompt and then opens the matching pane, and the tab also exposes the app as a drag source so it can be dropped into the System Settings list. Both deep links use the System Settings (macOS 13+) anchors and are spelled out once, in `PermissionCenter`.

Status is observed three ways: a 3-second poll per ungranted permission (stops once granted), a `DistributedNotificationCenter` observer for the undocumented `com.apple.accessibility.api` notification — the system posts it when an app's Accessibility trust is toggled, so a revocation while KagiPeek keeps running is acted on immediately instead of at the next activation — and a re-check whenever the app becomes active or the Mac wakes. The polls and activation re-checks stay as the fallback if the notification ever stops being posted; Input Monitoring has no equivalent notification and relies on them. Reading the system hotkey list goes through Carbon and needs no additional grant, and the update check needs no permission. See [PERMISSIONS.md](PERMISSIONS.md) for the user-facing guide.

## Persistence

Settings and statistics live in `~/Library/Application Support/KagiPeek/` as plain JSON files, not in `UserDefaults`. That location does not depend on the preference domain, so a reinstall or a differently signed build keeps the data.

```text
~/Library/Application Support/KagiPeek/
  settings.json                  # { schemaVersion, settings } — user data
  usage.json                     # { schemaVersion, statistics, favorites } — user data
  conflicts-cache.json           # the last cross-app conflict scan, read at launch
  menu-cache/
    control.json                 # schema + settings fingerprint every entry was written under
    menus-<identity>.json        # one cached menu scan per app identity
  logs/                          # kagipeek-<date>.log, last-actions.json, session.active
  crash/                         # crash reports, one JSON file each
```

`DataDirectory` resolves the folder (`FileManager.applicationSupportDirectory` + `KagiPeek`) and creates it on demand. `JsonFileStore` is the small shared store both stores use:

- **Atomic writes.** The payload is encoded with `JSONEncoder` and written with `.atomic`, so a crash mid-write cannot leave a truncated file.
- **Corrupt files are preserved, not discarded.** If `JSONDecoder` fails, the file is renamed to `<name>.corrupt-<unix timestamp>.json` (for example `settings.corrupt-1761112345.json`) and kept beside the original; the app continues with defaults. A later save writes a fresh file, and the corrupt copy remains for inspection.
- **Migration happens once and in priority order.** `settings.json` first; if it is absent, the v2.0 `UserDefaults` payload under `settings.v2`; if that is absent, the handful of 1.x keys read from the legacy `com.Voltline.KagiPeek` domain (`settings.overlayHoldDelaySeconds`, `settings.keyDisplayStyle`, `settings.overlayColumnCount`, `settings.maxDisplayCount`, `settings.launchAtLoginEnabled`). Usage migrates the same way from `usage.v2`. The first write after loading creates the JSON files; after that, `UserDefaults` is not read again.
- **Only two of these files hold user data.** Everything else is derived or diagnostic: `conflicts-cache.json` and `menu-cache/` are reproducible by scanning again, and `logs/` + `crash/` exist to explain a bug — `ActionRecorder` keeps the last 30 action *names* (never menu text, typed characters or queries), logging can be switched off under **Settings → Diagnostics**, and deleting the folder costs a rescan and a history, nothing else. Search queries and raw key events stay in memory either way.
- **The menu cache is derived data.** Unlike settings and statistics, every entry can be reproduced by scanning the app again, so an unreadable entry is dropped instead of preserved next to it, and a failed write costs a rescan and nothing more. It is local-only and never leaves the machine.

`AppSettingsModel` owns defaults, ranges, and validation in pure Swift, so settings can be tested without AppKit. v2.0.0 made `sortMode` default to `.smart`. v2.1.0 added `panelPlacement` (default `.coverWindow`), `fixedPanelWidth` (720, clamped 320–4000), `fixedPanelHeight` (620, clamped 240–3000), and `switchHotkey` (⌃⌥⌘S), and **removed `autoHideDelay`**. v2.2.0 added the two recorded action keys (`runRowKey`, `copyRowKey`), `excludedBundleIDs`, `ignoredCommands`, `showAppleMenu`, `showDockIcon` and the diagnostics switches, and removed `allowPanelExecute` and `allowSearchExecute`, which had stopped controlling anything, plus `keepBrowserOpenAfterRun` and the `contextFirst` sort mode, which lost their subjects when the browser window and the redundant mode went. **Panel order** (`panelOrder`) was added after that: the settings schema is now version 6, and a v5 file has no key, so `decodeIfPresent` gives the default **By modifier** without a rewrite.

**Removing a key needs no migration step.** `AppSettingsSnapshot` only implements `init(from:)`, and every field there is `decodeIfPresent` with the default as fallback, so an older payload decodes, the unknown key is ignored by `CodingKeys`, and the next save drops it. `SettingsPayload`/`SettingsMigrator` exist so that the *version* is read and not only written: `isOutdated(_:)` reports that a file came from an older build, and a future incompatible change has one place to add its step. The invariant that keeps "no migration step" honest — decode an old payload, re-encode without the removed key — has a unit test. `usage.json` carries its own version now: sharing the settings constant meant a settings migration would silently claim the statistics file had changed too.

Trigger settings v5 replaced the four-way `triggerMode` with `modifierTriggerEnabled`, `hotkeyTriggerEnabled`, `triggerGesture` and `triggerKey`. `SettingsMigrator` maps `holdModifiers` to the gesture on / hold / **Any modifier**, `doubleTapCommand` to the gesture on / double tap / **Any modifier**, `hotkey` to the gesture off with the hotkeys still on, and `disabled` to both switches off; the legacy key is decoded once and is not written back. The 2.0 `UserDefaults` blob has no schema envelope, so it goes through the same migration step.

`UsageStatistics` is the pure value both `UsageStore` and the tests use:

```text
UsageStatistics
  totalPresses: Int
  records: [usageKey: UsageRecord]   // usageKey = "bundleID|chord" ("*" = system/built-in)
    UsageRecord: { count: Int, lastUsed: Date }
```

The 800-record cap is enforced with a least-recently-used prune after every recorded press. `summariesByApp()` aggregates the same records into `AppUsageSummary` (bundle id, presses, distinct shortcuts, last used) for **Settings → Statistics**. A decode failure falls back to empty statistics rather than crashing. Resetting clears `totalPresses` and all records.

## Testing and CI

`Package.swift` declares `KagiPeekCore` (path `KagiPeek/Core/Pure`) and `KagiPeekCoreTests` (path `Tests/KagiPeekCoreTests`). The XCTest suite covers:

- chord parsing and normalization
- key mapping and special keys
- prefix matching and chord traversal
- the four sort modes, translated into both a usage list and a per-app list (`UsageOrdering`)
- key formatting and breadcrumbs
- description cleanup and truncation
- conflict detection (including duplicate suppression)
- search indexing and fuzzy scoring
- localization completeness (both languages, matching format placeholders)
- built-in catalog integrity (size, unique chords, both titles)
- usage statistics (recording, 800-entry LRU cap, encode/decode, reset)
- decayed usefulness (`Ranker`): a recent press outranks an old one at equal count, and a count of zero scores zero
- `SemanticVersion` parsing (`v` prefix, pre-release suffix) and comparison
- `MarkdownExporter` grouped table rendering, including the unavailable marker
- system-hotkey conflicts against app bindings, with external entries
- tokenized search: terms in any order, `+` as a separator, modifier aliases, all terms required
- pinyin full/initial forms and Latin word initials
- `HotkeyMatcher`: exact modifier match, Hyper superset allowed at three or more modifiers, strict matching below three, wrong key code rejected
- per-app usage grouping and `bundleID` parsing from `bundleID|chord`
- `PanelPlacement` encode/decode and the settings defaults (cover window, switch hotkey)
- decoding of older payloads, including one that still carries `allowPanelExecute`/`allowSearchExecute`, and re-encoding dropping those keys
- `RowKeyRouter`: run wins over copy on a shared chord, unbound keys are not routed, an extra modifier is not a action key
- `HotkeySpec` matching and `capturedIdentifiers`: Return and keypad Enter are equivalent in both directions, and both lists come from the same alias table
- `PanelRowBuilder`: group order, `index == -1` for unselectable rows, flat order excluding them
- `HeaderLayout`: the 460/600 thresholds and which controls each density keeps
- `PanelOrdering`: fewer strokes first, then fewer modifiers, then the modifier order, then the key; the filter rule is "carries every filtered modifier"
- `PanelSortOrder`: **By modifier** equals the old order exactly; **By menu group** keeps each top-level menu contiguous in menu-bar order, keeps the shortcut order inside a menu, and puts unranked groups after ranked ones with an empty group last; switching the order moves the `0`–`9` / `a`–`z` Shift labels to the new positions
- the settings schema writes version 8; a v7 payload without `pagingPairs` migrates to the default `;` / `'` pair, unknown members of the set are dropped rather than rolling the whole file back, and a v5 payload without `panelOrder` migrates to **By modifier**
- `PanelSelection`: zero rows select nothing, one row selects it, a stale index is dropped rather than clamped to the last row
- `RowLayout`: the note column disappears below 300 pt, the key column is capped in both directions, and the title floor of 60 pt engages only at the narrowest supported row
- `KeyChord.isFinalStroke`: one source of truth for "this stroke is the last one", shared by descent and menu item activation
- `PendingModifiers` and `ChordComposition`: held vs latched, the lone-⇧ rule, the `composed` guard rail, and the full swallow truth table
- `PanelKeyIntake`: navigation, the enabled paging pairs, the action keys, `/` and Escape are claimed before composition; ⌫ is deliberately not on the list
- `PagingKeyPlan`: either the first character of an enabled pair (previous) or the second (next), matched on the typed character first and the ANSI key code only when the event has none; arrows are never part of it, several pairs can be on at once without swallowing each other, and `+` (Shift+=) still pages while the Shift-hint layer is up because it is not a `0`–`9` / `a`–`z` label
- `SearchKeyRouter`: all eight paging characters pass through to the search field, so a focused query field never pages
- narrowing is preserved: a held or ticked ⌘ keeps ⇧⌘A, because the rule is "carries every held modifier", not "equals it"
- menu-path weighting: a title match outranks a menu-name match, and the nearer level outranks the deeper ancestor
- `OverlayMetrics` sizing is stable: narrowing the list keeps the session's height, a budget smaller than the rows on screen cannot clip them, an empty budget falls back to the rows drawn, and a heading reserved by the widest list stays reserved
- `MenuCachePolicy`: the fingerprint tracks the scan-shaping setting, an entry expires exactly at the age cap, a future timestamp is refused, and a mismatched or missing control file invalidates the whole cache
- `BindingItem` survives a JSON round trip (`id`, `usageKey`, `chord` with its alternates, and the empty chord), which is what a cache restore depends on
- `SystemHotkeyNames`: known chords get a name in either language, a reassigned chord and a multi-step sequence get none, and the table has no duplicate chord
- the nameless-entry contract: an empty title cleans to `DescriptionCleaner.placeholder`, which is what a system hotkey macOS cannot name shows
- `IgnoredCommands`: normalizing drops duplicates within a scope, the same title in two scopes stays two rules, and the legacy flat title list migrates to global rules
- `KeyEventRouter`: hotkeys answer in any phase with panel→search→switcher precedence; idle passes through, armed cancels, active routes; Escape by key code works with no decoded character; a bare `/` opens search; navigation (arrows, ⌃N/⌃P) and paging (`;`/`'`) work while narrowed, where held modifiers are stripped; the action keys answer runs/copies but not repeats; ⌫ pops a tick before a level; an unknown or `nil` key with no match keeps the panel
- `ModifierDoubleTap`: fires on two clean press–release pairs of the trigger key when the gap between them is inside the window, times only that gap (a slow press still counts), forgets its candidate on a typed key, and never fires from a held trigger key; it reads the trigger key's pressed state, so one machine serves all six trigger keys
- `DoubleTapTiming`: derives the window from the system double-click speed and clamps it to 0.25–0.6 s, so the gesture has no separate user setting
- `HyperEscape`: arms on the hyper set, dismisses on a clean release inside the window, clears on any other press, and a key used meanwhile cancels the dismiss
- `FavoritesPolicy`: the star toggle narrows to favorites, pin-to-top moves favorites first keeping each group's order, and equality covers all three rules

AppKit/AX/UI behaviour is not unit tested: the Xcode project has a single app target and no test target, so `Core/AX`, `Core/Engine`, `Core/Input`, `Core/Storage` and `UI` (about 6,300 lines after the v2.3.0 refactor) have nowhere to run assertions. The response so far has been to move what *can* be pure into `Core/Pure` — `RowKeyRouter`, `PanelRowBuilder`, `HeaderLayout`, `PanelState`, `PanelSections`, `UsageOrdering`, and in the v2.3.0 refactor `KeyEventRouter`, `ModifierDoubleTap`, `HyperEscape`, `FavoritesPolicy`, `SearchSnapshot` and `EnginePhase` — and test it there. The engine's `handleKeyDown` is now a thin side-effect executor over `KeyEventRouter`, so the routing half of the largest AppKit class is under test.

GitHub Actions runs on `macos-15`: a Debug build, a Release build (both with signing disabled), `swift test`, then a coverage report for the pure target. The 70 % line-coverage floor is a hard gate: a run below it fails the job. It runs on every branch push and on pull requests. See [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Release

`scripts/build_release.sh` builds Release, reads the version **from the built bundle** (`CFBundleShortVersionString`), and cross-checks it against `MARKETING_VERSION`; a mismatch or an empty value is a hard error, because a `sed` that picked the wrong copy of that setting once produced `KagiPeek-.dmg` and a `v` release tag. It signs with a Developer ID Application identity when available (and attempts `notarytool` notarization; missing credentials skip it with a warning), otherwise falls back to the stable local identity or ad-hoc signing. The self-signed branch skips `--timestamp`, so an offline build does not fail at the last step. The `.app` and the `.dmg` are both signed and verified, both are stapled when notarizing, and a `SHA256SUMS` line is written next to the image.

`scripts/install.sh` builds, stages the bundle next to the destination, verifies the signature, swaps it in with `mv`, and copies the replaced bundle to `~/Library/Application Support/KagiPeek/backups/` through `scripts/backup_app.sh`. Backups are named `KagiPeek-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app` and the five most recent are kept; a failure mid-swap restores the newest backup. Nothing but `KagiPeek.app` is ever placed in `/Applications`: a second copy of the same bundle id is picked up by LaunchServices, and an ad-hoc copy becomes a separate TCC identity. The installer refuses an ad-hoc build outright — a stable `KagiPeek Local` or Developer ID signature is required — because an ad-hoc cdhash changes on every compile, so macOS treats each rebuild as a new app and permissions are asked again. Ad-hoc output from `scripts/build_swiftc.sh` is for `codesign --verify` in a temporary directory only. It quits the app by bundle identifier instead of `pkill -f`, which used to match build copies and other users' instances too. `scripts/build_swiftc.sh` is the fallback build for hosts where the Xcode build system cannot run at all, because it wraps every compile in `sandbox-exec` and nested sandboxing can be denied.

`Distribution/kagipeek.rb` is a Homebrew cask template. It must be copied into a `homebrew-tap` repository before `brew install --cask kagipeek` works.

The app is not distributed through the Mac App Store. The sandbox is disabled because reading another app's menu bar and observing global key events are not possible inside the App Sandbox.

## Known limitations

- **Menu bar only.** Shortcuts implemented directly in custom views, toolbars, or games are invisible; only menu items with key equivalents appear. The fallback catalog covers common system actions, not every app's private UI.
- **Apps that build menus lazily** may show incomplete results until their menu bar has been opened once.
- **Secure input** suppresses key events by design; the panel hides.
- **The panel has no idle timer.** It stays until Esc or the panel/switch hotkey. That is deliberate, but a panel left on screen stays there.
- **Cover-window geometry is a snapshot.** The cover size is computed from the front window's frame when the panel opens; resizing the window afterwards does not re-place the panel until it is reopened.
- **Hyper matching is permissive by design.** A hotkey with three or more modifiers also matches events carrying extra modifiers, so an unrelated app that adds a modifier can still trigger it. Hotkeys with fewer than three modifiers are matched exactly.
- **Conflicts are informational.** macOS picks the winner. The system shortcut list is read-only: KagiPeek cannot bind, change, or disable Spotlight, Mission Control, or any other system hotkey.
- **Cross-app scope is a snapshot.** The palette shows the selected app's menu scan at that moment; the 20 s cache and lazy menu construction still apply, and the panel never switches away from the frontmost app.
- **Panel execution needs live menu items.** Fallback-catalog entries copy instead of executing, and disabled menu items are not run at all.
- **The update check is manual.** It needs network access, only compares versions, and opens the release page instead of downloading or installing anything.
- **No remapping.** KagiPeek reports shortcuts and can optionally press a menu item; it does not define custom bindings.
- **A copy key recorded on a narrowing modifier is ambiguous.** Held modifiers are stripped while narrowing, so the old default copy key ⌘↩ could not be told apart from `⌘` + `↩` and answered run. The default copy key is now plain Return and has no such collision; a custom copy key on ⌘ meets the old rule again, so copying then means releasing ⌘ first, recording it on ⇧↩, or ticking ⌘ in the title bar instead of holding it — the tick is not in the event.
- **The tap's key-up memory is per key code.** A consumed key-down makes the tap consume that key's release whatever the modifiers are by then, which is the safe direction; it cannot distinguish two keyboards.
- **macOS only.** It relies on AppKit, Accessibility, and Core Graphics event taps.