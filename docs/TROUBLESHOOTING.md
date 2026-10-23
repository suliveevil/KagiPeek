# Troubleshooting

Start here when something does not work. Every section names the log category to look at;
`log show --last 10m --predicate 'subsystem == "com.voltline.kagipeek"'` prints all of them,
and **Settings → Diagnostics → Export diagnostics…** writes a zip you can attach to a bug
report.

## Where the diagnostics live

Everything KagiPeek records stays on this Mac. Nothing is uploaded.

| What | Path |
|------|------|
| Daily logs (kept 7 days, 20 MB total) | `~/Library/Application Support/KagiPeek/logs/kagipeek-YYYY-MM-DD.log` |
| Crash reports | `~/Library/Application Support/KagiPeek/crash/kagipeek-crash-<date>-<kind>.json` |
| Last 30 user actions (for crash context) | `~/Library/Application Support/KagiPeek/logs/last-actions.json` |
| Session sentinel (crash vs. clean exit) | `~/Library/Application Support/KagiPeek/logs/session.active` |

Open the folder from **Settings → Diagnostics → Open log folder**, or run

```sh
open "$HOME/Library/Application Support/KagiPeek/logs"
```

The same archive can be produced without the window, which is useful when the window is the
thing that is broken:

```sh
KAGIPEEK_EXPORT_DIAGNOSTICS=/tmp/kagipeek.zip /Applications/KagiPeek.app/Contents/MacOS/KagiPeek
```

A line looks like `2026-10-23 17:24:11.070 I [tap] event tap installed (accessibility granted)`:
timestamp, level (`V`/`D`/`I`/`W`/`E`), and the tag you grep for. Debug and verbose lines are
omitted unless **Settings → Diagnostics → Include verbose detail** is on; failures (`I`/`W`/`E`)
are always written.

## Which keyword answers which question

| Symptom | Grep | What the line tells you |
|---------|------|------------------------|
| Menu bar icon is gone | `[ui]` | `menu bar item on screen at x=…` means it exists and sits in the bar; `lost (…); rebuilding it` means the item's window disappeared and the app rebuilt it |
| Nothing happens at all | `[tap]` | `event tap installed` vs. `failed`; `disabled by the system` means macOS pulled the tap and it was re-armed |
| Shortcuts dead after a password field | `[perm] secure input` | The OS hides key events while secure input is on — not a KagiPeek bug |
| "It worked yesterday" | `[perm] accessibility` | The grant was revoked, usually by reinstalling under a new signature |
| Panel is empty / "built-in" | `[scan]` | `state=noMenus`, `state=permissionDenied`, `menu-bar attribute missing`, `truncated at maxItems` |
| Panel is slow every time | `[scan] cache-miss` | Why the disk cache did not answer: `control`, `fingerprint`, `entryFingerprint`, `expired`, `decode` |
| A row does nothing | `[inject]` | `ax-press failed err=<AXError>` plus whether a chord replay was available |
| Run key does nothing | `[run]` | `no row selected`, or the row that was executed and where it went |
| "Check for updates" fails | `[net]` | `reason=error/parse/no-tag/url` and the HTTP status |
| App vanished / "it quit by itself" | `[exit]` + `[crash]` | `clean exit` vs. `ended unexpectedly (crash report: …)` vs. `no crash report: killed, force quit or power loss` |
| Settings did not stick | `[settings] changed:` | Which keys changed, by name |

A crash report carries the app version, macOS version, Mac model, foreground state, the last
30 actions and the tail of that day's log — enough to tell an app bug from a system restriction
without asking the user to reproduce it.

## The panel never appears

1. **Is a trigger mode enabled?** **Settings → Trigger → Trigger mode** must not be *Off*.
2. **Is Accessibility granted?** **Settings → Permissions** shows both grants. A missing
   Accessibility grant disables the key tap entirely.
3. **Is secure input active?** Password fields, login windows and some terminals hide key
   events from every app. KagiPeek hides while that is true. Leave the field and try again.
4. **Is the front app excluded?** **Settings → General → Excluded apps** lists bundle
   identifiers whose panel is suppressed. `UsageStore`/`ShortcutEngine` log nothing here by
   design; check the list.
5. **Is the key tap running?** The About tab's *Diagnostics* row says whether the listener is
   active. If it is not, quit and relaunch; if it stays off with Accessibility granted, grant
   Input Monitoring as well — some systems gate key delivery behind it.

Log category: `input` (event tap installed / failed), `ui` (permission state).

## The panel appears but the list is empty, or is "built-in catalog"

- **The app exposes no menu bar.** Games, Electron apps with custom chrome, and some utilities
  build their menus lazily: open the app's menu bar once, then summon the panel again.
- **The scan failed.** Log category `scan` records the app identity, the item count and whether
  a menu bar was found. `no menu bar exposed and no fallback allowed` means
  **Settings → General → Use built-in catalog…** is off.
- **KagiPeek was scanning itself.** Before v2.2.0, opening the search palette, the browser
  window or Settings activated the app, and its own (empty) menu bar replaced the catalog. That
  is fixed; if you see it on an older build, update.

## Pressing the run key does nothing

1. **A disabled menu item is ignored.** The row is greyed out for a reason.
2. **The app received nothing.** Running a row activates the app being browsed and posts the
   chord 0.2 s later. An app that is slow to come forward, or that handles that shortcut in a
   custom view rather than the menu bar, may not react. Log category `input` records
   `replaying … into <bundle id>` when a chord is posted and `no target app …; not injecting`
   when there was nobody to send it to.
3. **The chord is incomplete.** A row that still has further steps descends a level instead of
   running; the breadcrumb tells you where you are.

## Only ⌘↩ copies, and Return runs — is that right?

Yes. They are two recorded bindings: the run key (↩ by default) replays the row into the front
app, the copy key (⌘↩ by default) only writes it to the clipboard. Change either one under
**Settings → General → Row actions**; the footer shows what the two keys currently do.

The search palette is different on purpose: Return always runs there and there is no copy
action.

## Chinese input does not work in the search field or the browser list

The window-level key monitors step back while an input method is composing, so ↑↓ moves the
candidate window and Return commits the candidate. If ↑↓ still moves the list while a
candidate window is open, the surface is not the one you think has focus — click the field
first. Log category: `input` (nothing is logged while composing, by design).

## Opening the app asks for permissions again after every rebuild

The accessibility grant is tied to the code signature. Ad-hoc signed builds get a new signature
on every build, so macOS treats each one as a new app. Run `./scripts/setup_signing.sh` once to
create the stable `KagiPeek Local` identity; after that the designated requirement
(`identifier com.voltline.kagipeek and certificate root = …`) does not change when the code
does. The grant then survives rebuilds **on the same machine and keychain**.

## Nothing builds, or `swift test` fails immediately

`sandbox-exec: sandbox_apply: Operation not permitted` means the environment cannot create a
nested sandbox, so `xcodebuild`'s per-file compiles fail and `swift test`'s manifest build fails.
Two workarounds:

```sh
swift test --disable-sandbox           # unit tests
./scripts/build_swiftc.sh Release      # app, compiled with swiftc + explicit macro plugins
```

`./scripts/install.sh` falls back to the swiftc build automatically when `xcodebuild` fails.

## The settings reverted after a restart

A write failed. Before v2.2.0 that was silent; now `log show --predicate 'subsystem ==
"com.voltline.kagipeek" AND category == "storage"'` says `could not write settings.json: …`.
The usual causes are a read-only or full volume, or a permission change on
`~/Library/Application Support/KagiPeek`. A file that cannot be decoded is kept as
`settings.corrupt-<timestamp>.json`, so nothing is lost — you can inspect or restore it.

## A shortcut is marked ⚠︎

Another binding claims the same combination: an app menu item, or an enabled macOS system
shortcut (Spotlight, Mission Control, …). macOS decides which one wins. KagiPeek only reports
it; **Settings → Ranking → Conflicts** lists both sides.

## The menu bar icon is gone

Check the log first: `[ui]` tells you which of two very different things happened.

| Log line | Meaning |
|----------|---------|
| `menu bar item on screen at x=… w=…` | The item exists and sits in the menu bar. If you cannot see it, something is covering or collapsing it. |
| `menu bar item is off-screen (x=… w=…)` | A menu bar manager moved it out of the bar — it is in that tool's hidden section. |
| `menu bar item lost (…); rebuilding it` | The item's window had disappeared; the app removed it and asked for a new one. |
| Nothing at all | The app never got as far as creating the item — check for `[start] launch` first. |

**Menu bar managers take the item on purpose.** Thaw, Ice and Bartender capture every status
item and lay them out themselves. With Thaw's *Ice Bar* enabled (`useIceBar`) and *always show
hidden items* off, a newly seen item starts in the collapsed section behind the `•••` icon.
Drag KagiPeek out of that section once and the layout remembers it.

**Watch for a stale identity.** These tools key items by `bundle id:item title`. KagiPeek's
bundle id changed case once (`com.Voltline.KagiPeek` → `com.voltline.kagipeek`), so a manager
can hold two records for the same app and treat the current one as new. Deleting the old
record is enough; the stale one is the entry that is no longer produced by the running app.

**The app defends itself, within its rights.** The item is an `NSStatusItem` the app owns, with
a stable autosave name and a constant accessibility label, and it is rebuilt when its window
disappears. What it cannot do is force a manager to show it.

**Second door.** **Settings → General → Show a Dock icon as well** turns the Dock icon back on;
clicking it opens Settings. The keyboard shortcuts themselves never depended on the icon.

## Keeping KagiPeek running in the background

What is already in place, and what each part is for:

| Mechanism | What it buys |
|-----------|--------------|
| `LSUIElement` + `.accessory` activation policy | No Dock icon and no window to close: the process stays alive exactly as long as you do not quit it |
| **Settings → General → Launch at login** (`SMAppService`) | The app is there after a reboot, without a login item script |
| `beginActivity(.userInitiatedAllowingIdleSystemSleep)` | App Nap cannot throttle the app while it is idle — the event tap stays responsive. Idle sleep is deliberately *not* disabled: a shortcut helper has no business keeping the Mac awake |
| `[tap] woke from sleep: re-asserting the event tap` | Sleep drops event taps and can change permissions. On wake the app re-checks permissions, re-arms the tap and refreshes the catalog |
| `[exit] clean exit` / `ended unexpectedly` | Every stop is recorded, so "it disappeared" is always answerable |

What is deliberately *not* implemented: a `KeepAlive` launch agent that restarts the app after
a crash or a force quit. It would survive everything, at the cost of a second bundle item, an
extra approval in System Settings, and an app that comes back from a state you asked it to
leave. The crash report says why it died; restarting it is a decision, not a default.
