# Privacy

KagiPeek reads other apps' menu bars and watches the keyboard, so it is fair to ask exactly
what it does with either. This page is the complete list.

## What it reads

| What | Why | Where it goes |
| --- | --- | --- |
| The frontmost app's menu bar (titles, key equivalents, enabled state) | To show its shortcuts | Memory, cached per app for 20 seconds; also cached on disk per app for up to 10 minutes (see below) |
| Key events (key code, modifiers, and — while a surface is reading them — the typed character) | To detect your hotkeys, drive the panel, and type into the search palette | Memory only, for the duration of the event |
| Enabled macOS system shortcuts (Carbon) | Conflict detection | Memory only |
| Third-party shortcut config files, **opened read-only**, when config scanning is on: `~/.config/karabiner/karabiner.json`, `~/.config/skhd/skhdrc` (or `~/.skhdrc`), `~/Library/Application Support/Keyboard Maestro/Keyboard Maestro Macros.plist`, the newest `btt_data_store.version_*` in `~/Library/Application Support/BetterTouchTool/`, `~/.hammerspoon/init.lua`, and `info.plist` inside `Alfred.alfredpreferences/workflows/*` | To find shortcuts that a menu scan cannot see | Memory only: chord, title and owning tool. Nothing from them is written to disk |
| The frontmost window's frame | Placing the panel beside or over it | Memory only |
| The list of running apps | The search palette's app scope | Memory only |

It does not read documents, text fields, window contents, the clipboard, or your browsing
history. Secure input (password fields, login windows) is detected, and the panel hides.

Config files are opened **read-only** — BetterTouchTool's SQLite database with SQLite's
read-only flag — are read at launch and when you ask for a rescan, and are never written,
copied or uploaded. Turning **Settings → Conflicts → Config file sources** off discards
everything found and opens none of them again.

## What it writes

Two JSON files in `~/Library/Application Support/KagiPeek/`:

- `settings.json` — your settings, including the recorded hotkeys and row keys.
- `usage.json` — a press count and a last-used timestamp per `bundleID|chord` (800 entries at
  most), plus your pinned shortcuts. No raw key events, no typed text, no queries.

Both are written atomically, and a file that cannot be decoded is preserved as
`*.corrupt-<timestamp>.json` rather than discarded. Search queries stay in memory.

Everything else that is written is derived or diagnostic rather than personal data:

- `conflicts-cache.json` — the last cross-app conflict scan, so opening the Conflicts tab does
  not walk every app's menus again. Chord, title and owning layer per finding.
- `menu-cache/` — one cached menu scan per app identity (`menus-<identity>.json`) plus a small
  `control.json` recording the settings the entries were written under. It holds exactly what a
  scan already read (menu titles, menu paths, key equivalents, enabled state), so re-opening the
  panel for the same app, or relaunching KagiPeek, does not walk the menu bar again. Entries are
  kept for at most 10 minutes and dropped when a scan-shaping setting changes or when you press
  "Restore defaults". An entry that cannot be decoded is dropped instead of preserved, because
  unlike settings and statistics it can be reproduced by scanning again.
- `logs/` and `crash/` — the daily diagnostic log, the last 30 action *names* (never menu text,
  typed characters or queries), and one JSON file per crash. They exist to explain a bug, logging
  can be switched off under **Settings → Diagnostics**, and deleting the folder costs a rescan and
  a history, nothing else.

None of these ever leaves the machine.

## What it sends

Nothing, except the update check you trigger yourself: it reads the public GitHub release
document once. There is no telemetry, no analytics, no account, no crash reporting endpoint.

## What it injects

One chord, when you ask for it. Pressing the run key, clicking a row, or pressing Return in the
search palette closes the surface and posts **that row's key combination** to the front app
(`CGEvent`, HID event tap), then stops. This exists so a menu command can be run without
reaching for the menu.

- Browsing the panel injects nothing.
- The copy key injects nothing; it only writes to the pasteboard.
- KagiPeek never replays what you type, and never injects more than the one chord.

## What it consumes

The global key tap is *active*, so it can swallow a key instead of passing it on. The keys it
swallows are:

- the hotkeys you recorded (panel, search, switch);
- while the panel is open: arrows, `;` / `'`, ⌃F/⌃B/⌃N/⌃P, Esc, the two recorded row keys, and
  ⌫ while navigating a chord;
- while the search palette has focus: whatever you type into its field, which the text field itself reads.

Everything else reaches the front app untouched, including a shortcut that completes a row:
the panel closes and the event continues, so the command runs exactly once.

## Logs

The app writes to the unified log under the subsystem `com.voltline.kagipeek`, in four
categories: `scan`, `input`, `storage`, `ui`. Entries name the app being scanned, whether a
chord was posted and to which bundle identifier, and whether a file write failed. They do not
contain typed text or the contents of your documents, and they stay on your machine unless you
choose to include them in a bug report — **Settings → About → Export diagnostics…** writes a
JSON file for exactly that purpose, and you decide who receives it.

## Permissions

Accessibility is required (menu reading and the key tap). Input Monitoring is an optional
fallback for systems that do not deliver key events with Accessibility alone. There are no
other grants; KagiPeek never asks for Full Disk Access, Screen Recording, or Automation. See
[PERMISSIONS.md](PERMISSIONS.md).

## Verifying this

The source is GPL-2.0. The relevant files are small and easy to audit:

- `KagiPeek/Core/Input/KeyboardMonitor.swift` — what is observed and what is swallowed;
- `KagiPeek/Core/Input/ShortcutInjector.swift` — the only code that posts events;
- `KagiPeek/Core/Storage/` — the only code that writes files;
- `KagiPeek/Core/Services/UpdateChecker.swift` — the only network code.
