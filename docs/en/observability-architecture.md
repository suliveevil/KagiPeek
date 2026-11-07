# Kaname observability architecture

[English](observability-architecture.md) · [中文](../zh-CN/observability-architecture.md)


Version: v1.0 · Author: Archi (System Architect) · State: Implemented (historical sections are marked)

> The first half of this document is the design argument, the second half the shape after it
> landed. Sections marked "historical record" keep **the** trade-offs made at the time; their
> call-site counts, line numbers and route comparisons describe the tree as it stood then. Paths,
> type names and behaviour follow the code.

---

## 1. Technology route trade-offs (historical record)

> This section records the selection process, and the outcome has landed: every diagnostic
> instrumentation point goes through **one** façade, `Diag`, and a single call writes both the
> unified log and the file sink. The second façade mentioned here, `AppLog` (43 call sites), has
> been folded into `Diag`; the four `Logger`s (`scan` / `input` / `storage` / `ui`) are now private
> details of the `Diag` mirror, and the symbol `AppLog` no longer exists in the repository. The
> comparison below is kept as written, because it explains why things ended up here.

### Route A: plain os.Logger, harvested with OSLogStore at export time

Reuse the existing `os.Logger` façade (no call-site changes at all) and harvest at export time with
`OSLogStore(scope: .currentProcessIdentifier)`.

**Verified hard limits** (Apple Developer Forums, confirmed by a DTS engineer, with FB feedback
corroborating):

- `.currentProcessIdentifier` reads **only the current process**; **entries from the previous
  launch are unreadable** ("It doesn't even give you log entries for previous instances of the
  current program"). After a crash and restart, the log from before the crash — unreadable.
- `debug`-level entries never reach disk, existing briefly in an in-memory ring buffer (the
  "roughly 30-minute window" the community talks about comes from that buffer, not from a
  documented promise); `info` is kept only until system quota compaction or rotation discards it.
- On macOS, `OSLogStore.local()` reads the whole system log but **needs administrator rights**, so
  it is unusable for distribution.
- `getEntries` walks slowly (even with a predicate), and calling it on the main thread stutters.

**Verdict: rejected.** The moments users report problems (after a restart, hours later) fall
exactly into this route's blind spot, and "roll over by date + retention days" is not something
this unified logging system lets you control.

### Route B: own lightweight file log (adopted)

The decision is one sentence: add a file sink beside `os.Logger`, with every instrumentation point
going through the same façade, `Diag`.

This section originally weighed two variants: convert every call site to a custom Logger type
(the private `.public` / `.private` interpolations would stop working, so it meant mechanical
rewriting and stripping the annotations), or leave `os.Logger` alone and start a separate
instrumentation façade. The latter was chosen because the former touches the engine's core files
with a wide regression surface, while the instrumentation list itself was judged enough to cover
the risk of a missed node.

What survived was the existing `AppLog`; what was added was `Diag`. That combination later exposed
precisely the misjudgement: both façades looked the same at the call site, but only one reached
disk, so a report like "the keyboard is stuck and the log says nothing" was both real and useless.
So the end state is not two tracks kept in parallel but a **merge** — every `AppLog` call site
folded into `Diag` (those duplicating an adjacent `Diag` line deleted outright), with the four
`Logger`s demoted to private implementations of the `Diag` mirror. The complete reasoning is in
the git history.

### Route C: third-party SDK (XCGLogger / CocoaLumberjack + PLCrashReporter)

| Dimension | Assessment |
|---|---|
| Dependency size | Lumberjack ~2 MB of source plus the PLCrashReporter binary; Kaname is a lightweight menu bar tool, and the share of the bundle is conspicuous |
| Architectural intrusion | Lumberjack demands its own Logger type → every call site rewritten; and it brings the whole fileLogFormatter/DDFileLogger mental model |
| Crash capture | PLCrashReporter is mature (signal handling, dwarf symbolication), its only clear advantage |
| MainActor/Swift concurrency | An ObjC-era library with no Sendable annotations, rubbing against the existing strict Swift concurrency checking |
| Maintainer | Kaname is a one-person project; one more dependency is one more maintenance tax to pay |

**Verdict: rejected.** PLCrashReporter's symbolication advantage buys little for "the user exports
logs by hand to look at, or to send to the author" — the system already produces crash reports
(re-raise is enough to get one). What is wanted is "the smallest report on our own timeline plus
context completion", and a hundred lines of our own code covers that.

---

## 2. Final architecture

```
┌─────────── Kaname process ──────────────────────────────────────────────┐
│                                                                          │
│  All call sites (one facade, one call)                                   │
│       │ Diag.info(.tap, "...") / Diag.error(.inject, "...")              │
│       ▼                                                                  │
│  Diag facade (enum, nonisolated, static state behind an NSLock)          │
│       ├─► os.Logger ×4 (scan/input/storage/ui) ──► unified logging       │
│       │   (Console.app / log CLI still work; handy during development)   │
│       ├─► gate LogLevelFilter (info+ default; D/V only when verbose)     │
│       ▼                                                                  │
│  Sanitizer (regex redaction, applied on every write)                     │
│       ▼                                                                  │
│  FileLogStore                                                            │
│  (serial DispatchQueue, one file per day, 32 lines / 200 ms batched      │
│   writes, rollover + quota)                                              │
│                             │                                            │
│ ActionRecorder (RingBuffer, 30) ──mirror──► logs/last-actions.json       │
│ CrashReporter (exception handler + signal handlers + sentinel)           │
│ DiagnosticsExporter (zip packaging, triggered by the user)               │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
          ▼ files land in ~/Library/Application Support/Kaname/
             logs/    kaname-YYYY-MM-DD.log
             logs/    session.active           (unexpected-exit sentinel)
             logs/    last-actions.json        (RingBuffer disk mirror)
             crash/   kaname-crash-YYYYMMDD-HHMMSS-signal.partial   (signal scene)
             crash/   kaname-crash-YYYYMMDD-HHMMSS-SIGSEGV.json     (completed next launch)
             crash/   kaname-crash-YYYYMMDD-HHMMSS-exception.json   (NSException, written on the spot)
```

### Module responsibilities

| Module | Type | Responsibility |
|---|---|---|
| `Diag` | enum + static methods | The single instrumentation entry: `Diag.info(.tap, "event tap installed")`; methods `verbose/debug/info/warning/error` plus `action(_:target:)`; the keyword enum is `DiagTag` (`start/perm/tap/scan/inject/net/run/settings/ui/crash/exit/export`). `nonisolated`, callable from the tap thread and from crash handlers |
| `Sanitizer` | enum | A static regex list, `redact` / `prepare`; the single place it applies is before FileLogStore writes |
| `FileLogStore` | final class | Serial `DispatchQueue(label:, qos: .utility)`; batch buffer (flush on 32 lines or 200 ms); per-day file switching; rollover cleanup; quota backstop |
| `RingBuffer` | final class + NSLock | Generic ring buffer; `ActionRecorder` uses it to hold 30 `ActionRecord`s, merged into the report on a crash and debounce-mirrored to disk |
| `CrashReporter` | enum | `NSSetUncaughtExceptionHandler` + six signal handlers + sentinel mechanism + next-launch completion |
| `DiagnosticsExporter` | enum | Assembles the zip, calls the save panel; `nonisolated`, read-only, no network |
| Settings fields | `AppSettingsSnapshot` already has 2 | `diagnosticsEnabled` (default true), `verboseDiagnostics` (default false); `currentSchemaVersion` is currently 8 |

### File layout and naming

```
~/Library/Application Support/Kaname/
├── logs/
│   ├── kaname-2026-10-23.log               # line format below
│   ├── session.active                        # written on start, deleted on clean exit; leftover = unexpected exit
│   └── last-actions.json                     # the 30-entry disk mirror for ActionRecorder
└── crash/
    ├── kaname-crash-20261023-141522-signal.partial      # signal scene, open/write inside the handler
    ├── kaname-crash-20261023-141522-SIGSEGV.json        # completed on next launch, named after the signal
    └── kaname-crash-20261023-141522-exception.json      # NSException written on the spot, the only kind
```

The fragment name carries no "crash kind" placeholder: the signal path is always
`-signal.partial`, and the completed report is named after the signal (`-SIGABRT` / `-SIGSEGV` /
`-SIGBUS` / `-SIGILL` / `-SIGFPE` / `-SIGTRAP`, from `CrashLogFormatter.signalName`); the
NSException path writes `-exception.json` directly, produces no `.partial`, and there is no
`-nsexception.json`.

Log line format (one line, grep-friendly):

```
2026-10-23 14:15:22.123 I [tap] event tap installed
2026-10-23 14:15:23.004 E [inject] injection failed code=-25204 target=com.apple.Safari item="Save As…"
```

Level characters: `V/D/I/W/E`.

### Rollover and quota (defaults)

- Files switch on the calendar day; **7 days kept**, **20 MB total cap** (at the default `info+`
  level, a typical day stays under 1 MB).
- Over the total cap: delete starting from the oldest date file; when the current day's file alone
  passes 5 MB, degrade to `W/E` only (the buffer drops lower levels outright, counts them and logs
  one `dropped N lines` per hour).
- Cleanup runs on the serial queue, once per rollover (the first write after the day changes),
  with zero cost the rest of the time.
- With `verboseDiagnostics = true`, both sinks receive the full `V/D/I/W/E`; otherwise `debug` /
  `verbose` are dropped **before** the unified log is written, leaving only `I/W/E`. That is, this
  one switch also decides how much `log stream` shows you during development — open it first if you
  want to see `D` lines.

---

## 3. Crash capture design

### 3.1 Uncaught NSException (Foundation is free to use here)

```swift
NSSetUncaughtExceptionHandler { exception in
    // Still a normal context with memory available: Foundation is usable, allocation is usable
    CrashReporter.handleException(exception)
    //   → through Sanitizer, assemble a CrashReport, write kaname-crash-<ts>-exception.json
    //   → logs.flushNow(timeout: 0.3) (the process is about to die)
}
```

`reason` goes through the same redaction as log lines: a third-party assertion may stuff the user
data that caused the crash into its reason, and this report is meant to leave the machine.

Report contents: time, app version, system version, device model (`HWModelStr`/sysctl hw.model),
foreground/background state (an accessory app is always background-active, and `NSApp.isActive` is
still recorded faithfully), `exception.name/reason`, `callStackSymbols`, and the
**RingBuffer snapshot** (call sites read memory synchronously, which is enough).

### 3.2 Fatal signals (only async-signal-safe calls inside the handler)

Constraints: no malloc, no Foundation/Regex/Dispatch, no locks (they can deadlock on an
already-corrupted heap).

The implementation **precomputes everything at launch and pre-opens no fd**: `prepareSignalFragment()`
encodes the fragment path into a C string at launch, pre-serializes the context (`ver` / `build` /
`os` / `model` / `pid`) into text, and pre-allocates each signal's prefix (`sig=11\ntime=` and the
like); the file itself is only `open`ed by the handler when a signal actually arrives. That way a
clean exit never leaves behind a zero-byte `*.partial` that looks exactly like "crashed but failed
to write".

```c
// inside the handler, only async-signal-safe calls:
open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
write(context)  // pre-serialized context
write(signalPrefix)  // sig=<n>\ntime=
write(<epoch seconds, converted to decimal by hand with int>)
write("\n")
close(fd)
```

Then **restore the default disposition and re-raise**:

```c
signal(sig, SIG_DFL);
raise(sig);
```

The system still produces its own full crash report (symbolicated stack included), and our
`.partial` is merely "a mark on our own timeline". Handled signals: `SIGABRT, SIGSEGV, SIGBUS,
SIGILL, SIGFPE, SIGTRAP`. When both the NSException and the signal path are live in one process,
whichever arrives first writes and the later one stands down (the two flags are read-only inside
the handler).

**Completion on next launch**: find a `.partial` file → read its signal number and time → merge
system context (version, model, system version, `last-actions.json`, the last 200 lines of that
day's log) → write the complete `.json` report → delete the `.partial` → log
`W [crash] recovered crash report …`.

### 3.3 Unexpected-exit sentinel

- At launch `CrashReporter.beginSession()` writes `logs/session.active`, containing pid and start
  time.
- `applicationWillTerminate` runs a single exit sequence (`AppDelegate.performShutdown`), ordered by
  what cannot be recovered:
  1. **Delete the sentinel first** — deleting is idempotent and cannot fail, so it takes precedence
     over anything that might block; the same step also deletes this session's `.partial` and the
     on-disk `last-actions.json`, because a clean exit should not leave the next launch anything
     that looks like a crash;
  2. **Flush both stores** (settings, usage) — the last edit inside a debounce window is the only
     loss on this path the user cannot undo, so it goes before any step that waits on another
     process;
  3. Take the status item down and stop the engine; resetting the Karabiner variable is the
     engine's last act;
  4. A preview session restores the real settings last and flushes them itself — restoring earlier
     only hands values to an engine that is already shutting down.
  Every wait on this path is bounded: `FileLogStore.flushNow` 500 ms, `UsageStore.flush` 500 ms,
  and each `karabiner_cli` run 800 ms (terminated with a single warning on timeout) — a quit never
  hangs on another process.
- The next launch follows a fixed order, and the four steps cannot be reordered:
  1. `completePartialReports()`: complete last time's `-signal.partial` into a full report (see
     3.2). It must run before this launch's fragment paths are prepared, or an empty file gets
     deleted as a corrupt fragment;
  2. `reportPreviousSessionIfNeeded()`: the sentinel is still there → the previous run did not exit
     cleanly. With a crash report inside the time window the line is
     `W [exit] previous session ended unexpectedly (crash report: …)`, without one it is
     `(no crash report: killed, force quit or power loss)`. The leftover sentinel is then **deleted
     outright**, not archived or renamed;
  3. `writeSentinel()`: write this run's sentinel;
  4. `prepareSignalFragment()`: encode this run's signal fragment paths and context.
- Boundary: selftest mode (`KANAME_SELFTEST`) also goes through a normal `NSApp.terminate`, so the
  sentinel is cleaned up as usual.
- Hang/watchdog: explicitly not done (an accessory app has no iOS-style watchdog semantics); listed
  as a non-goal.

---

## 4. Redaction design (Sanitizer)

**The single application point: before FileLogStore writes** (including the `W/E` context lines of
crash reports; `.partial` is guaranteed by construction to hold no user data and skips the regex).

The unified log side **is not redacted**, deliberately: it stays on this machine, only an
administrator can read it, and its whole purpose is grep during development. `Diag.mirror` writes
the entire line (`[tag] message`) as **one** already-assembled string with `privacy: .public`, so
call sites no longer carry per-value `.public` / `.private` annotations — there is now a single
dividing line: **anything that leaves this machine (file sink, export archive) goes through
Sanitizer; anything that stays does not**.

The regex list (applied in order, specific before general):

| # | Target | Regex (illustrative) | Replaced with |
|---|---|---|---|
| 1 | Sensitive query keys in URLs | `(?i)([?&](?:api[_-]?key\|token\|access[_-]?token\|secret\|password\|passwd\|signature\|sig\|client[_-]?secret\|session[_-]?id\|auth)=)[^&\s]*` | `$1<redacted>` |
| 2 | Remaining URL query values | the value segment of `(\?[^\s]*=)[^&\s]{8,}` | `<redacted>` (conservative: only fragments containing `?` are replaced wholesale with `?<query>`, see the trade-off) |
| 3 | Bearer / Basic credentials | `(?i)(bearer\|basic)\s+[A-Za-z0-9._~+/=-]{8,}` | `$1 <redacted>` |
| 4 | Bare key=value pairs | `(?i)\b((?:api[_-]?key\|token\|secret\|password\|credential)[a-z0-9_]*\s*[:=]\s*)\S+` | `$1<redacted>` |
| 5 | email | `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}` | `<email>` |
| 6 | Long hex (≥32) | `\b[0-9a-fA-F]{32,}\b` | `<hex>` |
| 7 | Long base64 (≥40, trailing = included) | `\b[A-Za-z0-9+/]{40,}={0,2}\b` | `<b64>` |

Trade-off note: if rule 2 redacted every query value, the GitHub releases API URL would be
unaffected since it carries no query; the only network endpoint today is fixed and clean, rules
1+3+4 already cover the real risk, and rule 2 takes the conservative shape of "replace the whole
query segment" to prevent accidental leakage when an endpoint is added later. Rule 7 can
false-positive on legitimately base64-looking content (some bundle path hashes, say) — acceptable,
since log triage does not depend on them.

---

## 5. Recent-action path RingBuffer

- **What is recorded**: `ActionRecord { ts: TimeInterval, action: String, target: String? }`
  (`ts` is seconds since 1970, not a `Date`, so the same value means the same thing in the disk
  mirror, the crash report and a grep). `action` is an action-name string (`panel.run`,
  `search.run`, `panel.run.replay` and the like, supplied by the call site); `target` is the
  target app's bundle id (such as `com.apple.Safari`). Menu item content, key characters and
  user-typed text are **not** recorded.
- **Capacity 30**, overwriting the oldest.
- **When cleared**: on clean exit `clear()` deletes the disk mirror along with the buffer; a crash
  does not clear (keeping it is the point).
- **Merged on crash**: the NSException path reads memory and writes it into the report; the signal
  path cannot read memory → the **disk mirror** covers it: after each append, a 1-second debounce
  writes `logs/last-actions.json` atomically on the serial queue (30 JSON entries, under 2 KB,
  cost negligible). Completion on next launch folds it into the `.json` report with
  `ActionRecorder.loadMirror(at:)`.
- Threads: appends come from the MainActor engine, the tap callback thread and the crash handler;
  the ring buffer is guarded by an `NSLock`, and mirror writes are owned by one private serial
  queue.

---

## 6. Export design

**Location**: a **Diagnostics** group at the end of `SettingsView`'s **General** page, collapsed by
default (`diagnosticsContent`) — not folded into About, and not given its own sidebar entry. The
group holds:

1. Toggle: **diagnostics collection** (`diagnosticsEnabled`, on by default) — once off, `Diag`
   returns at the entry and neither sink receives new lines; log files already written stay for
   export.
2. Toggle: **verbose logging** (`verboseDiagnostics`, off by default) — once on, `D` / `V` are no
   longer dropped by the gate and both sinks receive them.
3. The log directory path plus **open folder**.
4. Button: **Export diagnostics archive…** (zip) and Button: **Export diagnostics report…** (a
   single JSON). Both buttons are on this page; the About page has no export entry.

**Export contents** (inside the zip; note the top-level directory is always `Kaname-diagnostics`
and the date lives in the zip's file name):

```
Kaname-diagnostics/
├── session-info.json     # app version/build, macOS version, device model, this run's uptime, locale,
│                         # current state of both permissions, both diagnostics switches,
│                         # a summary of key settings (modifierTriggerEnabled / hotkeyTriggerEnabled /
│                         # triggerGesture / triggerKey / panelPlacement and other non-sensitive enums),
│                         # the list of log and crash files actually packaged
├── logs/                 # the logs directory in full (already through Sanitizer)
└── crash/                # the crash directory in full
```

**Exceptions**: `logs/` skips `session.active` (it belongs to the session being exported),
`last-actions.json` (already folded into crash reports) and every `*.partial` (fragments completed
only on next launch); `crash/` also skips `*.partial`. Skipped files do not vanish silently —
a file that cannot be copied or read leaves a reason in `session-info.json`, because a missing file
in the archive has to be visible to whoever receives it.

**How**: `DiagnosticsExporter.export(to:settings:)` assembles the package on a background queue
group (`ditto` builds the zip, the main thread only spins a progress indicator) → `NSSavePanel`
picks a destination, default file name `Kaname-diagnostics-<yyyyMMdd-HHmmss>.zip`.

**Explicitly no automatic upload**: `DiagnosticsExporter` has no network capability at all;
`UpdateChecker` remains the process's only network request. The export action itself is logged as
`I [export] exporting diagnostics: N log files, M crash files`.

**Settings fields landed**: both fields are already in `AppSettingsSnapshot` (`decodeIfPresent` +
defaults, old files decode directly). `currentSchemaVersion` is currently 8; these two fields are
independent of the schema version, and adding them needed no separate migration step.

### No-GUI entry points (two environment variables)

When the window itself is broken, triage cannot depend on the window.
`AppDelegate.applicationDidFinishLaunching` has two environment-variable entry points, and their
different positions are deliberate:

| Variable | Position | Behaviour |
|---|---|---|
| `KANAME_SELFTEST` | **before the single-instance guard** | Logs `I [start] selftest mode`, runs `engine.start()` as usual, after 3 seconds writes `engine.diagnosticsReport()` to `NSTemporaryDirectory()/kaname-selftest.json`, then `stop()` + flushes both stores + `NSApp.terminate(nil)`. It sits before the guard because what you usually want to ask is the copy **already installed and running**: "what do you see?" |
| `KANAME_EXPORT_DIAGNOSTICS=<path>` | **after the single-instance guard** | Calls `DiagnosticsExporter.export(to:settings:)` to write the zip to the given path, then `NSApp.terminate(nil)`; on failure the reason goes to stderr |

Both go through a normal `NSApp.terminate`, so the sentinel is cleaned up as usual and no fake
"unexpected exit" lands in the log. The outcome is logged as
`I [ui] selftest written to <path>` or `E [ui] selftest failed: <reason>`.

---

## 7. Instrumentation list (keyword names for grep)

| Keyword | Node | Level | Example line |
|---|---|---|---|
| `[start]` | Process launch (version/system/model), single-instance guard hit, engine.start complete (including duration), selftest enter/write | I | `I [start] launch version=2.3.0 build=1234 macOS=14.5 model=Mac14,2` |
| `[perm]` | AX/Input Monitoring state flips (old→new), Secure Input enter/exit, permission request initiated, polling recovery after a denial | I / W | `I [perm] accessibility revoked` |
| `[tap]` | Tap installed, install failed (with the error domain), re-enabled after the system disabled it, stop | I / E | `E [tap] run-loop source creation failed: the tap will never deliver events` |
| `[scan]` | Scan start (bundle id, cache hit/miss), result (count, duration), empty-catalog reason (permission/no menu/excluded), ScanState changes | I (result D) | `I [scan] menu ·History is a list of data (2500 children), reading 40, keeping shortcuts only` |
| `[inject]` | Injection failure (AX error code + target + menu item title), injection success | E (success D) | `E [inject] target pid 12345 is gone, nothing posted` |
| `[net]` | Request summary (host+path only), response status + duration, failure reason (timeout/decode failure/HTTP non-200) | I / W | `I [net] update-check status=200 ms=412 latest=v2.3.0` |
| `[run]` | Row execution (action + target bundle id; menu item titles only under verbose) | I / E | `I [run] Return key ignored: no row selected (index=-1, rows=0)` |
| `[settings]` | Settings changes: **key names only** | I | `I [settings] changed: showAppleMenu, panelOrder` |
| `[ui]` | Menu bar item displaced / rebuilt, activation policy switch, login item registration failure, selftest write | I / W / E | `W [ui] menu bar item lost (…); rebuilding it` |
| `[crash]` | NSException report written, signal `.partial` completed, crash recovery found | I / E / W | `E [crash] uncaught NSInvalidArgumentException: …` |
| `[exit]` | Clean exit (including uptime), unexpected-exit sentinel found | I / W | `W [exit] previous session ended unexpectedly (no crash report: killed, force quit or power loss)` |
| `[export]` | Diagnostics package export (file counts), reasons a folder could not be copied in full | I / W | `I [export] exporting diagnostics: 3 log files, 1 crash files` |

Level discipline: the triage minimum (the failure branches of tap/perm/net/crash/exit) is always
`I/W/E`; on high-frequency success paths (scan results, run) the success state is `D` and the
summary (counts/failures) is `I`. `LogLevelFilter` is the only gate, and it decides before
`mirror`, so the unified log and the file sink are blocked together: `error/warning/info` always
write, `debug/verbose` only with `verboseDiagnostics` on.

**Where the instrumentation actually lives** (by file, no line numbers — those expire with every
refactor):

- `[start]`: `AppDelegate.applicationDidFinishLaunching` (launch summary, single instance,
  engine.start duration) and the tail of `engine.start`.
- `[perm]`: the two permission-state flip branches in `ShortcutEngine`; `PermissionCenter` only
  supplies booleans and has no instrumentation.
- `[tap]`: `KeyboardMonitor` (creation failure, run-loop source failure, restart after the system
  disabled it, watchdog removal and recovery, teardown reason) and `ShortcutTester` (test tap
  disabled).
- `[scan]`: `MenuScanner` (unauthorized, no menu bar attribute, truncation, empty-catalog reasons),
  `CatalogLoader` (cache hit/miss, superseded by a newer request, scan slot timeout),
  `ShortcutEngine` (the forced rescan triggered by a Space switch).
- `[inject]`: `ShortcutInjector` (empty chord, target process gone, key event construction failure,
  step skipped).
- `[net]`: `UpdateChecker.check` (request summary, status code + duration, failure reason).
- `[run]`: `PanelSession` (no row selected, disabled row ignored, duplicate trigger rejected,
  drill-down) and `RowRunner` (AXPress success, no chord to replay, replay failure).
- `[crash]` / `[exit]`: `CrashReporter` (sentinel write, the previous session's outcome, completion).
- `[export]`: `DiagnosticsExporter.export`.
- `[ui]`: `StatusItemController` (menu bar item lost/offscreen), `AppDelegate` (activation policy,
  selftest write), `SettingsStore` (login item failure).

---

## 8. Performance budget

| Item | Budget | Means |
|---|---|---|
| Added to the launch path | **< 2 ms** (target < 0.5 ms) | Sentinel write + mkdir + pre-encoded signal fragment paths and context text + installing both handlers, all microsecond-level syscalls; the Sanitizer regex compiles lazily once |
| One log line at runtime | in-memory append ~µs; **zero disk I/O on the tap callback thread** | Diag only concatenates a string and does `queue.async` (`.utility` QoS), with the serial queue flushing 32 lines / 200 ms |
| High-frequency paths (scan/run) | success state `D` by default, nothing on disk, counted only | the level gate decides before enqueueing and discards outright without verbose |
| RingBuffer mirror | 1 s debounce + atomic write under 2 KB | `ActionRecorder`'s own serial queue (separate from the log queue, so a log backlog cannot stall the crash mirror) |
| Quota backstop | over the cap, drop lines not the process | see the rollover strategy in §2; write failures are counted silently (a broken file sink must never affect a functional path — a Diag failure is a no-op) |
| Memory | resident < 1 MB | 256-line buffer cap + 30-entry RingBuffer + regex cache |

---

## 9. Risks and trade-offs

1. **Instrumentation coverage gaps (the biggest identified risk)**: a failure branch with no
   instrumentation is invisible in the file log — all that remains is a line in the unified log,
   which is exactly the side that is easiest to lose. Mitigation: the §7 list cross-checked against
   the code-reviewer's silent-branch inventory, and instrumentation added where a real triage gap
   shows up (purely additive, any time).
2. **The façade merge's historical baggage**: when `AppLog` was folded into `Diag`, calls
   duplicating an adjacent `Diag` line were deleted outright, so "this branch used to log" cannot
   be inferred backwards from an old version. When reading old logs, search by `DiagTag` keyword,
   not by old code position.
3. **The signal handler's ceiling**: a `.partial` carries only the signal number and a timestamp,
   never a stack. The stack depends on the system crash report produced by re-raising; if the user
   does not export the system report, we know "when it crashed, on which signal, plus the previous
   30 actions" but not the stack. For a one-person menu bar tool, that is the right cost/benefit
   call.
4. **Sanitizer false positives**: the long base64/hex regexes can swallow hash values a triager
   wanted to see. Mitigation: `[net]`/`[scan]` summary lines never include raw hashes at
   instrumentation time; occasional false positives are acceptable.
5. **Disk and privacy residue**: log and crash files survive an uninstall-reinstall in
   Application Support (sharing the fate of the existing settings.json). Exports are already
   redacted; no automatic cleanup (the retention-day policy already caps size).
6. **Sentinel false positives**: on power loss or a kernel panic `applicationWillTerminate` never
   runs → the next launch reports a spurious "unexpected exit". Acceptable: it is a statement of
   fact (it really was an unexpected exit), and a `W` level does not disturb the user.
7. **Flush on the main thread**: `applicationWillTerminate` needs a synchronous flush of the tail
   log (so the last few lines before quit reach disk). The serial queue's `sync` wait is capped at
   500 ms and gives up on timeout (the exit path must not hang).
8. **Conditions for reviving the OSLogStore route**: if macOS later allows
   `.currentProcessIdentifier` to read across launches and the user accepts "logs in the system's
   hands", route A can be re-evaluated. There is no sign of that today.

---

## 10. Suggested landing order (historical record)

> These five steps were the build order at the time, and all of them have landed. It is kept
> because the order itself carries information: why the tap/perm instrumentation went in first.
> The `schema v4` mentioned here belongs to that time; the current schema is 8.

1. `Diag` + `FileLogStore` + `Sanitizer` (with unit tests: rollover/quota/redaction/level gate)
2. `RingBuffer` + settings fields (schema v4)
3. `CrashReporter` (sentinel → exception handler → signal handler → launch completion)
4. `DiagnosticsExporter` + the SettingsView section
5. Instrument module by module per the §7 list (tap/perm first — they are the highest-frequency
   paths for triaging "the feature does not work")
