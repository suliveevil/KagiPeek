# Release notes

Kaname reads the frontmost app's menu bar through Accessibility and shows its shortcuts in a
floating panel, which can also run them. These notes record what the app does, what changed
along the way, and what to do about it when upgrading.

## Highlights

- **Live menu scanning** — any app with a standard menu bar works, including menu grouping, key
  equivalents and enabled state. A ~100 entry built-in catalog is used as a fallback.
- **Which-key narrowing** — long-pressing ⌃/⌥/⌘ seeds the prefix with those modifiers, so holding
  ⌘ shows the ⌘ set with next-key rows (C, ⇧S, …). The hotkey (⌃⌥⌘K) and double-tap ⌘ summon it
  with an empty prefix, where every row is a complete combination. Modifier changes while the
  panel is open narrow or widen it live, and releasing everything widens it back — the panel
  stays open either way. Holding ⇧ alone does not narrow, so the list is never empty.
- **Chords** — multi-stroke shortcuts such as ⌘K ⌘C descend one level at a time. ⌫ goes back,
  Esc closes, a breadcrumb shows where you are.
- **The panel waits for you** — the trigger keys are not a prefix: the panel stays until you
  finish a shortcut — which is highlighted, then passed through to the app — or press Esc. There
  is no auto-hide delay to configure.
- **Rows show the complete shortcut**, grouped by menu, paginated, with conflict markers and
  greyed-out unavailable items.
- **An actionable panel** — ↑/↓ selects, ←/→ pages, the run key runs, Esc closes. Those keys are
  consumed by the panel while it is open; clicking a row works too, and a row that still has
  further steps opens the next level. Both row keys are recorded bindings: the run key (↩) closes
  the panel and runs that row's command, the copy key (⌘↩) only writes the chord to the clipboard.
  The footer hint renders the keys you actually chose.
- **Progressive highlighting** — holding ⌘ lights up every row that starts with ⌘; adding ⇧
  narrows the glow; completing a shortcut highlights its description for a moment before the
  panel closes. Row selection (↑↓) is a separate visual state.
- **Search palette** — ⌃⌥⌘F, fuzzy search over the scoped app's menu shortcuts and the built-in
  catalog. Space-separated, order-independent terms (`com op x` = `op cm x` = ⌘⌥X), `+` as a
  separator, modifier aliases (com/cmd, op/opt/alt, ct/ctl, sh/sft and their symbols), full pinyin
  and pinyin initials for Chinese titles (`jq` → 剪切), and Latin word initials (`fs` → Find
  Similar). Return runs the selected command.
- **The palette also carries the app scope and the export** — its app menu scans any running app,
  not just the frontmost one (the live panel still follows whatever is actually in front), and
  Markdown export saves the sheet you are looking at through a save panel: grouped by menu,
  `Shortcut` / `Action` columns, unavailable items marked.
- **Hyper keys work** — hotkeys with three or more modifiers accept a superset of modifiers, so
  Karabiner-style hyper (⌃⌥⇧⌘) + K/F trigger the panel and search correctly.
- **Panel placement options** — cover the front window (default, screen-centred and guaranteed
  larger than the window in both dimensions), fixed size with editable width/height, fill the
  screen, or the old "beside the window".
- **System hotkey conflicts** — Kaname reads macOS symbolic hotkeys (Spotlight, Mission
  Control, window tiling, …) and flags the ones that collide with the frontmost app's menu
  shortcuts. System shortcuts are read-only: nothing is bound, changed, or remapped.
- **A title bar that fits** — three densities measured from the panel width, so the settings and
  close buttons stay reachable in a one-column panel instead of being pushed outside it.
- **Ordering** — the statistics page orders by Smart order (decayed usage frequency), most used
  first, key order, or alphabetical.
- **Per-app statistics, durable storage** — settings and usage live in
  `~/Library/Application Support/Kaname/` as atomic JSON files, with corrupt files preserved
  for inspection. Statistics are grouped by app, and reinstalling the app no longer risks the
  data.
- **Permission help** — a dedicated window with one card per permission: what it is for,
  Required/Optional, a live status, and a Grant button that fires the system prompt **and** opens
  the exact System Settings pane. A poll flips the card to a green "Permission granted" and brings
  the window forward; the Kaname icon can also be dragged straight into the Accessibility list.
- **A dedicated About tab** — version, build, system, update check, data folder, repository,
  licence, and live diagnostics (permissions, listener, menu item count).
- **Diagnostics you can attach to a bug report** — **Settings → Diagnostics → Export diagnostics…**
  writes one JSON report: permissions, listener state, the scan result, your settings, and the
  command that prints the matching log lines. The same report is written by `KANAME_SELFTEST=1`,
  which works while the app is already running.
- **One panel at a time** — opening search closes the panel and vice versa; a global hotkey
  (⌃⌥⌘S by default) swaps between them.
- **Manual update check** — the About tab can ask the GitHub releases API for the latest version.
  Nothing is downloaded or installed, and nothing is polled.
- **Chinese / English UI**, Reduced Transparency and Increase Contrast support, front-window aware
  positioning that avoids the focused element.
- **Engineering** — AppKit-free core in a Swift Package with unit tests, GitHub Actions, a shared
  scheme, release/install scripts, docs and screenshots.

## Fixes worth knowing about

- Esc closes the panel with or without modifiers. ⌫ still backs out one chord stroke, and only
  with no other modifier held, so ⌘⌫ stays an ordinary shortcut.
- Switching to another app or another Space closes the panel; summon it again for the new app.
- **Kaname no longer mistakes itself for the frontmost app.** Opening the search palette or
  Settings activated the app, and the catalog was then rescanned from its own menu bar — the panel
  fell back to the built-in catalog and the palette renamed itself "Kaname".
- Nothing is injected while you browse; running a row injects that one chord and finishes.
- The two "Execute menu commands" switches are gone. Neither had controlled anything since rows
  started replaying their chord, and one of them told users Return copies while it ran.
- The row keys are recorded bindings, so a habit of pressing Return expecting a copy needs
  ⌘Return — or record whichever pair you prefer.
- Dead settings are dropped rather than carried: an existing settings file still decodes, and the
  keys disappear on the next save.

## Install

Requirements: macOS 14.0 Sonoma or later on Apple Silicon (arm64). The bundle identifier is
`com.suliveevil.kaname`. The published DMG is a universal binary (x86_64 + arm64), but Intel is not
a supported or tested configuration: the cask deliberately rejects Intel Macs at install time
instead of shipping an untested app.

Install from the tap:

```sh
brew tap suliveevil/tap
brew install --cask kaname
```

or download the DMG from the release assets. Building from source:

```sh
git clone https://github.com/suliveevil/kaname.git
cd Kaname
./scripts/install.sh
```

> Builds from a machine without a Developer ID certificate are **not notarized**, so Gatekeeper
> warns on first launch. Homebrew quarantines cask downloads by default. Either approve the app once
> in System Settings → Privacy & Security → **Open Anyway**, install with
> `brew install --cask --no-quarantine kaname`, or remove the attribute with
> `xattr -dr com.apple.quarantine /Applications/Kaname.app`. The `--no-quarantine` flag applies to
> that install only; a later `brew upgrade` without it quarantines the new copy again.

Either way, the app needs **Accessibility** on first launch (System Settings → Privacy &
Security → Accessibility). Input Monitoring is only needed if key events do not arrive.

## Upgrade notes

- **The code signature or bundle identifier changing means re-granting Accessibility.** A build
  signed by a different identity, or an ad-hoc local rebuild, is a new app to macOS: remove the
  stale Kaname entry under Privacy & Security and enable the new one. A signed update that
  changes neither keeps its grant.
- **Homebrew upgrades replace the app in place.** Quit Kaname first (`brew upgrade --cask kaname`
  while it is running leaves the old process holding a deleted binary and event tap). The
  Accessibility grant survives only when the bundle identifier and signing identity stay the same.
  `--no-quarantine` is not remembered: without it, the next upgrade is quarantined and blocked on
  first launch again.
- **Uninstall removes the app, not its data.** `brew uninstall --cask kaname` leaves
  `~/Library/Application Support/Kaname` (settings, statistics, logs, local backups), the
  preferences plist, caches and saved state. `brew uninstall --cask --zap kaname` deletes all of
  them, including the backups. Neither form clears the Accessibility grant; use
  `tccutil reset Accessibility com.suliveevil.kaname`, and remove a leftover login item in
  System Settings → General → Login Items.
- **Settings and statistics move to Application Support.** The first launch reads the JSON files if
  present, otherwise migrates the previous UserDefaults payloads, including the older
  `com.suliveevil.kaname` domain; nothing needs to be re-entered. The old defaults are left in
  place and can be deleted with `defaults delete com.suliveevil.kaname` and
  `defaults delete com.suliveevil.kaname`.
- **The default placement is "cover the front window".** Switch back to "beside the window" in
  Settings → Appearance if you prefer the old layout.
- **The panel no longer narrows while you hold modifiers unless you summoned it that way**, and it
  never closes by itself: completing a shortcut passes the keys to the app, Esc closes it.
- **Holding modifiers to summon the panel narrows it**; releasing them widens it again.
- A third hotkey (⌃⌥⌘S) switches between panel and search.
- Settings, per-app statistics and the data folder carry over unchanged.

**Full changelog:** https://github.com/suliveevil/kaname/blob/main/CHANGELOG.md
