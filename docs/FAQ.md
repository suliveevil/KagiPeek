# FAQ

Answers to questions that come up after the first launch. For installation and permissions, see the [README](../README.md) and [PERMISSIONS.md](PERMISSIONS.md). For internals, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Nothing happens when I hold a modifier

Work through these in order:

1. **Is KagiPeek running?** It is a menu bar app with no Dock icon. Look for the keyboard icon in the menu bar.
2. **Is a trigger enabled?** Open Settings and check that the trigger mode is not **Off**. The default is *hold modifiers and pause*.
3. **Is Accessibility granted?** Open **Settings → Permissions**. Accessibility is required for menu reading and for creating the key tap. If keys still do not arrive, grant **Input Monitoring** as a fallback and relaunch KagiPeek.
4. **Are you in a password field?** Secure input hides the panel by design. Click into a normal window and try again.
5. **Does the app have a menu bar?** Some games, overlays, and custom-drawn apps do not. With Accessibility granted but no menu bar, KagiPeek falls back to its built-in catalog; if the catalog is disabled you will see nothing.
6. **Is the hold long enough?** The default pause is 0.5 s and can be set between 0.1 s and 1.5 s.
7. **Is another app grabbing the hotkey?** If you use the global hotkey trigger, check for a conflict with another launcher or automation tool. Hotkeys with three or more modifiers also match when a Hyper-key tool adds a fourth modifier, so check for that too.

If the menu bar icon is missing entirely, quit any duplicate copy and relaunch KagiPeek from `/Applications`.

## Why does app X show no shortcuts?

KagiPeek reads the app's **menu bar** through Accessibility. It can only show what the app actually advertises as a menu key equivalent.

- Shortcuts implemented directly in custom views, toolbars, web content, or games are invisible to Accessibility and therefore to KagiPeek.
- Some apps build their menus lazily. Open the app's menu bar once, then trigger KagiPeek again; switching apps forces a fresh scan, and the per-app cache lasts 20 seconds.
- Some menu items intentionally have no key equivalent. KagiPeek does not guess one.
- If the app's menu bar is unusually large or slow, the 0.35 s AX timeout may truncate the scan. Retry after the app becomes responsive.

The built-in catalog (about 100 system, text-editing, Finder, and screenshot shortcuts) fills in common cases but cannot know an app's private shortcuts.

## Can I browse another app's shortcuts without switching to it?

Yes. The search palette's app menu lists the frontmost app plus every running regular app. Choose one and the palette scans and searches that app's menu shortcuts; its header then names that app, and Return runs the command inside it.

The floating panel is deliberately separate: whichever app the window is browsing, the panel still follows the real frontmost app, because that is the app your keys will reach.

## How do I export a shortcut sheet?

In the search palette, press the export button and choose a location. KagiPeek writes a Markdown file named after the app you are scoped to, with one section per menu and a `Shortcut` / `Action` table per section. Unavailable items are marked `(unavailable)`, and the sheet reflects the matches on screen — or the whole list when the field is empty.

## Why two permissions instead of one?

**Accessibility is required. Input Monitoring is an optional fallback.**

- **Accessibility** lets KagiPeek read another app's menu bar, create the global key tap, and (if you opt in) press a menu item through `AXPress`. Without it, only the built-in catalog can be shown and no trigger can fire.
- **Input Monitoring** covers the cases where macOS does not deliver key events to a tap created with Accessibility alone. On most Macs you never need it; KagiPeek checks it separately and only points you there when the key tap is not receiving events.

You do not need both to get started. Grant Accessibility first, try holding ⌘, and add Input Monitoring only if the panel does not appear. See [PERMISSIONS.md](PERMISSIONS.md) for the full walkthrough.

**Request Access** in **Settings → Permissions** does two things at once: it shows the system authorization prompt and opens the matching System Settings pane (Accessibility or Input Monitoring), so you do not have to find it yourself.

## How do I add KagiPeek to the permission list by dragging it?

The Permissions tab shows a KagiPeek app icon that is a real drag source. Drag it into the list in **System Settings → Privacy & Security → Accessibility** (or **Input Monitoring**) to add the running app there: open the pane, then drop the icon on the list. This is the quickest fix when KagiPeek is not listed at all. You still have to switch the entry on afterwards — macOS grants nothing until you toggle it.

## Does KagiPeek record what I type?

No. There is no keystroke log and no text capture. Shortcut processing is local; the only network request is the manual update check described below.

- The global key tap is used to compute modifier/key state and to detect the recorded hotkeys. Events pass through to the front app untouched, except KagiPeek's own panel, search, and switch hotkeys and the panel's navigation keys, which are consumed; a shortcut that completes a row is **not** consumed. No event is logged, replayed, or written to disk.
- Usage statistics store a **count and a last-used timestamp per `bundleID|chord`**, not a stream of key presses. They live in `usage.json` in Application Support, are grouped by app in Settings, and can be reset.
- Menu scans are cached in memory per app for 20 seconds. Switching apps forces a rescan, app launch/quit clears the cache, and changing the language or catalog setting refreshes it. They are not uploaded or archived.
- The only files KagiPeek writes are `settings.json` and `usage.json` in `~/Library/Application Support/KagiPeek/`; see *Where are settings and statistics stored?* above.
- Search queries are not recorded.
- **The update check is the only network request.** It runs only when you press **Check for updates**, fetches the public GitHub release document, and sends nothing about you, your apps, or your shortcuts.
- When macOS reports secure input (password fields, login windows), the panel hides.

KagiPeek has no accounts, telemetry, or crash-reporting endpoint. See the privacy sections in the [README](../README.md#privacy).

## Why isn't KagiPeek on the Mac App Store?

Because the App Sandbox makes the core features impossible. KagiPeek must read another app's menu bar via the Accessibility API and observe global key events with an event tap; both are outside what a sandboxed app may do. The project therefore ships as a Developer ID/notarized (or ad-hoc, for local builds) app outside the store, with the sandbox disabled.

The app is also GPL-2.0 licensed. App Store distribution would impose additional terms that conflict with the license.

## How does search work?

Press **⌃⌥⌘F** (default) to open the search palette, or press `/` while the panel is open. It searches the scoped app's menu shortcuts (plus the system's hotkeys when no scope is chosen) over title, key combination, menu path, modifier names, and pinyin.

- **Terms are unordered and all must match.** `com op x`, `op cm x`, and `cmd+opt+x` all find ⌘⌥X; `+` is just another separator.
- **Modifier aliases** are understood: `com`/`cmd`/`command`/`cm`/`⌘`, `op`/`opt`/`option`/`alt`/`⌥`, `ct`/`ctl`/`ctrl`/`control`/`⌃`, `sh`/`sft`/`shift`/`⇧`.
- **Chinese titles match pinyin:** full pinyin (`jian qie`), spaced syllables, and initials (`jq` for 剪切).
- **English titles match word initials:** `fs` finds Find Similar.
- Better matches rank first; the ranking is not affected by the order you type the terms in.
- **↑/↓** moves the selection.
- **Return runs the selected shortcut.** The palette closes, the app you were in comes back, and that one chord is replayed into it. It is not a copy: the palette has no copy action at all.
- To copy a chord without running it, use the copy key in the panel — ⌘↩ by default, a recorded binding.
- Menu commands can be destructive (Delete, Empty Trash, Quit), which is why nothing runs until you press Return; the first match is merely selected.

## What does the ⚠︎ next to a shortcut mean?

Another binding claims the same key combination. KagiPeek lists every conflict in **Settings → Conflicts**, with a type (menu order, blocked by macOS, blocked by a tool, two tools, one tool against itself) and a likely winner. Clashes with enabled macOS system shortcuts are included and marked as the system layer.

The warning is informational. macOS decides which menu item actually receives the key equivalent; KagiPeek cannot change that. A conflict often means an app exposes the same shortcut twice in different menus, or that a global shortcut collides with an app menu shortcut. If the app's own behavior surprises you, the conflict list is the place to look.

## Why does a macOS system shortcut show up as a conflict?

macOS keeps its own system-wide shortcuts (Spotlight, Mission Control, screenshots, input-source switching, …). KagiPeek reads the enabled ones through Carbon and compares them with the app's menu shortcuts. When they collide, both rows are marked ⚠︎ and the conflict list shows the system entry under **System hotkeys** / **系统热键**.

That list is read-only. KagiPeek never binds, changes, or disables a system shortcut; change those in **System Settings → Keyboard → Keyboard Shortcuts**.

## Why does the panel stay open after ⌘K?

Because `⌘K` is the first stroke of a **multi-stroke shortcut** (a chord), such as `⌘K ⌘C` in VS Code-style editors. When the current stroke has further completions, the panel descends one level and shows what can follow; the breadcrumb shows the prefix.

- Press the next stroke to continue.
- Press **⌫** to go back one level; **Esc** closes the panel. Both apply only when no other modifier is held, so ⌘⌫ and similar combinations remain normal shortcuts.
- Press the key that completes a shortcut to finish: the panel highlights the row for about 0.4 s, closes, and the shortcut runs in the front app. A key with no match leaves the panel open — it no longer closes on a miss.

Otherwise the panel stays open because it is persistent by design. Releasing the modifiers does not dismiss it.

If a chord is not visible, the app may not expose it as a menu key equivalent, or the scan may have missed that menu.

## Why doesn't the panel close by itself?

Because v2.1.0 made the panel **persistent**. The auto-hide delay and its setting were removed: there is no idle timer, no "browse" versus "pinned" mode, and no way to configure a timeout. The panel stays on screen until one of these happens:

- you press a **complete shortcut** — the panel highlights it for about 0.4 s and closes;
- you press **Esc**;
- you press the **panel hotkey** (or the **switch panel/search** hotkey) again.

Releasing the modifiers you were holding does not close it either. This is deliberate: the panel is now a reference surface you can read at your own pace, and it is dismissed by a clear action instead of a timer.

## Why does Esc close the panel, and why can't I just click away?

Esc is the panel's explicit "dismiss" gesture. It is handled while no other modifier is held, so ⌥⌘Esc and similar combinations stay ordinary shortcuts, and the panel lifts as soon as you want it gone. Clicking outside the panel is not a dismissal because the panel is non-activating: clicks elsewhere go to the front app as usual, so an outside click cannot be relied on to close it. Esc plus the panel/switch hotkey give you a predictable way out.

## Why does the shortcut I press still reach the app?

Because KagiPeek only **observes** keys; it does not remap them or replay them. When you press a complete shortcut, KagiPeek uses the event to highlight the matching row, closes the panel, and lets the same event continue to the frontmost app. That is why the command runs immediately, exactly as if the panel had never been open. The events KagiPeek actually consumes are only its own hotkeys and the panel's navigation keys (arrows, Return, Esc); a completed shortcut is never swallowed.

## Can I use a Hyper key (⌃⌥⇧⌘) with KagiPeek?

Yes. When a recorded hotkey has **three or more modifiers**, KagiPeek accepts events that carry a **superset** of them. A Karabiner-Elements or BetterTouchTool Hyper key (usually ⌃⌥⇧⌘) therefore triggers a recorded ⌃⌥⌘ hotkey. Hotkeys with fewer than three modifiers are matched strictly, so a two-modifier shortcut is not widened.

Record the hotkey as usual in **Settings → Trigger** — you do not need to configure anything extra for the extra modifier. The trade-off is intentional: a three-modifier hotkey can also fire when another tool adds a modifier.

## How do I use the panel with the keyboard?

The panel is persistent, so keyboard operation is always available:

| Key | Action |
| --- | --- |
| ↑ / ↓ | Move the selection |
| ← / → | Previous / next page |
| Run key (↩ by default) | Close the panel and replay the selected row's shortcut into the front app |
| Copy key (⌘↩ by default) | Copy the selected row's shortcut; the panel stays open |
| Esc | Close the panel (with or without modifiers) |
| `;` / `'`, ⌃B / ⌃F | Previous / next page |
| Click | Same as the run key |
| The complete shortcut | Highlight the matching row for ~0.4 s, close the panel, and let the shortcut run |

Both keys are recorded under **Settings → General → Row actions**, so the footer's `↵ run · ⌘↩ copy` always names the keys you actually chose. With no modifier held, the navigation keys and the two row keys are consumed by the panel and do not reach the front app. ⌫ backs out one chord stroke and is only handled with no other modifier held, so ⌘⌫ stays an ordinary shortcut.

Two visual states are easy to confuse: the **selection** (↑/↓ or the pointer) is a cursor you move yourself, while the **key highlight** marks the rows the current prefix can reach. A row can be selected without being highlighted, and vice versa.

Pressing the run key on a row that still has further steps opens the next level instead of running it.

## Why did the panel copy instead of running the command?

It should not: the run key runs the row. If a row copies, you either pressed the copy key (⌘↩) or recorded the two keys the other way round under **Settings → General → Row actions**. The footer always shows which key does what, so check it first — and note that the search palette is the one surface where Return always runs and there is no copy key at all.

## Why did nothing happen when I pressed the run key?

Two common causes. A **disabled menu item** is ignored: the app reports it as unavailable, so there is nothing to run. Or the target app never received the command — from the panel, KagiPeek presses the menu item itself (no focus change, nothing to wait for), so a menu item that macOS will not let another process press falls back to replaying the chord; from the palette, the scoped app is activated first and then the command runs, so an app that is slow to come forward, or one that handles that shortcut in a custom view with no menu item, may not react. **Settings → About → Export diagnostics…** plus `log show --last 5m --predicate 'subsystem == "com.voltline.kagipeek"'` shows whether the chord was posted and to which bundle identifier.

## Why does the panel disappear in some apps or fields?

macOS **secure event input** is active. Password fields, login windows, and some terminals deliberately hide key events from event taps. KagiPeek detects this, hides immediately, and does not try to work around it. Leave the secure field (or close the app holding secure input) and the panel returns.

## Where are settings and statistics stored? How do I reset them?

In **`~/Library/Application Support/KagiPeek/`**, as two plain JSON files — not in UserDefaults:

```text
~/Library/Application Support/KagiPeek/
  settings.json
  usage.json
```

Both are written atomically. If a file cannot be decoded, KagiPeek renames it to `settings.corrupt-<timestamp>.json` (or `usage.corrupt-<timestamp>.json`) and starts from defaults, so the damaged file is kept rather than silently lost. **Settings → Statistics → Show data folder** opens the folder in Finder, and the About tab shows its path.

- **Reset statistics only:** **Reset statistics** in **Settings → Statistics**.
- **Reset all settings:** **Restore defaults** in **Settings → Statistics**, or quit KagiPeek and delete `settings.json`.
- **Remove everything:** quit KagiPeek and move the whole `~/Library/Application Support/KagiPeek` folder to the Trash.

The first v2.1.0 launch migrates the old UserDefaults data (including the 1.x `com.Voltline.KagiPeek` domain) exactly once. The old defaults are left untouched afterwards; you can remove them with `defaults delete com.voltline.kagipeek` and `defaults delete com.Voltline.KagiPeek`.

## Will I lose my settings and statistics if I reinstall or update?

Normally no. Because the data lives in Application Support rather than the app's preference domain, uninstalling KagiPeek (moving the app to the Trash), replacing it with a differently signed build, or updating it does not remove `settings.json` / `usage.json`. The data is lost only if you delete the folder manually, reset it, or use a "clean uninstall" tool that removes Application Support data.

The flip side: an old preferences-only cleanup command (`defaults delete`) no longer clears your statistics. Remove the folder instead.

## How do I switch between the panel and search?

Press the **switch panel/search** hotkey — ⌃⌥⌘S by default, recordable in **Settings → Trigger**. It is a single toggle with three cases:

- search visible → show the panel;
- panel visible → show search;
- neither visible → open the panel.

The two surfaces are **mutually exclusive**: opening one closes the other, so you never have both on screen at once.

## Do I need to grant permissions again after an update?

It depends on the signature:

- The **v1.1 → v1.2 upgrade always required re-granting Accessibility**, because the bundle identifier changed from `com.Voltline.KagiPeek` to `com.voltline.kagipeek`. Remove the stale entry if it remains and enable the new app.
- The **v1.2 → v2.0 and v2.0.0 → v2.1.0 upgrades do not change the bundle identifier**, so a signed update keeps its Accessibility grant. The v1.1 → v1.2 exception above still applies if you skipped a release.
- A **Developer ID-signed, notarized release** keeps its code identity, so later updates normally keep the grants.
- An **ad-hoc signed build** (the default for local builds) changes identity when rebuilt. macOS may treat it as a different app: remove the old KagiPeek entry from Accessibility (and from Input Monitoring if you granted it), add the new build, and relaunch.
- Replacing `/Applications/KagiPeek.app` with a build signed by another identity has the same effect.

This is a macOS privacy protection, not a KagiPeek bug. See [PERMISSIONS.md](PERMISSIONS.md).

## Why is there no Dock icon?

KagiPeek is an `LSUIElement` agent app: it lives in the menu bar with no Dock icon and opens no window at launch. The menu bar icon opens the panel, the palette and Settings; ⌘, opens Settings from inside any of its windows.

## Can I change the triggers or the hotkeys?

Yes. **Settings → Trigger** configures the trigger mode (hold modifiers, double-⌘, global hotkey, or off), the hold delay, and all three hotkeys. The defaults are:

| Action | Default |
| --- | --- |
| Hold to peek | ⌃/⌥/⌘ held for 0.5 s |
| Panel hotkey | ⌃⌥⌘K |
| Search hotkey | ⌃⌥⌘F |
| Switch panel/search | ⌃⌥⌘S |

KagiPeek does not remap application shortcuts. It reports what the app already declares.

macOS system shortcuts are read-only here as well: KagiPeek reports collisions with them in the conflict list, but it cannot bind, change, or disable Spotlight, Mission Control, or any other system hotkey.

## What is Smart order?

The default order of the statistics page: presses weighted by an exponential decay (roughly a 60-day scale), so a shortcut used ten times last week outranks one used ten times last year, and a stale favourite fades instead of dominating forever. Ties fall back to the raw press count.

**It does not order the panel.** The panel is always in key order — ⌘ → ⌥ → ⌃ → ⇧, then the key — because it is a reference card, and "most used" would move a row every time you run one. The search palette is always in match order for the same reason.

All four orders live in **Settings → Statistics → Sort order**: smart order, most used first, key order, and alphabetical. They apply to both lists on that page — the per-app list and the rows inside an app.

## Can I hide disabled menu items?

Yes. Menu items whose `AXEnabled` state is false are greyed out by default and can be hidden entirely in Settings. This is useful in apps where most of a menu is contextually unavailable.

## Why does the panel sometimes appear in an odd place?

That depends on **Settings → Appearance → Panel placement**:

- **Cover the front window** (default) makes the panel large enough to cover the front window in both dimensions and centers it on the screen.
- **Fixed size** uses the width and height you set (720 × 620 by default) and centers it.
- **Fill the screen** uses the whole visible screen area.
- **Beside the front window** is the old v1.x/v2.0 behavior: the panel sits beside or below the window and tries not to cover the focused element.

The geometry is computed when the panel opens. If the window moved after that, or if an app reports unusual window frames, full-screen spaces, or multiple displays confuse the anchor, the panel can look misplaced. Close and reopen it, or choose a different placement.

## Does KagiPeek use much CPU or battery?

It is event-driven. The key tap is idle until you press a key; menu scans happen on trigger and are cached per app for 20 seconds; nothing polls in the background. If you see sustained CPU use, note the frontmost app: a hung app with a very large menu can make AX scans expensive until the timeout kicks in.

The macOS system hotkey list is read once at launch (and again after you change the interface language), and the update check runs only when you press the button.

## Does KagiPeek check for updates automatically?

No. There is no background polling. **Settings → About** has a **Check for updates** button; only when you press it does KagiPeek request the latest GitHub release, compare it with the running version, and then either link to the release page, say you are up to date, or report that the check failed. It never downloads or installs anything on its own.

## How do I uninstall KagiPeek?

1. Quit KagiPeek from the menu bar.
2. Move `/Applications/KagiPeek.app` to the Trash.
3. Optionally remove settings and statistics:

```bash
rm -rf ~/Library/Application\ Support/KagiPeek
defaults delete com.voltline.kagipeek        # only for a v2.0-era install
defaults delete com.Voltline.KagiPeek        # only for a 1.x-era install
tccutil reset Accessibility com.voltline.kagipeek
tccutil reset ListenEvent com.voltline.kagipeek
```

The `tccutil` commands are optional; they clear the leftover privacy entries. `ListenEvent` only matters if you granted Input Monitoring. The `defaults` commands are only needed for data written by older versions; v2.1.0 keeps everything in the Application Support folder.

## What are the system requirements? Is there a Windows or Linux version?

KagiPeek requires macOS 14 Sonoma or later. It is built on AppKit, Accessibility, and Core Graphics event taps, all of which are macOS-only. There is no Windows or Linux version and none is planned.

## Why do the shortcuts differ from the app's own cheat sheet?

A cheat sheet documents what the app supports; KagiPeek reports what the app currently exposes in its menu bar, including enabled/disabled state and localized menu titles. Custom views, web apps, and context menus can support shortcuts that never appear in the menu bar, so those will not show up. Conversely, a menu item can be present but disabled, which KagiPeek greys out.

## Something else is wrong

Open an issue at [github.com/suliveevil/KagiPeek/issues](https://github.com/suliveevil/KagiPeek/issues) with:

- macOS version and KagiPeek version
- the app you were in when it happened
- whether Accessibility shows as granted (and Input Monitoring, if you needed it)
- steps to reproduce, and a screenshot if the panel misbehaves

Please do not paste passwords, private menu titles, or other sensitive screen content.