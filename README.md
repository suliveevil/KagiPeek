# Kaname

[![CI](https://github.com/suliveevil/kaname/actions/workflows/ci.yml/badge.svg)](https://github.com/suliveevil/kaname/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/suliveevil/kaname?display_name=tag)](https://github.com/suliveevil/kaname/releases/latest)

**Press and hold a modifier. See what the app you are in can do next.**

Kaname is a menu bar utility for macOS. It reads the frontmost app's menu bar through the Accessibility API and shows its shortcuts in a floating panel. The panel is **persistent**: it stays until you press Esc, toggle it off, or complete a shortcut. A modifier pressed while it is open joins an ordered filter, and a letter pressed while that modifier is still down narrows further; the trigger key's own press is not a filter token, so the panel opens on the full list of complete combinations (⌘C). There is no per-app shortcut pack to install and no configuration file to maintain: if an app has a menu bar, Kaname can show its shortcuts, including chords, disabled items, and conflicts — and it can trigger any of them, including menu items that have no shortcut at all.

The shortcut engine was rewritten around live menu scanning. The panel then became keyboard-driven
and clickable, then persistent, and the features grew around that list: four placement modes,
tokenized and pinyin-aware search, Hyper-key matching, per-app statistics in Application Support,
guided permission onboarding, and a panel/search switch hotkey. Conflicts name their **type** and a
likely winner instead of a severity, the cross-app scan is cached on disk behind a manual rescan, and
every menu item is now run by pressing it in the menu itself — so menu items with no shortcut at all
are reachable too. [CHANGELOG.md](CHANGELOG.md) carries the per-version detail.

`macOS 14.0 Sonoma or later · menu bar agent · local by default · GPL-2.0`

[Features](#features) · [Install](#install) · [First run](#first-run) · [Usage](#usage) · [Configuration](#configuration) · [Privacy](#privacy) · [Architecture](#architecture) · [Development](#development) · [FAQ](#faq) · [中文](README.zh-CN.md)

## Screenshots

<!-- Screenshots are captured by the app's built-in preview mode. -->

![The panel's two cards: the app's menu items, then the system's hotkeys](docs/images/overlay.png)
*Hold a modifier and pause. The panel covers the focused window by default and narrows to the level of the modifiers you are holding, so each menu item shows what can come next. It stays until you press Esc or toggle it off; ↑/↓ select a menu item and the run key acts on it. Two cards, never interleaved: the app's menu items under its name, then the system's hotkeys under theirs — named where macOS lets us name them (Minimize, Spotlight, Force Quit) and an em dash where it does not. The list is a reference card rather than a copy of the menu bar: menu items are ordered by the shortcut itself and the menu a menu item lives in is the middle column, so ⌘C, ⌘V and ⌘X sit together whichever menu they came from. Each menu item is three aligned columns — the title, its menu, and the shortcut — so a long menu item name never pushes its neighbours' menu paths out of line.*

![The same panel at 300 pt wide](docs/images/overlay-narrow.png)
*The title bar gives way in a fixed order: the result count, then the modifier chips and the favourites toggle, then the app name and subtitle. The settings and close buttons stay reachable — in a one-column panel they used to be pushed outside it. The menu column is dropped rather than squeezed, and the "has a sub-level" chevron moves into the trailing slot so it survives.*

![Ticking modifiers instead of holding them](docs/images/overlay-latch.png)
*Pressing a modifier while the panel is open adds it to the panel's ordered filter, and the next press narrows on top of it — ⌃ then F keeps only shortcuts that carry both. Clicking a title-bar chip ticks the modifier instead, so it stays down after release; ⌫ takes back the last token you added, then the last tick.*

![Holding a modifier instead of ticking it](docs/images/overlay-held.png)
*Holding is the other half of the same list: pressing a modifier while the panel is open adds it to the filter, and letting go leaves that condition in place. The menu item keeps its whole chord either way; the modifier you pressed is lit in place rather than stripped, so a menu item narrowed by ⌘ still reads ⌘C and not just C.*

![Menu items that have no shortcut at all](docs/images/overlay-noshortcut.png)
*Triggering the menu item is the point, so the panel does not stop at menu items that can be typed: one with no key equivalent still gets a row, sorted after every shortcut, with the shortcut column left blank. Running it presses the menu item itself — the only way to reach it — and the same press is tried first for every other menu item, with the chord replayed only as a fallback.*

![The search palette listing matching shortcuts](docs/images/search.png)
*The palette names the app it is answering for — icon, name, and an app menu for the frontmost app plus every running regular app — and groups its matches into cards by menu. Return closes the palette and triggers the menu item in the app you scoped to: pressing it in the menu when it has a target, replaying the chord otherwise. The palette has no copy action; the export button writes what you are looking at to Markdown.*

![Kaname settings](docs/images/settings.png)
*Settings has seven tabs: General, Trigger, Appearance, Statistics, Conflicts, Permissions, and About. General holds the two recorded action keys, the excluded and ignored lists, and a collapsed Diagnostics group at the end; statistics and conflicts each have a page of their own.*

![The first-run permission guide](docs/images/permissions.png)
*One card per permission, with what it is for, whether it is required, and a Grant button that opens the exact System Settings pane.*

## Features

| | |
| --- | --- |
| **Live menu scanning** | Reads the frontmost app's menu bar recursively through Accessibility: menu titles, key equivalents, enabled state, and the position of each item in the tree. Items with no key equivalent are kept too — they are triggered by pressing the menu item, not by typing. Any app with a standard menu bar works without a custom shortcut list. |
| **Fallback catalog** | 100 built-in system, text-editing, Finder, and screenshot shortcuts fill in when an app has no menu bar or a scan cannot run. Can be disabled. |
| **Persistent panel** | The panel stays until you press Esc or toggle it off. The summoning press is a trigger, not a filter token: the hotkey (⌃⌥⌘K), the double tap and the hold all open on the whole list, so every menu item is a complete combination (for example ⌘C). A modifier pressed **while the panel is open** joins an ordered filter, and releasing the keys leaves that condition in place. |
| **Modifier and letter filter** | Hold ⌃ while the panel is open, then press a letter, to combine them into one query (`⌃ f`): the list keeps only menu items that answer both, in the panel's normal order. ⌫ takes back the last token — the letter if the letter came last, otherwise that modifier; pressing the same modifier again removes it wherever it sits in the queue, and a third press adds it back at the tail. Completing a shortcut emphasises its description for about 0.4 s, then the panel closes. |
| **Chords** | Multi-stroke shortcuts such as `⌘K ⌘C` descend one level at a time. ⌫ takes back the filter's last token first, then goes back one stroke; Esc closes the panel, and the next open starts from an empty filter; a breadcrumb shows the current prefix. Pressing a key with no match leaves the panel open. |
| **Menu grouping** | Each menu item keeps the menu it came from as its middle column, with the app's own menu titles in the app's language. A group heading appears only when **Panel order** is **By menu group**; there the card is headed with the app's name, the system section with **System hotkeys**, and each config-tool card with that tool's name. The default chord order is one flat list, so it draws no heading. |
| **Three sections** | The app's menu items come first under its name, macOS's own hotkeys follow under **System hotkeys**, and third-party config tools come last — one card per tool, each folded independently, with its row count still visible. The tool section is **hidden by default**; **Settings → Conflicts → Config files** turns it on, and that switch only affects display (the scan and the conflict list keep running either way). While a filter is in force every tool card opens, so a matching row is never hidden behind a fold. A chord the system owns is thus visible next to the one the app owns. Config-tool rows can be copied and favourited but never run; the six whole-Mac actions (sleep, restart, shut down, lock, log out / force log out, force quit) are marked red and are never run either. |
| **Pagination** | Long lists are paged with `1/3` and clickable ‹ ›. **Max menu items per group** is an upper bound, not a promise: if the current window fits fewer, the panel shows fewer instead of pushing the last menu items under the footer. The panel never grows past the screen. |
| **Actionable panel** | ↑/↓ select a menu item, ←/→ always page, the run key (Space by default) runs the selected menu item, the copy key (Return by default) copies it, and Esc closes. Up to four punctuation pairs can page alongside the arrows under **Settings → General → Menu item actions** — `;`/`'` by default, with `,`/`.`, `[`/`]`, `-`/`=` as further checkboxes; several may be on at once, or none. While no modifier is held these keys are consumed by the panel, so the front app never sees them; a completed shortcut is not consumed, so the app still receives it. Clicking a menu item does what the run key does. Both keys are **recorded** under **Settings → General → Menu item actions**. |
| **Executed HUD** | A 0.75 s toast such as `⌘C Copy ✓` confirms a panel execution or a copy. Can be disabled. |
| **Conflict detection** | Bindings that claim the same combination are marked ⚠︎, and **Settings → Conflicts** lists every member with a **type** rather than a severity: menu-order overlap, a system shortcut shadowing a menu item, a third-party tool shadowing either, system-vs-system, system-vs-tool, tool-vs-tool, and a tool fighting itself. Each finding names the layer and says which one wins — or honestly says "same layer, registration order decides, no file records it". The list filters by type and by **related app**, and only rescans when you ask. |
| **System hotkey conflicts** | Spotlight, Mission Control, and other enabled system shortcuts are read through Carbon and compared with the app's menu shortcuts. Matching chords are marked ⚠︎, and the conflict list names the system source. Because a system shortcut sits below a menu item, the verdict is not "maybe" but **the menu item never fires**. Menu items in the panel's system section are named from a built-in table (⌘Space → Spotlight, ⌥⌘⎋ → Force Quit); a chord the table cannot name uses the chord itself as the row's title, with the shortcut column left empty, rather than repeating the chord twice. |
| **Third-party config sources** | Karabiner-Elements, skhd, Keyboard Maestro, BetterTouchTool, Hammerspoon and Alfred keep their shortcuts in a file rather than a menu, and all of them hook the keyboard *below* an app's menu. Kaname parses those files (read-only) so a conflict list can say "⌘⇧4 will never reach Safari" instead of just "two things want ⌘⇧4". Scanning is on by default, with the list of what was read at the top of **Settings → Conflicts**. Showing those rows in the panel and search is a separate switch there, **off by default** — it is a display choice, not a scan permission. |
| **Combo lookup** | Type a combination into search — `cmd shift 4`, `⌘⇧4`, `opt cmd t` — and Kaname answers who owns it, or that it is free, instead of returning an empty list that reads as "not scanned". |
| **Live shortcut test** | **Test this combo** on any conflict row watches one real keypress: two listen-only event taps detect whether another app swallowed the key, and above that layer the verdict falls back to what came to the front. Each result is tagged **confirmed / informative / inconclusive**, so a guess is never presented as a fact. While it listens, every panel behaviour is suspended, so Kaname can never be the thing that ate the key. |
| **Disabled items** | Menu items that the app reports as disabled (`AXEnabled == false`) are greyed out, end with a `lock.slash`, and can optionally be hidden. Their context menu opens with **This menu item is unavailable right now** instead of pretending an action can run; clicking one shows the same sentence in a HUD at most once per menu item per three seconds. |
| **Usage sorting** | The statistics page is one flat list with the shortcut first; the owning app and the command description are the row's note, so the same chord used by two apps is two rows. **Sort by** offers **Shortcut** (the default, in the panel's keyboard order), **App**, or **Command**, and the choice persists. The panel follows its own **Panel order** setting, and the palette always follows match order; neither follows this setting. |
| **Usage statistics** | Counts and last-used times per `app|shortcut`, with system and built-in menu items shown as *System / built-in*. Stored in `~/Library/Application Support/Kaname/usage.json`, capped at 800 entries, resettable. No raw key events or text. |
| **Search** | A global search palette (default ⌃⌥⌘F), also reachable by pressing `/` in the panel. Results arrive in cards by menu, with a banner when the query spells out a combination. Space-separated terms in any order, `+` as a separator, modifier aliases (com/cmd/cm/⌘, op/alt/⌥, …), full pinyin and pinyin initials for Chinese titles, and word initials for English titles; all terms must match. Return closes the palette and **triggers** the selected menu item in the app you scoped to — pressing the menu item when there is one, replaying the chord otherwise. The palette has no copy action; the panel does. |
| **Multi-app scope** | The palette's app menu lists the frontmost app and every running regular app, and its header shows the scoped app's icon and name, so the list always says whose shortcuts these are. Choosing another app re-scans and re-ranks for it, and running a menu item activates that app first. The panel still follows the real frontmost app. |
| **Export Markdown** | The palette's export button saves the current matches (or the scoped app's whole sheet when the field is empty) through a save panel: grouped by menu, `Shortcut` / `Action` columns, unavailable items marked. |
| **Excluded apps and ignored menu items** | An app can be excluded from scanning altogether (a list you fill from a file picker, not a text field of bundle identifiers), and a menu item title can be ignored either globally or for one app — so "Reload Page" in Safari can be hidden without hiding Xcode's. |
| **Panel placement** | Cover the front window (default), a fixed width/height, the whole visible screen, or beside the front window (the older behavior, which also avoids the focused control). |
| **Appearance and accessibility** | The panel follows the system appearance, with Light and Dark overrides. A light panel is a `.popover`-style paper surface and a dark one a `.hudWindow` glass surface, with a 12 pt corner radius and a 16 pt outer margin; Reduce Transparency keeps the solid colour, and Increase Contrast strengthens borders and text. |
| **English and 简体中文** | The interface follows the system language and can be overridden in Settings. |
| **Permission onboarding** | Accessibility is required (menu reading and the global key tap). Input Monitoring is offered as a fallback when a system does not deliver key events with Accessibility alone. **Request** opens the matching System Settings pane — Accessibility does not raise a system prompt, because a prompt would pre-register the app without enabling it; Input Monitoring raises the prompt and opens its pane. A draggable Kaname icon can be dropped into the permission list. Each grant is detected and explained separately; the panel hides while secure input is active. |
| **Hyper-key ready** | Hotkeys with three or more modifiers also match when the event carries extra modifiers, so a Karabiner-style Hyper (⌃⌥⇧⌘) triggers a recorded ⌃⌥⌘ hotkey. Hotkeys with fewer than three modifiers stay strict. |
| **A Karabiner rule can stand down** | Karabiner rewrites the keyboard *below* Kaname's event tap, so a rule bound to the same key (a `left_command` with `to_if_alone`, say) keeps firing while the panel is open, and the panel only sees the rule's output — ⌘ stops narrowing. **Settings → Trigger → Tell Karabiner when the panel is open** writes Karabiner's `kaname_panel` variable: 1 while the panel is shown, 0 when it closes, and 0 at launch and quit so a crash cannot leave it stuck. Add `conditions: [{"type": "variable_unless", "name": "kaname_panel", "value": 1}]` to that rule and it applies only while the panel is closed. On by default, and nothing is written when Karabiner is not installed. |
| **Panel/search switch** | One hotkey (default ⌃⌥⌘S, recorded in Settings) moves between the two surfaces: search visible → panel, panel visible → search, neither → panel. Only one is ever on screen. |
| **Seven settings tabs** | General, Trigger, Appearance, Statistics, Conflicts, Permissions, and About. General ends with a collapsed **Diagnostics** group: logging on or off, a verbose mode, the log folder, and both exports — **Export diagnostics archive…** (a zip of the logs) and **Export diagnostics report…** (a JSON report); About shows the icon, version and commit, system version, the manual update check, the data folder, the repository and license. |
| **Private by design** | All shortcut processing is local; settings and statistics are plain JSON files in Application Support, and the only network request is the update check you trigger yourself. No account, no telemetry, no keystroke log. Running a menu item presses it through Accessibility; the one chord is injected only when that press is not available. |

## Install

### Requirements

- macOS 14.0 Sonoma or later.
- Apple Silicon (arm64). The release DMG is a universal binary (x86_64 + arm64), but Intel is not a supported or tested configuration: the cask deliberately rejects Intel Macs at install time rather than letting an untested app install and fail later.
- Accessibility permission (required). Input Monitoring is an optional fallback if key events are not delivered on your system. Both are explained on first launch.
- The app is a menu bar agent: no Dock icon, and no window when it launches — the menu bar icon is the way in (Settings → General → **Show a Dock icon as well** adds one back).

### Download a release

1. Download the latest DMG from [Releases](https://github.com/suliveevil/kaname/releases/latest) and verify it against the published `.sha256` file (`shasum -a 256 Kaname-*.dmg`).
2. Open the DMG and drag **Kaname** into **Applications** — launch it from there, not from inside the DMG.
3. Launch Kaname and grant Accessibility as described below. Add Input Monitoring only if the panel does not appear.

Notarized builds open normally. A build that is not notarized is blocked on first launch with an "unverified developer" notice — the app is still fully signed, only Apple's check is missing. After the block dialog, use either:

- **No Terminal:** open **System Settings → Privacy & Security**, scroll down to the Kaname notice, and click **Open Anyway** (the right-click → Open shortcut does not exist on macOS 15), or
- **Terminal:** `xattr -dr com.apple.quarantine /Applications/Kaname.app`

> **Upgrading or replacing an existing copy?** macOS ties privacy grants to the app's code signature. If you replace Kaname with a build signed differently — a local or ad-hoc rebuild, or an install over a release signed by another identity — the old Accessibility grant is no longer valid: open **System Settings → Privacy & Security → Accessibility**, remove the stale Kaname entry if present, and enable the new app again. Without this step no panel will appear. A normal signed update keeps the bundle identifier and its grant.

### Homebrew

```bash
brew tap suliveevil/tap
brew install --cask kaname
```

The cask lives in the public `suliveevil/homebrew-tap` repository and points at the DMG attached to the matching GitHub release. [`Distribution/kaname.rb`](Distribution/kaname.rb) is the template that `scripts/publish_release.sh` renders after the release upload; it is not installable until the DMG and its `.sha256` exist.

- **Not notarized.** Homebrew quarantines downloads by default, so the first launch is blocked by Gatekeeper. Approve Kaname once under **System Settings → Privacy & Security → Open Anyway**, or strip the attribute from the installed copy with `xattr -dr com.apple.quarantine /Applications/Kaname.app`. Homebrew 7 removed `--no-quarantine`, and every `brew upgrade` downloads a fresh copy that is quarantined again.
- **Upgrade:** `brew upgrade --cask kaname`. Quit Kaname first — it is a menu bar agent, and a running copy keeps the old binary and event tap alive.
- **Uninstall:** `brew uninstall --cask kaname` removes the app. `brew uninstall --cask --zap kaname` also deletes `~/Library/Application Support/Kaname` (settings, statistics, logs and local backups), the preferences plist, caches and saved state. Neither form removes the Accessibility grant — reset it with `tccutil reset Accessibility com.suliveevil.kaname` — and a login item may have to be removed in **System Settings → General → Login Items**.

### Build from source

```bash
git clone https://github.com/suliveevil/kaname.git
cd Kaname
open Kaname.xcodeproj
```

Select the **Kaname** scheme and run. Xcode handles signing for local development. To build and package a DMG without opening Xcode:

```bash
./scripts/build_release.sh
# produces build/Kaname-<version>.dmg
```

To build and replace `/Applications/Kaname.app` in one step:

```bash
./scripts/install.sh
```

The release script signs with a Developer ID Application identity when one is available and attempts notarization; otherwise it falls back to ad-hoc signing. Ad-hoc builds work locally but are not notarized, and macOS may require you to re-grant permissions after replacing the app.

## First run

1. Launch Kaname. Nothing opens on screen — the app appears in the menu bar. If Accessibility is missing, the menu bar menu carries a **Permission guide** item instead. **Settings → Permissions** lists both grants and their current status.
2. Open **Settings → Permissions** and click **Request** next to Accessibility. Kaname opens the matching **System Settings → Privacy & Security → Accessibility** pane; enable Kaname there. Accessibility does not raise a system prompt of its own: a prompt would register the app without enabling it, so the app is added by dragging the Kaname icon from the Permissions tab into the list, or with **+**.
3. Try holding ⌘. The first launch shows one HUD — **Hold ⌘ or double-tap it to open the panel** — and never repeats. If the panel appears, nothing else is needed.
4. If no panel appears, quit Kaname, click **Request** next to **Input Monitoring** (it raises the system prompt and opens that pane too), enable Kaname, and reopen the app. This is the fallback for systems that do not deliver key events with Accessibility alone.
5. Check **Settings → Permissions** to confirm the current state.

The full walkthrough, including reset commands and signature-related re-granting, is in [docs/en/PERMISSIONS.md](docs/en/PERMISSIONS.md).

## Usage

### Trigger

| Trigger | How |
| --- | --- |
| Hold the trigger key | Hold the trigger key without pressing another key for 0.5 s (0.3–0.9 s in 0.1 s steps) | Default gesture. The trigger key is one of **Any modifier**, **Left Control**, **Left Option**, **Left Command**, **Right Command** (default), or **Right Option**; combinations are not supported. The summoning press is not a filter token, so the panel opens on the whole list; a modifier pressed while it is open narrows. Shift alone is ignored. |
| Press the trigger key twice | Two complete presses inside 0.3 s (0.15–0.8 s) | Alternative gesture. Any key press between the two presses cancels it. |
| Panel hotkey | ⌃⌥⌘K by default | One of the three global hotkeys. The panel stays open until Esc, the hotkey again, or the app behind it losing focus. Switching the frontmost app (or the desktop), a full-screen app or Mission Control closes it; summon it once to get a fresh panel for the new app. |
| Search | ⌃⌥⌘F by default | Opens the search panel independently. The hotkey is configurable. |
| Switch panel/search | ⌃⌥⌘S by default | Search visible → panel; panel visible → search; neither → panel. Only one is ever on screen. Recordable in Settings. |
| Two independent switches | Settings → Trigger | The modifier gesture and the three hotkeys each have their own switch at the left of the card header. They can both be live, only one can, or both can be off — both off means no trigger fires, while the menu bar and settings keep working. |
| A Karabiner rule yields to the panel | Settings → Trigger, plus one condition in your own Karabiner rule | On by default. While the panel is shown Kaname sets Karabiner's `kaname_panel` variable to 1 and clears it to 0 when the panel closes, at launch and at quit. A rule carrying `conditions: [{"type": "variable_unless", "name": "kaname_panel", "value": 1}]` applies only while the panel is closed, so the key reaches the panel as a modifier. Without that condition the rule behaves exactly as before; nothing is written when Karabiner is not installed. |

### The panel

- **One level at a time.** With no filter and an empty prefix every menu item is a complete combination (for example ⌘C). A modifier pressed while the panel is open joins the ordered filter, so the list narrows as more tokens arrive; a chord prefix shows each menu item's next key.
- **The panel is persistent within one app.** It stays on screen while the app it was opened over keeps focus — no idle timer, no auto-hide delay — and closes when that app loses focus (a desktop switch, a full-screen app, Mission Control), or when you press Esc or the panel/switch hotkey again. Releasing the modifiers leaves the filter in place rather than widening the list. The next trigger press after a focus change opens a fresh panel in one gesture.
- **Filter with modifiers and letters.** A modifier pressed while the panel is open is added to an ordered filter; hold ⌃ and press a letter to make the query `⌃ f`. ⌫ takes back the last token — the letter if it came last, otherwise that modifier — and once the queue is empty the key goes back to chord backtracking. Pressing the same modifier again removes it wherever it sits in the queue; a third press adds it back at the tail. Releasing the keys does not clear anything, and Esc closes the panel; the next open starts from an empty filter.
- **Fullscreen spaces stay usable.** On a full-screen space or with the menu bar hidden, the panel stays fully on screen and clear of the top safe area (the menu bar or the notch). Switching Space closes the panel and refreshes the front app's menu once, so a new summon never shows a stale list.
- **Selection and highlight are different things.** Highlight follows your fingers (the menu items the current prefix can reach); selection is your cursor, moved with ↑/↓ or the pointer. The selected menu item carries a 3 pt accent bar on its leading edge and a slightly brighter title, so it is visible on the light palette and to VoiceOver (which announces it as selected). Neither state moves the row text.
- **The shortcut still reaches the app.** Kaname only observes keys; it does not remap them. Completing a shortcut closes the panel and lets the same key event continue to the front app, so the menu item runs immediately, exactly as if the panel had not been open.
- **Chords stay open.** If a stroke is the first step of a multi-stroke shortcut, the panel descends one level and shows what can follow; a breadcrumb shows the prefix. ⌫ takes back the filter's last token first, then goes back one stroke, and only while no other modifier is held, so ⌘⌫ stays an ordinary shortcut. Esc closes the panel whatever the modifiers are — ⌥⌘Esc included, which therefore never reaches the front app — and the next open starts from an empty filter.
- **Keyboard and mouse.** ↑/↓ select, ←/→ always page, the run key acts on the selection, Esc closes. Any punctuation pairs ticked under **Settings → General → Menu item actions** page too; the default pair is `;` / `'`, and `,` / `.`, `[` / `]`, `-` / `=` can be added. The keys are judged by the character they type, and `+` (Shift+=) is never a paging key, so it stays available to the Shift-hint layer's `0–9` / `a–z` labels and never conflicts. With no modifier held these keys are consumed by the panel and never reach the front app; clicking a menu item does the same as the run key.
- **`/` opens the search palette.** The panel has no text field of its own: `/` swaps it for the search palette with the cursor already in the field, and every open starts with an empty query, so nothing from last time is carried over. Press `/` again while the field is empty to go back to the panel (there is nothing to lose); once you have typed a query, `/` is an ordinary character and the back chevron in the title bar takes you back. ⌘/ is never taken; it belongs to the front app.
- **Run or copy.** The run key (Space by default) closes the panel and triggers that menu item in the front app: it presses the menu item itself when the scan kept one — which is also the only way to run a menu item that has no shortcut at all — and replays the chord into the app as a fallback. The copy key (Return by default) writes the chord to the clipboard and leaves the panel open (a menu item with no shortcut copies its menu path instead). Both are **recorded** under **Settings → General → Menu item actions**; the footer always spells out the two keys you actually chose. A menu item with further steps descends a level instead of running, and a disabled menu item is ignored.
- **Shift reveals targets.** While Shift is held, the first 36 menu items show `0–9` / `a–z` labels; Shift plus that character runs that menu item directly. The label layer exists only in the panel — inside search, Shift still belongs to the text field.
- **Completing a shortcut.** The menu item is highlighted for about 0.4 s, the panel closes, and the shortcut runs in the app. A key with no match leaves the panel open instead of closing it.
- **Three sections, and paging.** The app's menu items come first, ordered by the shortcut (shorter chords first, then ⌘ → ⌥ → ⌃ → ⇧, then the key) or, when **Panel order** is set to **By menu group**, by top-level menu; the system's hotkeys follow under **System hotkeys**, and config tools come last as one card per tool — hidden by default, and when shown folded independently with their row counts still visible; a filter in force opens every card. The menu a menu item lives in is the middle column, not a heading. Long lists show `1/3` with clickable ‹ ›.
- **Empty panels say why.** An empty list is one of four states with a fixed priority: missing Accessibility permission (with a **Permission guide** button), still scanning (with a spinner), favourites-only with nothing pinned, or no match for the current filters. The permission case wins over scanning, because no scan can finish without it.
- **When nothing can be shown, the reason is stated.** A menu item the app reports as disabled ends with a `lock.slash`; right-clicking it shows **This menu item is unavailable right now**, and clicking it says the same thing in a HUD once per menu item per three seconds, so repeated clicks cannot stack identical notices.
- **Changing Panel order announces itself.** Switching between **By modifier** and **By menu group** while the panel is visible shows one HUD line with the new order; the panel itself carries no permanent mode label. The new order is also applied immediately.
- **Conflicts and disabled items.** Conflicting menu items carry ⚠︎. Disabled menu items are greyed out unless you choose to hide them.
- **Long descriptions** are truncated with an ellipsis according to the display setting.

### Search

Press ⌃⌥⌘F, or press `/` while the panel is open. Search covers the scoped app's menu shortcuts and the built-in catalog; with no scope chosen it also covers the system hotkeys and the config-tool rows. The palette's app menu switches scope.

- **Terms are unordered and all must match.** `com op x`, `op cm x`, and `cmd+opt+x` all find ⌘⌥X; `+` is just another separator.
- **Modifier aliases** are understood: `com`/`cmd`/`command`/`cm`/`⌘`, `op`/`opt`/`option`/`alt`/`⌥`, `ct`/`ctl`/`ctrl`/`control`/`⌃`, `sh`/`sft`/`shift`/`⇧`.
- **Chinese titles match pinyin:** full pinyin (`jian qie`), spaced syllables, and initials (`jq` for 剪切). **English titles match word initials:** `fs` finds Find Similar. Better matches rank first, regardless of the order you type the terms in.
- ↑/↓ moves the selection.
- **Return runs the selected menu item.** The palette closes, the app you scoped the search to is activated, and the menu item is triggered there: it is pressed in the menu when the scan kept one, otherwise that one chord is replayed into the app.
- **The palette has no copy action.** To copy a chord without running it, use the copy key in the panel (Return by default); Space runs.
- **Panel and search are mutually exclusive.** Opening one closes the other. The switch hotkey (⌃⌥⌘S by default) moves from search to panel, from panel to search, or opens the panel when neither is visible.
- Search queries are not recorded.

### Menu bar and settings

Kaname is an `LSUIElement` agent: no Dock icon, and no window at launch. The menu bar icon is the whole interface — **Search Shortcuts…**, **Shortcut Panel**, **Settings…**, and **Quit Kaname**. Those four are the whole menu; the **Permission guide** only appears while Accessibility is still missing and disappears once it is granted. There is no pause item: turning both trigger switches off in Settings is the pause. Its own menu bar (the app menu inside its windows) carries ⌘, for Settings and ⇧⌘F for the search palette.

Settings is one utility window: it can be closed and resized but not minimised, and reopening it always brings the same window forward. When Settings is visible, **Permission guide** appears as a sheet attached to it, so the guide cannot hide behind the window or in another Space; before Settings has ever been opened, the guide stands alone.

Settings has seven tabs:

| Tab | What it covers |
| --- | --- |
| General | Interface language, launch at login, executed HUD, **Show a Dock icon as well**, **menu item actions** (the two recorded action keys), **excluded apps** (added from a file picker, removed from the list), **ignored menu items** (one collapsible group per scope: global rules, then one per app, plus the built-in catalog and **Include the Apple menu in scans** switches), and a collapsed **Diagnostics** group (logging on/off, verbose logging, the log folder, **Export diagnostics archive…**, **Export diagnostics report…**). |
| Trigger | Two independent switches, each at the left of its card header: **Modifier gesture** (hold still / press twice, the trigger key, and the matching delay) and **Global hotkeys** (the panel, search, and switch hotkeys). Both can be live, only one can, or both can be off — both off is the pause state. |
| Appearance | Key style, panel theme, key position, **panel order** (by modifier, or by menu group), columns, **max menu items per group** and description length (typed; Return or leaving the field commits, an out-of-range entry keeps the previous value), disabled items, **panel placement** (cover the front window, fixed size with width and height, fill the screen, or beside the front window), and a **Favorites** card for pinning and filter behaviour. |
| Statistics | **Sort by** (shortcut, app, or command description), one flat list of shortcuts with the owning app and description as a note, **Show data folder**, **Reset statistics**, and **Restore all settings…**. |
| Conflicts | Third-party **config file sources** first (which files were read, how many bindings each contributed, a rescan), then the conflict list with a **type** filter, a **related app** filter, the scan timestamp, a manual rescan, and a **Test this combo** action on each row. |
| Permissions | Accessibility and Input Monitoring status, **Request** (opens the matching System Settings pane; Input Monitoring also raises the system prompt), and the draggable Kaname icon. |
| About | Icon, version and commit, system version, **Check for updates**, data folder, repository and license. |

The search palette is the surface you get from the search hotkey or by pressing `/` in the panel. Its header names the app it is answering for and offers an app menu with the frontmost app and every running regular app, so any of them can be searched; **Export Markdown** writes what you are looking at to a file. Its list is live: hover to select, click or press Return to run the menu item in that app, Esc to close. The update check is manual: it compares the latest GitHub release and never downloads or installs anything.

## Configuration

| Setting | Values | Default |
| --- | --- | --- |
| Modifier gesture | On / Off (its own checkbox) | On |
| Trigger gesture | Hold still / Press twice | Hold still |
| Trigger key | Any modifier / Left Control / Left Option / Left Command / Right Command / Right Option | Right Command |
| Hold delay | 0.3–0.9 s, 0.1 s steps | 0.5 s |
| Double-tap detection | Follows the system double-click speed, clamped to 0.25–0.6 s | Automatic |
| Global hotkeys | On / Off (their own checkbox) | On |
| Panel hotkey | Any key combination | ⌃⌥⌘K |
| Search hotkey | Any key combination | ⌃⌥⌘F |
| Switch panel/search hotkey | Any key combination | ⌃⌥⌘S |
| Panel placement | Cover the front window / Fixed size / Fill the screen / Beside the front window | Cover the front window |
| Fixed panel width | 320–4000 pt | 720 |
| Fixed panel height | 240–3000 pt | 620 |
| Show a “shortcut triggered” confirmation | On / Off | On |
| Sort by (statistics) | Shortcut / App / Command description | Shortcut |
| Built-in catalog when menus are unavailable | On / Off | On |
| Include the Apple menu in scans | On / Off | Off |
| Show a Dock icon as well | On / Off | Off |
| Show unavailable menu items | On / Off | On (greyed out) |
| Key style | Symbols / Words | Symbols |
| Columns | 1–3 | 2 |
| Max rows per page (upper bound; the panel fits fewer when the window is short) | 6–60 | 24 |
| Max description length | 8–80 characters | 30 |
| Language | System / English / 简体中文 | System |
| Run a menu item | Any recorded key | Space |
| Copy a menu item | Any recorded key | Return |
| Key position | Left / Right | Right |
| Panel theme | System / Light / Dark | System |
| Pin favourites to the top | On / Off | On |
| Filters can hide favourites | On / Off | Off |
| Ignored menu items | A title, global or bound to one app | None |
| Launch at login | On / Off | Off |
| Excluded apps | Bundle identifiers, chosen from a file picker | None |
| Scan config files (Conflicts tab) | On / Off | On |
| Diagnostics logging | On / Off | On |
| Verbose diagnostics | On / Off | Off |
| Usage statistics | Per-shortcut counts with the owning app and command, 800-entry cap | Stored in Application Support |

## Privacy

- **Shortcut handling is local.** Kaname has no accounts, no analytics, and no telemetry, and no data about you, your apps, or your shortcuts is sent anywhere. The single exception is the update check you trigger yourself: it fetches the public GitHub release document once and uploads nothing. The source is available under the GPL-2.0.
- **Accessibility is used for menus and the key tap.** Kaname reads menu titles, key equivalents, and enabled state from the frontmost app, and uses a global key tap to see modifier and key state. It does not read documents, text fields, or window contents.
- **Scans stay short-lived, and never leave the machine.** Menu data is cached in memory per app for 20 seconds, and on disk — per app, for up to 10 minutes, in `~/Library/Application Support/Kaname/menu-cache/` — so re-opening the panel for the same app, or relaunching Kaname, skips the AX walk. The disk copy records only what a scan already read (menu titles, paths, key equivalents, enabled state); it is dropped when a scan-shaping setting changes, when it turns 10 minutes old, or when you press "Restore all settings…". There is no live menu observer, and nothing is uploaded.
- **Two files hold user data; the rest is derived.** Settings and statistics are `settings.json` and `usage.json` in `~/Library/Application Support/Kaname/`, written atomically. A file that cannot be decoded is renamed `*.corrupt-<timestamp>.json` and kept rather than silently discarded. Next to them sit `conflicts-cache.json` (the last cross-app conflict scan, so opening the page does not rescan every app), `menu-cache/` (menu scans, valid for 10 minutes) and `logs/` + `crash/` (the diagnostic log, the last 30 action names, the crash reports) — all reproducible, all safe to delete, and the log can be switched off in **Settings → General → Diagnostics**.
- **Keys are observed, not recorded.** The global key tap computes the current modifier/key state and detects the recorded hotkeys and the panel's own navigation keys. It passes events through to the front app except those keys, which it consumes so the app does not also receive them. Kaname never stores a stream of key presses or typed text.
- **One chord is injected, and only when pressing cannot be used.** When you press the run key, click a row, or press Return in the search palette, Kaname triggers that menu item by pressing it through Accessibility; the row's chord is posted once (`CGEvent`, HID event tap) only when there is no menu item to press or the press is refused. It does not replay what you type, it does not inject anything while you are just browsing the panel, and the copy key never injects at all. This is the one place where the app synthesises input, and it exists so a menu item can be run without reaching for the menu.
- **Statistics are minimal.** Kaname stores a use count and last-used timestamp per `bundleID|chord` (one row per app and shortcut), capped at 800 entries and resettable in Settings. No raw key events or queries are stored.
- **Secure input wins.** When macOS reports secure input (password fields, login windows), the panel hides.
- **Config files are opened read-only, and only for the scan.** When third-party scanning is on, Kaname reads `karabiner.json`, `skhdrc`, Keyboard Maestro's macro library, BetterTouchTool's data store, `init.lua` and Alfred workflow `info.plist` under your home directory to find their shortcuts. It opens them read-only (BetterTouchTool's database with SQLite's read-only flag), never writes, never uploads, and keeps only chord, title and owning tool in memory — no file is copied out and nothing from those files is written to disk. Turning the setting off forgets everything found and opens no such file again. |
- **No telemetry or upload.** No shortcut, app, or usage data is ever sent; the update check only reads a public release document.

See [docs/en/PRIVACY.md](docs/en/PRIVACY.md) for the complete list of what is read, written, sent and injected, [docs/en/PERMISSIONS.md](docs/en/PERMISSIONS.md) for the grants, and [docs/en/ARCHITECTURE.md](docs/en/ARCHITECTURE.md) for the implementation.

## Compared with vim-which-key and emacs which-key

Kaname borrows the interaction model, not the implementation.

| | Kaname | vim-which-key | emacs which-key |
| --- | --- | --- | --- |
| Scope | Any macOS app with a menu bar | Neovim keymaps | Emacs keymaps |
| Data source | Live Accessibility menu scan plus a built-in fallback | Lua configuration | Active keymaps |
| Invocation | Modifier gesture (hold or double-tap), three global hotkeys, or the panel/search switch hotkey | Leader key | Prefix key timeout |
| Navigation | Persistent panel, complete shortcuts, progressive highlight, chord breadcrumb, ⌫ back, Esc close | Prefix menus | Prefix menus |
| Display | Floating panel: over the focused window, beside it, or filling the screen | Popup window | Minibuffer or child frame |
| Ranking | Key or menu-group order in the panel; Shortcut / App / Command order for the statistics page | Configured order | Configured order |
| Configuration | Settings UI, no config file | Lua tables | Emacs variables |
| Platform | macOS 14+ | Neovim | Emacs |

Unlike the editor plugins, Kaname cannot define or remap shortcuts. It reflects what the app already exposes, which is why it works immediately across applications and why it cannot invent a shortcut that is not in a menu.

The editor plugins only display the next keys; Kaname also runs the menu item for you — by pressing the menu item, so one with no shortcut is reachable too.

## Architecture

At a high level:

```
frontmost app → Accessibility menu scan → ShortcutEngine (20 s memory cache,
                                              ├─→ PanelSections  → panel card 1: the app's menu items
                                              │                    (PanelSortOrder: chord / menu-group order)
                                              ├─→ SearchCorpus   → search palette (app scope,
                                              │                    grouped into cards by menu)
                                              └─→ ConflictDetector → Settings → Conflicts
global keys   → key tap → HotkeyMatcher ──────┤
                                              ├─→ UsageStore → Application Support/usage.json
                                              └─→ PanelPlacement → cover / fixed / fill / beside
system hotkeys → Carbon CopySymbolicHotKeys ──┤
                                              ├─→ SystemHotkeyNames → panel card 2 + conflicts
                                              └─→ MenuScanCache    → menu-cache/ (10 min)
```

The shortcut engine, chord resolution and ordering, formatting, description cleanup, conflict detection and caching policy, search corpus (tokenizer and pinyin), hotkey matching, panel placement, usage statistics, Markdown export, and semantic versions live in a pure SwiftPM target (`KanameCore`) with XCTest coverage. AppKit, Accessibility, and SwiftUI code sit above it: `SystemHotkeyReader` (Carbon system shortcuts, plus the `SystemHotkeyNames` table that gives them names), `AppDirectory` (running-app list for the search scope and the conflict scan), `ConflictCache` (the cross-app scan kept between launches), `MenuScanCache` (menu scans on disk), and `UpdateChecker` (the manual update check). The full component map, threading model, cache invalidation, and known limitations are in [docs/en/ARCHITECTURE.md](docs/en/ARCHITECTURE.md).

## Development

Run the pure-logic tests:

```bash
swift test
```

If `swift test` fails because `xcode-select` points at the Command Line Tools, prefix it with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or select Xcode with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

Build the app the same way CI does:

```bash
xcodebuild \
  -project Kaname.xcodeproj \
  -scheme Kaname \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

CI runs the same job twice, on `macos-15` and `macos-26`: checkout, a Debug build and a Release build with signing disabled, then `swift test`, a DMG packaging check on the older runner, and a coverage report for the pure target. Coverage is a gate, not a warning: a run whose `Core/Pure` line coverage is below 70% fails. It runs on every branch push and on pull requests. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

If `sandbox-exec` is unavailable in your environment (the build system wraps every compile in it, and nested sandboxing can be denied), both `xcodebuild` and `swift test` fail with `sandbox_apply: Operation not permitted`. Workarounds: `swift test --disable-sandbox`, and `./scripts/build_swiftc.sh Release`, which compiles the same sources with `swiftc` and loads the SwiftUI macros explicitly. `scripts/install.sh` falls back to it automatically when `xcodebuild` cannot build.

Release:

```bash
./scripts/build_release.sh   # build/Kaname-<version>.dmg
```

Contributor setup, layering rules, the "a setting change touches six places" checklist, and the test policy are in [docs/en/CONTRIBUTING.md](docs/en/CONTRIBUTING.md); the release steps are in [docs/en/RELEASING.md](docs/en/RELEASING.md). What shipped, and what to check when upgrading, is in [docs/en/RELEASES.md](docs/en/RELEASES.md). When something does not work, start with [docs/en/TROUBLESHOOTING.md](docs/en/TROUBLESHOOTING.md).

For the git workflow with parallel agents — one worktree and one branch per agent, a single integrator on `main` — [AGENTS.md](AGENTS.md) is the rule; [docs/en/CONTRIBUTING.md](docs/en/CONTRIBUTING.md) explains the reasoning.

The Homebrew cask template is [`Distribution/kaname.rb`](Distribution/kaname.rb). It must be copied into a tap before `brew install --cask kaname` works.

`build_release.sh` also accepts `KANAME_SIGN_IDENTITY` (choose a signing identity), `KANAME_NOTARY_PROFILE` (a `notarytool` keychain profile to notarize with), and `KANAME_SKIP_DMG=1` (build the app only).

## FAQ

**Nothing happens when I hold a modifier.**
Check the trigger mode, whether Accessibility is granted, and whether you are in a secure input field. If the panel still does not appear, grant Input Monitoring and relaunch. If the app has no menu bar, enable the built-in catalog. Full checklist in [docs/en/FAQ.md](docs/en/FAQ.md#nothing-happens-when-i-hold-a-modifier).

**Why does app X show no shortcuts?**
Kaname can only show shortcuts the app exposes in its menu bar. Shortcuts implemented in custom views, web content, or games are invisible; menu items without key equivalents are not guessed. See [docs/en/FAQ.md](docs/en/FAQ.md#why-does-app-x-show-no-shortcuts).

**Does it upload anything or record what I type?**
No. Shortcut handling is local, the key tap only passes events through (except Kaname's own hotkeys and the panel's navigation keys; a completed shortcut still reaches the app), and statistics contain only counts and timestamps grouped by app. Settings and statistics are two JSON files in Application Support. The one thing it does synthesise is a single chord, and only as a fallback: pressing the run key or clicking a menu item presses the menu item through Accessibility, and that menu item's shortcut is posted into the front app once only when the press is not available. The only network request is the update check you press yourself. See [Privacy](#privacy).

**When does the panel close by itself?**
When the app it was opened over loses focus: switching desktops, moving to a full-screen app, Mission Control, or activating another app. The auto-hide delay is still gone and there is no idle timer — focus, not elapsed time, ends a session — and within one app the panel stays persistent until you press Esc or toggle it off with the panel/switch hotkey. Switching apps or desktops also refreshes the menu scan once. Releasing modifiers does not clear the filter; it stays until you take it back, and the next open after a close starts from an empty filter. If a focus notification was missed, the next trigger press opens a fresh panel in that same gesture instead of toggling a stale one off.

**Where is my data, and will reinstalling lose it?**
In `~/Library/Application Support/Kaname/` as `settings.json` and `usage.json`. They are independent of the app bundle and the preference domain, so reinstalling or updating keeps them; only deleting the folder removes them. See [Privacy](#privacy) and [docs/en/FAQ.md](docs/en/FAQ.md).

**Can I use a Hyper key?**
Yes. Record a three-modifier hotkey in **Settings → Trigger**; a Karabiner-style Hyper (⌃⌥⇧⌘) event carries a superset of modifiers and still matches. Hotkeys with fewer than three modifiers are matched strictly.

**Why isn't it on the Mac App Store?**
Reading another app's menu bar and observing global keys are not possible inside the App Sandbox. Kaname ships outside the store with the sandbox disabled.

**What does ⚠︎ mean?**
Another binding — an app menu item, an enabled macOS system shortcut, or a third-party tool's config — uses the same key combination. macOS decides which one wins; Kaname only reports the conflict, names its type and the layer. Details are in **Settings → Conflicts**.

**Do I need to grant permissions again after updating?**
The upgrade that changed the bundle identifier **always** required re-granting Accessibility. Builds since then keep the same identifier, so a signed update normally keeps its grant; ad-hoc local builds may still be treated as new after every rebuild. See [docs/en/FAQ.md](docs/en/FAQ.md#do-i-need-to-grant-permissions-again-after-an-update).

## License

GPL-2.0. See [LICENSE](LICENSE).

## Credits

Kaname is built on the ideas and code of [KagiPeek](https://github.com/Voltline/KagiPeek), refactored into an independent project and maintained by [suliveevil](https://github.com/suliveevil). The shortcut engine was rewritten, then made actionable, and the panel became persistent; the interaction model is inspired by [vim-which-key](https://github.com/folke/which-key.nvim) and [emacs which-key](https://github.com/justbur/emacs-which-key).

The conflict-checking work — naming the type of a clash, the event-stack layer model, third-party config scanning, the combo lookup and the live keypress test — takes its ideas from [HotkeyClash](https://github.com/Wunderlandmedia/HotkeyClash) by Wunderlandmedia, also GPL-2.0. The layer ranking and the head/tail event-tap technique are theirs; the code here is written for Kaname's own models.

Five ideas come from [Menu-Bar-Search](https://github.com/BenziAhamed/Menu-Bar-Search): addressing a menu item by its position in the menu tree (`pathIndices` → `axPath`), weighting search hits by how close a matched menu level is to the menu item itself, caching scans on disk behind a control file that records the settings they were written under, resolving the app that owns the menu bar rather than merely the frontmost one, and reporting *why* a scan came back empty instead of showing an empty list. The `showAppleMenu` setting is its toggle, defaults off.
---

## 中文

中文文档：[README.zh-CN.md](README.zh-CN.md)
