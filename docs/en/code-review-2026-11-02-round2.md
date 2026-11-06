# Kaname code re-review (round two)

[English](code-review-2026-11-02-round2.md) · [中文](../zh-CN/code-review-2026-11-02-round2.md)


Re-review date: 2026-11-02 · Baseline: `83a1b03` · Scale: `Kaname/` 129 files / 21,431 lines
plus `Tests/` 43 files / 6,028 lines
Compared with: round one of 2026-11-02 (`docs/en/code-review-2026-11-02.md`, baseline `bd8b926`,
126 files / 20,542 lines)

Principles referenced as in round one: *Refactoring*, 2nd edition (R2), *Clean Code*, *Clean
Architecture* (the dependency rule), *The Pragmatic Programmer*, *Migrating to Swift 6*, and
Apple's *macOS Human Interface Guidelines*.

---

## 0. What actually happened to round one's 20 items

Round one's items were **not all fixed**. Measured one by one (the ✅ marks in the documents were
not trusted; every item was re-measured):

| Item | Document mark | Measured | Verdict |
|---|---|---|---|
| P0-1 dependency inversion | ✅ Fixed | `Core/` has 0 references to its own `UI/` types; 111 files pass `-typecheck` independently | **Largely done, one leftover** (see N1) |
| P0-2 assumeIsolated | ✅ Resolved | 24 sites, all forced by SDK signatures | ✅ Done |
| P0-3 unbounded queue | ✅ Fixed | `InputMailbox` bounded + drop counts + resync, with unit tests | ✅ Done |
| P0-4 swallowed errors | ✅ Fixed | `try!` eliminated (0 in app code, 3 in tests); `try?` 62 → 59, of which **those swallowing real errors 57 → 54** | **Partly done**: the diagnostics-export thread is closed (N4), the other 54 untouched |
| P1-5 God class | Unmarked | Engine 2,530 lines / **19 MARK sections** (baseline 2,775 / 20) | **Not done** |
| P1-6 long functions | Unmarked | 9 → **3** | **Mostly done** |
| P1-7 double polling | ✅ Fixed | A single timer | ✅ Done |
| P1-8 11 parameters | ✅ Fixed | `PermissionPresentation` + `PermissionPolicy` | ✅ Done |
| P1-9 two logging façades | ✅ Fixed | `AppLog.swift` deleted (confirmed in git) | ✅ Done |
| P1-10 `fatalError` | Unmarked | `AppIconDragSource.swift:53-56` already carries `@available(*, unavailable)` | ✅ **This item's "not done" verdict is refuted** (see the N5 correction) |
| P2-11 comment volume | Unmarked | `KeyboardMonitor` 27.8% (not "close to half"), the incident chronology compressed to one line | **No longer a problem** (the original description is refuted) |
| P2-12 naming consistency | ✅ Fixed | — | ✅ Done |
| P2-13 accessibility | Unmarked | Fixed in `8586235`: icon buttons gained labels, decorative icons hidden | ✅ **Already done, mis-tagged in the document** (the original measurement method was wrong, see §3) |
| P2-14 hit areas | Unmarked | `.contentShape` still 7 sites, unchanged from the baseline | **Not done** (see N10, and the suggestion needs re-judging) |
| P2-15 Observation | Unmarked | `ObservableObject` still 10, `@Observable` still 0 | **Not done** (see N10) |
| P2-16 fixed sizes | Unmarked | `.frame(width:/height:)` still 41, unchanged from the baseline | **Not done** |
| P3-17 tests cover Pure only | Unmarked | 537 tests, 43 files; but the engine and input layers still have none | **Partly improved** (see N9) |
| P3-18 concurrency migration | Unmarked | Swift 6 + `complete`, 0 diagnostics on all three paths | ✅ Done |
| P3-19 build depends on an installed artefact | Unmarked | `scripts/Info.plist` is in the repository, the installed artefact demoted to a fallback | ✅ **Already done, mis-tagged in the document** |

**In one sentence**: P0 and P1-7/8/9, P3-18/19 are genuinely done; **P1-5, P1-10, P2-14/15/16 were
not touched at all**; P0-4, P1-6, P3-17 are partly done; P2-13 and P3-19 are done but the document
does not say so.

---

## 1. New findings this round

### N1 (P1)　✅ Fixed　P0-1 only moved half of it: the engine still holds an `NSWindow`

- Location: `Core/Engine/ShortcutEngine.swift:108` (that line has been deleted)

  ```swift
  /// The fixture's own settings window: an `NSWindow` with `isReleasedWhenClosed = false`
  /// has to be retained by someone, and the fixture lives in another file.
  var previewWindow: NSWindow?
  ```

- Symptoms: `startPreview` moved wholesale into `App/PreviewScenarios.swift`, but **the window it
  creates is still held by the engine** — because `isReleasedWhenClosed = false` means somebody
  always has to retain it. So "the engine holds no UI object" holds only for the project's own types
  under `UI/`, not for AppKit.
- Basis: the Clean Architecture dependency rule. Both checks used to verify round one **happened to
  miss this class**: "enumerate the 28 types in `UI/` and search inside `Core/`" cannot find
  `NSWindow` (it belongs to AppKit), and "`Core/` `-typecheck`s independently" cannot find it either
  (AppKit is an SDK, not a UI file of this project).
- Why it is not a small thing: the comment says the dependency was **forced by a memory-management
  detail — who retains the window** — rather than chosen by design. That is, the way to remove it
  is not architectural but fixture-level.
- Suggestion: let the fixture retain the window itself. `PreviewScenarios.swift:132` is the only
  write point and **has no read point at all** — its sole purpose is keeping the object alive. Put
  a `private nonisolated(unsafe) static var retainedWindow: NSWindow?` in the fixture file (or a
  `PreviewWindowKeeper` value type) and this line in the engine can go. Zero behaviour change, and
  the compile-time dependency genuinely breaks.

- **What was actually done**: the engine's two lines (comment + property) were deleted;
  `App/PreviewScenarios.swift` gained
  `private final class PreviewWindowOwner { static let shared = …; var window: NSWindow? }`, and the
  write point became `PreviewWindowOwner.shared.window = window`.
  **The suggested `nonisolated(unsafe) static var` was not used** — that is exactly the suppression
  this project has decided to reserve for the signal handlers (see MEMORY.md), while a proper
  solution exists here that needs no lock at all: default isolation *is* MainActor, and a
  `@MainActor` class (what you get by default) plus an immutable `static let` singleton
  **type-checks**, with no suppression needed. Structural correctness beats suppression, and that is
  what was done here.

- **The AppKit picture inside Core afterwards** (scanning all of `Core/` by "kind of behaviour", 27
  sites): **`NSWindow`/`NSView`/`NSViewController`/`NSHostingView`/`NSPanel` are all at zero**.
  What remains is 25 `NSWorkspace` sites (a system-level service façade: querying running apps,
  `notificationCenter`, opening URLs) plus 2 `NSApplication` sites (a notification-name constant, and
  the `isActive` read closure installed by `CrashReporter`'s `@MainActor install()`). **Holding
  `NSWorkspace.shared` is not holding a UI object** — it is a system service the AX/app-context layer
  has to use; `NSImage`/`CGRect`/`NSColor`/`NSScreen` are data types, exempted by this re-review.
- Acceptance: `Core/` `-typecheck`s independently with 0 diagnostics; Debug and Release both 0
  errors 0 warnings; **the `settings` preview was run specifically** (the very path in question), and
  the window is created and renders (`settings-0.json` = 680×600 / "Kaname Settings", matching the
  size the code requested — had retention broke, the window would be released before layout);
  the `panel` preview reports `app=57 system=79 page=1/6 rows=24`, identical to the baseline.

### N2 (P1)　✅ Fixed (`f0a74b8`)　`Core/Pure` held a locked global mutable cache, and the lock contradicted `nonisolated(unsafe)`

- Location: `Core/Pure/LogRotationPolicy.swift:29-45`

  ```swift
  private static let formatterLock = NSLock()
  /// ... `nonisolated(unsafe)` says so where the compiler can see it;
  /// the lock below is what makes it true.
  nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

  private static func formatter(for timeZone: TimeZone) -> DateFormatter {
      formatterLock.lock()
      defer { formatterLock.unlock() }
      ...
  }
  ```

- Symptoms (three, each worse than the last):
  1. **Layer violation**: `Core/Pure` is defined as "pure decisions that can be unit tested". The
     file's other four functions (`fileName`, `date(fromFileName:)`, `shouldRollover`,
     `filesToPrune`) are all pure, and `formatter(for:)` alone is a process-wide cache shared across
     calls. A pure policy and a global singleton welded into one `enum`.
  2. **Dependency injection bypassed**: the file header proudly says "`now` is injected and the time
     zone is a parameter, so the tests can pin it" — but the `formatter` cache is implicitly global,
     so tests are not isolated from each other.
  3. **`nonisolated(unsafe)` contradicts the lock**: `nonisolated(unsafe)` means "no lock protects
     this state" (which is the legitimate reason for its 17 uses in `CrashReporter`'s signal
     handlers). Here there **is** a lock. So its only real effect is **switching off compiler
     checking**: from now on any access to `formatters` without the lock compiles happily. The lock's
     contract degrades from "verifiable by the compiler" to "written in a comment".
  4. An attached style problem: the project's convention is `withLock` only, never a
     `lock()/defer { unlock() }` pair (the reasoning being that one missed unlock is a deadlock).
     LogRotationPolicy was the **only** hand-rolled pair in the Pure layer.
     > **Correction (batch C re-check)**: round two's claim of "the only hand-rolled pair in the
     > project" is wrong — the same class of error as N5: counting an identifier and drawing a
     > conclusion without verifying. Measured, the project has **15** hand-rolled `lock()/unlock()`
     > pairs (`RingBuffer` 5, `CatalogLoader` 4, `Diag` 4, `KeyboardMonitor`'s `withLock` definition
     > 1, `LogRotationPolicy` 1). With LogRotationPolicy's pair deleted, **14** remain.
     > The weight of this point therefore drops: it is no longer "the only exception" but "the one
     > among the 15 that also wears `nonisolated(unsafe)`" — the real problem is still point 3 above.
     > Along the way `Diag.configure` was found to be the **only one of those 14 without a `defer`**
     > (the other three in that file have one), and it was fixed this round.
- Basis: Clean Architecture (no mutable shared state in the inner layer); Pragmatic Programmer,
  "don't rely on coincidence".
- Suggestion (in order of preference):
  1. **Delete the cache rather than repair it.** Its entire reason to exist is formatting
     `yyyy-MM-dd`, and the same file's `filesToPrune` already uses `calendar.dateComponents`.
     Build the file name from zero-padded integers and the lock, the cache and the
     `nonisolated(unsafe)` all disappear together, restoring the Pure layer.
  2. If a `DateFormatter` must stay, fold it into an immutable `State` box the way `Diag.State` does,
     use `withLock`, and drop `nonisolated(unsafe)`.

- **What was actually done**: option 1. The lock, the `formatters` cache and `formatter(for:)` were
  deleted, replaced by two pure functions, `dayStamp(for:timeZone:)` and
  `date(fromDayStamp:timeZone:)` — `calendar.dateComponents` for the integers, then
  `String(format: "%04d-%02d-%02d")`, matching the route `filesToPrune` in the same file already
  takes. `fileName(for:)` now calls `dayStamp`, `date(fromFileName:)` calls `date(fromDayStamp:)`,
  and the two are exact inverses.
  `date(fromDayStamp:)` additionally does one **read-back check** (take the split year/month/day,
  ask the calendar again, return `nil` on mismatch): building the string by hand has no
  `DateFormatter` to reject `2026-02-31` for us, and the read-back is the only thing that stops it.
  Two tests were added (zero padding, and "a non-existent day is rejected"), 537 → 539.
  The Pure layer is free of shared mutable state again; `nonisolated(unsafe)` remains in the project
  only at the 17 sites in `CrashReporter`.

### N3 (P1)　✅ Fixed (`9334117`)　`KeyEventRouter.route`: 80 lines of code plus 10 parameters, in the Pure layer, already with 23 tests

- Location: `Core/Pure/KeyEventRouter.swift:67-173` (after the split, `route` is 16 lines)
- Measured: 107 lines = **80 lines of code** + 18 comment lines + 9 blank. It was not inflated by
  comments; it was genuinely long.
- Symptoms: two R2 smells stacked on one function — *Long Function* + *Long Parameter List* (the
  most parameters in the project). The 10 parameters fall naturally into four groups, and the body
  walks a decision chain in exactly that order:

  | Group | Parameters | Corresponding body segment |
  |---|---|---|
  | Event | `keyCode` `key` `modifiers` `isRepeat` | throughout |
  | App state | `phase` `settings` | global hotkey decision |
  | Panel state | `panel` `prefix` `pending` | navigation/row keys/⌫/chord |
  | Data | `items` | chord resolution |
- Basis: R2 *Long Parameter List* → *Introduce Parameter Object*; *Long Function* → *Extract
  Function*.
- Why this was the next thing that most needed doing: it sits in **the Pure layer** (a split carries
  zero runtime risk) and `KeyEventRouterTests` already backs it with **23 tests** — the only long
  function in the project with a test net behind it. By contrast `startPreview` (149 lines) is a
  screenshot fixture, and `CatalogLoader.scan` (81 lines) sits in the AX layer with no tests.
- Suggestion: gather the three "panel state" parameters into an object (`panel`/`prefix`/`pending`
  are three faces of one thing); cut the body along its existing order into
  `routeHotkey` → `routePanelKey` → `routeStroke`. **The order must be preserved item by item** —
  the comment above the function states plainly that "order matters: when two hotkeys share the same
  chord, the one asked first answers", and `HotkeyChoice`'s declaration order is load-bearing too.

- **What was actually done (`9334117`)**: `route` went from 107 lines to **16**. The 10 parameters
  were split by "two things", not by the four groups: ① `keyCode`/`key`/`modifiers`/`isRepeat` are
  just `KeyEvent`'s fields and the engine already holds that object, so pass it (Preserve Whole
  Object; no new type needed); ② the other six are read from `EngineState` every time and **all four
  function signatures in this file need the same set**, so they became `RoutingContext`.
  **Whether a parameter group deserves a type is judged by "does this group cross several
  signatures"** — if it appears once, it does not.
  The body was cut into three: `routeActiveKey` 25 → `ownedKey` 54 → `composedStroke` 27, order
  preserved item by item. `ownedKey` stays at 54 lines: about 20 of them are load-bearing comments
  and the rest is one five-question chain that reads better whole than cut.

- **⚠️ A Swift trap stepped on during the split, caught by a test, worth recording
  separately**: `ownedKey` initially returned `KeyDownAction?`, and `KeyDownAction` **has its own
  `case none`**. Inside a function returning Optional, a bare `.none` compiles as
  **`Optional.none`** ("this key is not the panel's, carry on") rather than
  `Optional.some(.none)` ("the panel takes this key and the answer is: do nothing"). **It compiles,
  it runs**, and it warns only inside a ternary — `return .none` does not warn at all. The
  consequence was that a top-level ⌫ silently went from a terminal branch to falling through into
  chord composition, pinned exactly by `testBackspaceAtTopLevelIsIgnored`.
  The fix is not writing `KeyDownAction.none` in full (that repairs one site and leaves the trap),
  but **making the two meanings impossible to spell the same way**: a private
  `enum OwnedKey { case action(KeyDownAction); case notOurs }`, where the `.action(...)` parameter
  slot is a non-Optional `KeyDownAction`, so `.none` there can only be the enum case.
  The whole project was scanned for the same shape: 6 types declare `case none`, and **no other
  function** writes a bare `.none` in an Optional return.
- Acceptance: all 537 tests green (including this router's 23 characterisation tests); `Core/`
  `-typecheck`s independently with 0 diagnostics; the panel preview's
  `app=57 system=79 page=1/6 rows=24` is identical to before the split; the search preview's
  `items=136 results=136 first=Cut` is the same and the screenshot is **exactly 78,474 bytes**,
  identical.

### N4 (P1)　✅ Fixed (batch D)　P0-4 leftover: diagnostics export failed **completely silently**, while writing a file in the same function popped a notice

- Location: `UI/Settings/SettingsView.swift:1019-1026`

  ```swift
  private func exportDiagnostics() {
      guard let data = engine.diagnosticsReport() else { return }        // serialization failed: nothing happens
      guard let url = ExportPanel.run(...) else { return }
      do { try data.write(to: url, options: [.atomic]) }
      catch { engine.showHUD(chord: "!", title: error.localizedDescription) }  // write failed: HUD
  }
  ```

- Symptoms: the user clicks "export diagnostics" and if JSON serialisation fails, **the button
  appears to do nothing**. Yet writing the file, immediately next to it, pops a HUD. Within one
  six-line function, two failures are handled in opposite ways.
- Why it fails: `ShortcutEngine.diagnosticsReport()`'s return value is
  `try? JSONSerialization.data(withJSONObject:)` (`:2528`), with two more `try?` inside.
  An unserialisable value mixed into `[String: Any]` makes the whole thing nil.
- This is exactly round one's P0-4 wording: "diagnosability fails silently exactly when it is
  needed".
- Basis: Clean Code, "don't swallow errors".
- Suggestion: make `diagnosticsReport()` `throws` and have each of the three `try?` explain its
  failure; the caller reuses the existing `catch` branch to pop the HUD. Only after this does P0-4
  truly close.

- **What was actually done** (one caller more than suggested — see below):
  1. `diagnosticsReport()` → `throws -> Data`. **The three `try?` each went where they belong**:
     - `JSONSerialization.data(withJSONObject: payload)` became a `try` that propagates — if the
       report itself cannot be serialised there is no report, and the caller has to know.
     - The two settings-snapshot ones (`JSONEncoder().encode` + `jsonObject(with:)`) went into one
       `do/catch`, and on failure the reason goes into the report: **`payload["settingsError"]`**.
       That segment is **added value, not a requirement** — a report without settings is still worth
       attaching, so it must not fail the whole thing; but "silently dropping a segment" is exactly
       how a broken encoder goes unnoticed. Nothing is swallowed: the reason travels with the file.
  2. `SettingsView.exportDiagnostics()` now sends both failures down the same path (the symptom of
     this item *was* their inconsistency): `Diag.error` for the reason plus a HUD notice.
     **The HUD copy reuses `.diagnosticsExportFailed` ("Export failed: %@") already used by the other
     export path in the same file**, even the chord `!` is the same. (Almost coined a new key —
     the existing one already carries the `%@` placeholder and fits better than the new one would
     have.)
     The log line is not a duplicate of the HUD: **when this path fails no file is produced at all**,
     so the log is the only trace that survives, while the HUD disappears and leaves nothing.
  3. **`AppDelegate.writeSelfTestAndExit()` is a second caller, worse than SettingsView**: when the
     report is nil it calls `engine.stop()` + `terminate` and **exits outright, saying nothing and
     flushing nothing** — a failed self-test looked exactly like a passing one. Changed to a single
     `do/catch`: construction and writing are inside it, and exit plus flush became
     **unconditional** (the failure branch used to skip the flush).

- **Verification**: `KANAME_SELFTEST=1` is precisely the changed path and ran end to end — the log
  shows `selftest written to …/kaname-selftest.json`, the produced JSON is valid with 28 top-level
  keys, **including the `settings` segment and no `settingsError`** (the normal path).
  The settings preview screenshot is **byte-identical** to before the change (this scenario is
  deterministic, see the N6 correction).
  All 539 tests green, `Core/` type-checks independently with 0 diagnostics, `build_swiftc.sh` 0
  errors 0 warnings. The failure branch cannot be triggered automatically (it needs the save panel),
  so it was confirmed by code review only.
- **This item closes, P0-4 does not**: the `try?` swallowing real errors went from **57 to 54**
  (only these three removed). Round one's P0-4 wording was "diagnosability fails silently exactly
  when it is needed" — **that sentence is now closed**; the other 54 are spread across
  `CrashReporter` 12, `ActionRecorder` 6, `PreviewScenarios` 6, `FileLogStore` 5, `MenuScanCache` 4,
  `DiagnosticsExporter` 4, the config scanners 7, storage 3 and tests 3.
  **Note: `Core/Input` has none of them** (only 2 `try? await Task.sleep`, which drop a cancellation
  rather than an error), so round one's rule "`try?` is banned in the input path" **is already
  satisfied** — the earlier claim of "10 sites still in the input path" was wrong; those 10 were
  never in the input path.
- **One item left for round three**: `DiagnosticsExporter` (the export path behind the settings
  page's "Diagnostics" tab, a **different path** from the `diagnosticsReport()` changed here) still
  has 4 `try?` inside. Three are `try? fileManager.removeItem/createDirectory` (cleaning a staging
  directory; failure should not fail the export, and that stands), but `:93`'s
  `guard let contents = try? contentsOfDirectory(...) else { return [] }` is **the same disease as
  this item**: an unreadable directory returns an empty list, and the user gets an "empty"
  diagnostics package without knowing what is missing. It was not touched this round — fixing it
  means more than this one line, namely how that path expresses "partial success" overall.

### N5 (P2)　✅ No change needed — the verdict on this item was itself wrong: `@available(*, unavailable)` was there all along

- Location: `UI/Design/AppIconDragSource.swift:53-56`
- **Correction**: this item originally read "round one gave the right advice but nobody acted on
  it"; **that verdict is wrong**. Counting one occurrence of `fatalError` and concluding the
  attribute was missing, without reading the line. The actual code is:

  ```swift
  @available(*, unavailable)
  required init?(coder: NSCoder) {
      fatalError("init(coder:) is not used")
  }
  ```

  `git blame` shows `@available(*, unavailable)` came in with **the same commit** as the file
  (`1bf1922`), and was already present in the commit that wrote round two's report (`f492250`).
  That is, the compile-time rejection P1-10 asked for was there from the start.
- **Why `fatalError` must stay**: `required init?` is required by `NSCoding` and **must have a body**;
  it cannot be omitted in the spelling. And `@available(*, unavailable)` already makes every call
  site fail **at compile time**, so this `fatalError` is unreachable fallback, not a runtime trap.
  **This is the correct spelling; do not touch it.**
- **Lesson (this project's third instance of the same error)**: round one counted
  `.accessibilityLabel` and concluded "the settings page has no labels", when SwiftUI derives them
  from control text automatically; this round counted `try!`/`assumeIsolated` and included comments
  (see §5); and here an identifier was counted without reading the line it sits on.
  **"Quantified" is not "looked at"** — anything used as the basis for a "not done / regressed"
  verdict has to be read in the code itself.

### N6 (P2)　✅ Fixed (batch C)　Cross-file duplicate blocks — the new code had been copied out

- Locations (two real duplicates, worth acting on):
  1. **The AX value ladder written twice**: `Core/AX/MenuScanner.swift` and
     `Core/AX/WindowGeometry.swift` each had a private `attribute(name:of:)` plus typed variants
     (`pointAttribute`/`sizeAttribute`/`elementAttribute`), each the same five lines of a
     `CFGetTypeID` guard followed by `unsafeDowncast`.
  2. **The NSWorkspace observer lifecycle written twice**: `Core/AX/AppContextService.swift:28-33`
     and `Core/AX/AppDirectory.swift:19-26` both hand-maintained `observers: [NSObjectProtocol]`
     plus `start()`'s `guard observers.isEmpty` and `stop()`'s
     `observers.forEach { center.removeObserver($0) }`.
- The other four are delegate wrappers or struct literals — not duplicates, leave them.
- Basis: R2 *Duplicated Code*; Pragmatic Programmer DRY / "one fact, one source".
- **What was actually done**:
  - Added `Core/AX/AXValueReader.swift` (a `nonisolated enum`): the ladder exists once, and
    `MenuScanner`'s 13 call sites and `WindowGeometry`'s 4 were repointed to it.
    The two ladders had already **drifted**: `MenuScanner`'s had a `CFNull` guard, `WindowGeometry`'s
    did not; the guarded one was kept (a null value would have been rejected by the next type check
    anyway, so behaviour is equivalent).
    `boolAttribute` was first judged dead code (missing `MenuScanner.swift:263`) and kept after
    re-checking.
  - Added `Core/AX/WorkspaceObservation.swift` (a `@MainActor final class`): each service's `start()`
    collapsed into `guard !observation.isRunning` + `observe(...) { … }`, and `stop()` into one line.
    `MainActor.assumeIsolated` call sites therefore dropped from 3 to 1.
  - **Along the way**: `children(of:)`'s `unsafeBitCast(raw, to: CFTypeRef.self)` became
    `Unmanaged<AnyObject>.fromOpaque(slot).takeUnretainedValue()`. Same width, semantically
    equivalent, but `unsafeBitCast` reinterprets a pointer as an object reference, whereas what a
    CFArray stores *is* the object pointer itself — `Unmanaged` is the API for expressing that.
    `unsafeBitCast` is therefore at zero project-wide (leaving 6 `unsafeDowncast`).
- **Verification** (the AX layer has no test net, so only previews: `scripts/build_swiftc.sh` →
  `install.sh` → preview scenarios):
  - Log metrics identical word for word: `panel sequence: app=57 system=79 page=1/6 rows=24`,
    `search: scope=frontmost items=136 results=136 first=Cut`, `config scan: 201 shortcuts`;
    the scan still reports `menus=true, state=ok` (Safari, 182 items), showing the `children(of:)`
    rewrite did not break menu traversal.
  - Screenshots byte-identical: **the settings and search ones hold** (see the correction below).
- **⚠️ Correction: this item originally said "all three screenshots are byte-identical to before the
  change", and the panel one is not evidence.**
  The **panel screenshot is itself non-deterministic** — running the *pre-change* build
  (`Kaname.previous.app`) twice produced two different MD5s (41668162 / fd44be26, 243,112 / 242,092
  bytes). The reason is that the shot is taken 1.2 s after `activatePanel()`
  (`PreviewScenarios.swift:246`) while the panel has an entrance animation, so which frame is caught
  depends on what the machine is busy with. The `panel sequence` line in the log, however, was
  identical all three times.
  **Lesson**: the fifth instance of §5's sentence — **check whether the instrument is reliable before
  reading the number**. The three scenarios have now been classified by measurement: **settings and
  search are deterministic** (the same build run twice gives the same MD5, so byte comparison is
  usable), **panel is non-deterministic** (log metrics only). Round three should pick evidence from
  this list.
- **One thing left alone, with the reason**: `UI/MenuBar/StatusItemController.swift:120-139` also has
  an `observers` array, but it **mixes two notification centres** (`NSWorkspace`'s wake plus
  `NotificationCenter.default`'s screen-parameter change), and `uninstall()` has to remove from both.
  It is not a third copy of the same block but a different shape; folding it in would mean
  generalising `WorkspaceObservation` into "any centre + composable teardown", and neither the wake
  nor the screen-change path has preview or test coverage. **Cost exceeds benefit, so it is booked**.
- Result: Core cross-file ≥5-line duplicate blocks **8 → 4** (method in §5), and the ones that
  disappeared are exactly the two above; the 4 remaining are the four this item judged "not
  duplicates".

### N7 (P2)　One file in `Core/Pure` does `import SQLite3`

- Location: `Core/Pure/BetterTouchToolScanner.swift:2`
- Symptoms: the only file in the Pure layer depending directly on a C database API (the other four
  `import CoreGraphics` are geometry maths, acceptable). It means this "pure" scanner only means
  anything when a real BTT database exists.
- Judgement: **the cost is already paid and the gain is small**; not worth touching now (the other
  six scanners share `ConfigFileScanner`, the skeletal duplication is one 5-line block, and the
  whole is healthy). It is recorded here so that "Pure = no side effects" has an explicit exception
  list — a convention without a list gets assumed by default.

### N8 (P2)　`EngineState` holds an `NSImage` (AppKit) — a formal violation, suggested to keep

- Location: `Core/Engine/EngineState.swift:23` (`appIcon`), `:61` (`searchScopeIcon`)
- Symptoms: the engine's state struct carries a UI-framework type. The comment at `:59-60` states
  this is intentional ("icons are AppKit's and can only stay on the engine's side").
- Judgement: **not suggested to change**. The dependency rule cares about "will a UI change force
  the business rules to change" — `NSImage` is a data type, not a behaviour type, and it will not.
  Swapping it for `Data` or a port buys real complexity and no behavioural gain.
- Suggestion: leave it, but put the reasoning into that comment (it currently says only "can only
  stay on the engine's side", not "why that is safe"), so round three does not re-investigate it as
  an escaped violation.

### N9 (P3)　✅ Fixed (`8a4909e`)　The largest test file was a junk drawer

- Location: `Tests/KanameCoreTests/KanameCoreTests.swift`, **1,105 lines / 109 tests**
- Symptoms: it was named after the *target*, not after the type. Splitting it revealed it was more
  specific than originally described — not "one class testing a dozen types" but **29 `XCTestCase`
  classes stuffed in** (`KeyChordTests`, `KeyFormatterTests`, `DescriptionCleanerTests`, …
  `PanelHighlighterTests`). The other 42 test files all follow "one type, one file"; the largest one
  alone did not.
- Cost: when a test fails, the file name does not say which type broke; `KeyChord`'s tests and
  `L10n`'s crowd the same file, so touching the former means opening the latter.
- Suggestion: split by the type under test. A pure file move, zero risk, interruptible at any point —
  the ideal class of change for "do a bit whenever there is time".

- **What was actually done (`8a4909e`)**: split into 29 files, the original deleted. Committed as a
  **pure move**: the concatenated content of the 29 new classes is **SHA256-identical** to the
  original (`59cff75194207a06`), test functions 109 → 109, and the diff is 29 additions plus
  1 deletion with **0 modifications**.
  Three things made it scriptable rather than hand-moved: ① the 29 classes **reference each other
  nowhere** (confirmed by cross-searching class names first, so no shared helper had to be copied or
  hoisted); ② the file top level had only two import lines; ③ four classes' doc comments sat
  **in the gap after the previous class** rather than above their own, so they were re-attached
  semantically (menu path weighting → `MenuPathWeightTests`, disk cache freshness →
  `MenuCachePolicyTests`, panel height → `PanelSizeStabilityTests`, `BindingItem` JSON round trip →
  `MenuCacheRoundTripTests`).
- **Along the way (`e410fe5`)**: this round looked properly at `swift test`'s output for the first
  time and found **16 pre-existing warnings in the test target** (the app target has had 0 warnings
  since the Swift 6 migration, which is why they never surfaced): 13 "result of call is unused"
  (`InputMailbox.post`, `ModifierTapTracker.flagsChanged`, both deliberately discarding the result in
  tests, where `_ =` is honest rather than suppression) plus 3 "variable was never mutated" (changed
  to `let`). The test build is now 0 warnings too. The reason it was worth doing is not tidiness
  alone: round two had just corrected four of round one's metrics, and a warning-free test build is
  a stable baseline for the next round's "did it get worse".

### N10 (P2)　P2-14 / P2-15 / P2-16 not done, and P2-14's verdict deserves revising

- **P2-14 hit areas**: `.contentShape` is still 7 sites, unchanged from the baseline. But round
  one's advice (44×44 pt) **does not apply to this project's primary surface**: the panel is a
  launcher-style dense list with a row height of **30 pt** (`OverlayMetrics.rowHeight`, from which
  `Theme.rowHeight` derives), and blowing the favourite star up to 44 pt would destroy the
  information density the product rests on.
  Measured, `OverlayView.swift:724-748`'s star is 14×14 plus `.contentShape(Rectangle())`, i.e. it
  is already tappable across 14 pt (transparent area included), and **the star also appears when a
  row is selected by keyboard**, so keyboard users can reach it.
  → Suggested revision: dense panels do not get 44 pt; that rule holds only for standard surfaces
  such as the settings window, and the settings window uses text buttons.
- **P2-15 Observation**: `ObservableObject` 10 sites, `@Observable` 0, untouched.
  One key press in `EngineState` changes several `@Published` values, so pointless refreshes are
  indeed being paid for. An optional optimisation; not doing it is not a debt.
- **P2-16 fixed sizes**: `.frame(width:/height:)` 41 sites unchanged, 9 of them on the settings
  window. The truncation risk under long localised copy remains, but it falls under "wait until it
  actually happens" — the Chinese and English sets are both complete (`L10n` 851 lines) and no
  truncation has been observed.

---

## 2. Corrections to round one's metric conventions (so round three does not step in them again)

Four of round one's numbers were wrong, and each would mislead the "did it get worse" judgement:

| Round one wrote | Measured | Impact |
|---|---|---|
| "201 Swift files" | Baseline `bd8b926` is **169 `.swift` files** (126 app + 42 test + Package.swift); 217 is the count of all tracked files | The base was off by 32, making "scale growth" unjudgeable |
| "P2-13: 1 `accessibilityLabel` on the settings page" | Of the settings page's 59 controls, 11 are `Toggle`s all written `Toggle(localization.text(...), isOn:)` and 26 of 27 `Button`s carry text — **SwiftUI derives labels from text automatically** | The real gap was one icon button and one decorative icon, fixed in `8586235`. Measured by "label count" you get the opposite conclusion |
| "P2-11: `KeyboardMonitor` is close to half comments" | Measured **27.8%** (188/677), and the incident chronology is compressed to one line (`:27`, citing the date as evidence, a legitimate "why") | This was never a problem |
| "P3-17: tests cover pure logic only" | Now 537 tests / 43 files — coverage has indeed improved a lot, but **the engine and input layer themselves** still have none | The wording needs precision: what is missing is "tests of the engine/input layer", not "too few tests" |

One more methodological lesson: round one verified P0-1 with "enumerate the types in `UI/` and search
inside `Core/`", a check that **cannot find AppKit types**, which is how N1's `NSWindow` slipped
through.
When round three verifies the dependency direction, the checklist must explicitly include AppKit's
**behaviour** types (`NSWindow` / `NSView` / `NSViewController` / `NSHostingView` / SwiftUI's `View`),
while data types (`NSImage` / `NSColor` / `CGRect`) may be exempted with that exemption written down.

---

## 3. Principle mapping (this round)

| Finding | R2 | Clean Code / Architecture | Pragmatic / Swift 6 / HIG |
|---|---|---|---|
| N1 engine holds an NSWindow | — | dependency rule (formal violation: AppKit was not on the checklist) | — |
| N2 mutable cache in the Pure layer | *Mutable Data* | dependency rule (no shared mutable state in the inner layer) | Migrating to Swift 6: `nonisolated(unsafe)` only for state no lock can protect |
| N3 route: long function + 10 parameters | *Long Function* + *Long Parameter List* | a function does one thing | — |
| N4 silent failure | — | don't swallow errors | crash observability |
| N5 fatalError | — | compile-time rejection instead of a runtime trap | — |
| N6 duplicate blocks 2→6 | *Duplicated Code* | DRY | one fact, one source; "broken windows" |
| N8 EngineState's NSImage | — | dependency rule (formal violation, but cost > benefit) | — |
| N9 test junk drawer | — | test organisation should mirror the unit under test | — |
| N10 44 pt hit areas | — | — | HIG: 44 pt does not apply to a dense launcher surface |

---

## 4. Suggested next batches (increasing risk, each independently revertible)

**Batch A (zero risk, with a test net)**　✅ **Done**: `9334117` + `8a4909e` + `e410fe5`
N3 split `KeyEventRouter.route` (Pure, backed by 23 tests) → N9 split `KanameCoreTests` (a pure file
move) → and the test build's 16 pre-existing warnings cleared. (Details in the "what was actually
done" of N3 / N9.)

**Batch B (zero behaviour change, compile-time gain)**　✅ **Done**
N1 moved `previewWindow` back into the fixture — that line is gone from the engine, and AppKit
**behaviour types** in `Core/` are at zero (leaving only `NSWorkspace` system services, see N1).
N5 needed **no change** after verification: `@available(*, unavailable)` was there all along, and
`fatalError` is the unreachable fallback a `required init?` must have (see the N5 correction).

**Batch C (small extractions, needing preview verification)**　✅ **Done**
N2 deleted `LogRotationPolicy`'s formatter cache (building file names from zero-padded integers,
`f0a74b8`) → N6 extracted `AXValueReader` and `WorkspaceObservation`. Verification as in the N6
item: the three preview screenshots **byte-identical** to before, log metrics word-identical.
Outside the batch, `Diag.configure`'s missing `defer` was fixed.

**Batch D (closing)**　✅ **Done**
N4 made `diagnosticsReport()` throw and both callers report failure visibly — round one's P0-4 line
"diagnosability fails silently" is closed. **Note this is not all of P0-4**: `try?` sites swallowing
real errors still number 54 (`CrashReporter` 12 leading; `Core/Input` zero), untouched this round.
`DiagnosticsExporter`, a sibling path, has one more instance of the same problem, recorded in the N4
item for round three.

**Suggested not to do**: N8 (`EngineState`'s `NSImage`), the 44 pt part of N10, and P2-15's
Observation migration. All three are "cleaner if changed but no behavioural gain"; book them.

**The large item still unresolved**: P1-5, the engine God class (2,530 lines / 19 sections). It
weighs more than any item above, but is also the least suited to a series of small batches — it
needs one dedicated split design, and deserves a round of its own.
→ **That design is written, see `docs/en/engine-split-design.md`; the diagnosis has been corrected and
slice 1 is done, see §6.**

---

## 5. Quantitative baseline (for round three to compare against)

### 5.1 After batches B+C (same script re-run: app + tests, comments stripped first)

Comparable only once the conventions are unified: **the right two columns come from
`scripts/code-metrics.py` run over two commit trees**, while the first three columns are each
round's own hand tallied numbers — **do not subtract across conventions**.

```
python3 scripts/code-metrics.py .                              # the current working tree
git archive e410fe5 | tar -x -C /tmp/tree-A
python3 scripts/code-metrics.py /tmp/tree-A                    # any historical commit
```

| Metric | After batch A, `e410fe5` | After batches B+C | Change | Note |
|---|---|---|---|---|
| App files / lines | 129 / 21,485 | **131 / 21,558** | +2 / +73 | Added `AXValueReader`, `WorkspaceObservation` |
| Test files / lines | 71 / 6,090 | **71 / 6,104** | +14 | N2 added 2 `dayStamp` tests |
| `Core/` file count | 111 | **113** | +2 | Both new types live in `Core/AX/` |
| Test count | 537 | **539** | +2 | All green; test build 0 warnings |
| Functions over 80 lines | 2 | **2** | — | Still `startPreview` 149 / `CatalogLoader.scan` 81 |
| Largest file | `ShortcutEngine` 2,529 | **2,526** | −3 | Still 19 MARK sections (P1-5 untouched) |
| **Core cross-file ≥5-line duplicate blocks** | 8 (re-measured) | **4** ✅ | −4 | N6; exactly the two real duplicates disappeared (see N6) |
| `MainActor.assumeIsolated` | 24 | **22** | −2 | N6: 3 hand-written → 1 in `WorkspaceObservation` |
| `nonisolated(unsafe)` | 18 (re-measured) | **17** | −1 | N2; the remaining 17 are all in `CrashReporter` (signal handlers, legitimate) |
| `unsafeBitCast` | 1 | **0** ✅ | −1 | N6 along the way; only 6 `unsafeDowncast` left |
| `lock()` / `unlock()` | 15 / 15 | **14 / 14** | −1 | N2; plus `Diag.configure`'s missing `defer` fixed |
| `try?` | **62** (re-measured, convention fixed) | **62** | — | See the `try?` count correction below; **57 swallow real errors** (the other 5 are `try? await Task.sleep`) |
| `try!` | 3 (re-measured) | **3** | — | All 3 are in tests, 0 in app code (see the convention note below) |
| `@unchecked Sendable` | 6 (re-measured) | **6** | — | Each has a lock or serial queue, contract in a comment |
| `ObservableObject` / `@Observable` | 10 / 0 | **10 / 0** | — | Untouched (P2-15 suggested not doing) |
| `.contentShape` | 7 | **7** | — | Untouched (see N10) |
| `.frame(width:/height:)` | 41 | **41** | — | Untouched |

### 5.2 After batch D (same script, only what changed)

| Metric | After batches B+C | After batch D | Change | Note |
|---|---|---|---|---|
| App files / lines | 131 / 21,558 | **131 / 21,573** | +15 | N4 changed 4 files (engine/settings/AppDelegate/no additions) |
| Largest file | `ShortcutEngine` 2,526 | **2,533** | +7 | `diagnosticsReport()` gained a `do/catch` and comments |
| `try?` | 62 | **59** | −3 | N4: the three `try?` in `diagnosticsReport()` are gone |
| ├ swallowing real errors | 57 | **54** | −3 | **this is the number P0-4 actually cares about** |
| └ `try? await Task.sleep` | 5 | **5** | — | drops a cancellation, not an error; not counted |

### 5.3 After round three (same script over two trees: `80ac2cd` → working tree)

| Metric | Before round three, `80ac2cd` | After round three | Change | Note |
|---|---|---|---|---|
| App files / lines | 131 / 21,573 | **133 / 21,753** | +2 / +180 | Added `DiagnosticsReportBuilder`(100) + `ScanState`(30) − engine(−20) − `MenuScanner`(−25) |
| Test files / lines | 71 / 6,104 | **72 / 6,216** | +1 / +112 | 6 tests in `DiagnosticsReportBuilderTests` |
| Core files | 113 | **115** | +2 | The same two new files |
| Largest file | `ShortcutEngine` 2,533 | **2,513** | −20 | Slice 1 (see §6 and the design document) |
| Functions over 80 lines | 2 | **2** | — | **0** inside the engine (134 functions, median 8 lines, longest 57) |
| `try?` total | 59 | **56** | −3 | |
| ├ swallowing real errors | 54 | **51** | −3 | **this is the number P0-4 actually cares about.** Checked file by file: all −3 come from **N11** (`DiagnosticsExporter` 4 → 1). N13 swapped one `try?` for another (net 0) and its point is not the count; slice 1 contributed 0. |
| └ `try? await Task.sleep` | 5 | **5** | — | drops a cancellation, not an error; not counted |
| `try!` | 3 | **3** | — | **All in tests** (`MenuCacheRoundTripTests` 2, `LocalizationTests` 1), app code **0**. |
| | | | | `try!` in tests is legitimate: a failed construction should crash that test rather than pass silently. The earlier "`try!` = 0" counted **app code only**. |

### 5.4 The first two rounds' original records (different conventions, for provenance only)

| Metric | Round one baseline `bd8b926` | Round two `83a1b03` | After batch A |
|---|---|---|---|
| App files / lines | 126 / 20,542 | 129 / 21,431 | 129 / 21,485 |
| Test files / lines | 42 / 5,857 | 43 / 6,028 | 71 / 6,090 |
| Functions over 80 lines | 9 | 3 | 2 |
| Largest file | `ShortcutEngine` 2,775 | 2,530 | 2,529 |
| Test build warnings | — | 16 | 0 |
| Core cross-file 5-line duplicate blocks | 2 | 6 | 6 |
| `try?` | 64 | 59 | 59 |
| `accessibilityHint` | 0 | 0 | 0 |

**The account of the two convention gaps**: round two wrote `nonisolated(unsafe)` = 23
(CrashReporter 20 + LogRotationPolicy 2 + UI 1), while the same script re-measuring `e410fe5` gives
18 (CrashReporter 17 + LogRotationPolicy 1); `try?` 59 vs 65 and `try!` 0 vs 3 likewise. The
difference is the file set (tests included or not) and whether comments were stripped.
**Do not subtract the first two rounds' numbers from the table in 5.1**; either re-measure with the
script, or compare only within one table.

**Counting conventions (so round three does not step in them again)**: this round's `try!` count came
out as 2 and `assumeIsolated` as 29, and for a moment both looked like regressions.
The regex had counted **mentions inside comments** — those 2 `try!` are `Sanitizer.swift:78-79`
explaining "why `try!` is not used here", and 5 of the 29 `assumeIsolated` were comments.
**Code-smell counting must strip inline comments first** (match after
`re.sub(r'//.*$', '', line)`), or every round will magically "get worse" by a few items. This is
exactly the class of error §2 is trying to prevent, and the report's own author stepped in it.

**"Quantified" is not "looked at"**: N5 (thinking `fatalError` was unhandled) and N2's "the only
hand-rolled pair" were both written by counting an identifier and concluding without reading the
code. Anything used for a "not done / regressed / only one place" verdict must be read on that line
first; `scripts/code-metrics.py` produces a to-check list, not a conclusion.

**Regexes bite too (this round's fifth and sixth instances)**:
- The `try?` regex `try\?` counts the substring `try?` inside **`monitorRetry?.cancel()`**
  (`Re` + `try?`). It must be `\btry\?`. After the fix batch A's number went from 65 to 62.
- `try? await Task.sleep(...)` is not the same thing as "swallowing an error": `Task.sleep` throws
  only on cancellation, and dropping that is syntactic noise, **not the "swallowed error" P0-4 talks
  about**. So the script lists it separately, and P0-4's progress is read from "the 54 sites that
  swallow real errors", not from 59.

**Check whether the instrument is reliable before reading the number (this round's seventh instance,
and the most expensive)**: at one point this round treated "the three preview screenshots are
byte-identical to before" as the strongest equivalence evidence. **The panel one is not evidence** —
running the pre-change build twice produced two different MD5s (the shot is taken 1.2 s before the
entrance animation ends, see the N6 correction).
All three scenarios are now measured: **settings and search are deterministic** (the same build run
twice gives the same MD5, so byte comparison works), **panel is non-deterministic** (log metrics
only). Likewise, before using a screenshot for an equivalence judgement, run **the same build** twice
and see whether it matches itself.

| `SWIFT_VERSION` | 5.0 | **6.0 + `complete`** | 0 diagnostics on all three paths, 539 tests pass |
| `Core/` independent `-typecheck` | Failed | **Passes (0 diagnostics)** | 113 files; but measured against its own UI types, which misses AppKit (see N1) |

---

## 6. Round three (continued 2026-11-03)

One item batch D left behind, plus three silent failures found while walking the `try?` list, plus
P1-5's re-grading.

### N11 (P1)　✅ Fixed (`570bb22`)　N4's sibling path: an incomplete diagnostics archive does not say what it is missing

- Location: `Core/Services/DiagnosticsExporter.swift:93` (`copyContents`)
- Symptoms: `guard let contents = try? contentsOfDirectory(...) else { return [] }` — an unreadable
  log directory returns an empty list. The user gets a diagnostics package with no logs, looking
  exactly like "this app simply has no logs". One layer down there is the same hole: `copyItem`
  failing `continue`s, so a single file disappears silently.
- Basis: Clean Code, "don't swallow errors"; the same disease as N4 (N4 booked it as "left for round
  three").
- **What was done**: `copyContents` now returns a `FolderCopy` (`copied` / `skipped` / `failure`), and
  `SessionInfo` gained `logFilesError` / `crashFilesError`, following N4's `settingsError` convention
  — partial success is still worth attaching, so it does not fail the export, but the reason travels
  with the file.
  Along the way the destination's `try? removeItem` became `try` + `catch CocoaError.fileNoSuchFile`:
  a stale file that cannot be cleared should say so, rather than letting `ditto` run into an
  unprepared destination.
- **Verification (all three paths used real filesystem failures, not stubs)**: `chmod 000` on the log
  directory → `logFilesError = "folder could not be listed: …"`; `chmod 000` on a single file →
  `logFilesError = "kaname-2026-11-02.log: …"`; normal → 2 files, both error fields absent.
- **An incidental finding that decided where the reason has to go**: the run with an unreadable
  directory **left not one line in the log** (`FileLogStore` writes to the same directory).
  **This is precisely the failure mode that takes the log away with it**, so the reason must go into
  the JSON report and cannot live in the log alone. That is not belt and braces; it is the only
  channel still alive.

### N12 (P1)　✅ Fixed (`2423860`)　When the redaction rules fail silently, nothing finds out

- Location: `Core/Pure/Sanitizer.swift:85-90`
- Symptoms: `Sanitizer.failedPatterns` exists, gets populated, and is asserted empty by
  `SanitizerRuleCompilationTests.testEveryRuleCompiles` — but **no code anywhere in the project reads
  it**. The comment claims "the diagnostics export surfaces it", which is false, and the symbol name
  it mentions, `rulesThatFailedToCompile`, **does not exist at all**.
  So the real failure mode is: one regex written wrong → that redaction rule silently stops applying
  → the log lands on disk carrying what should have been erased (and leaves the machine inside the
  diagnostics package), while the only witness is a test that ran long ago against another build.
- This is the round's only **safety-related** finding, and the only one where "the mechanism is all
  there but nobody wired it up".
- **What was done**: wired into three channels, because each closes a gap the others leave — the
  archived `session-info.json` (the only thing that leaves the machine and outlives this session),
  the in-app report's `sanitizerFailedPatterns`, and one `W [start]` line at launch (the report only
  exists if someone thinks of exporting). The comment's symbol name and its false claim were fixed
  at the same time.
- **Verification**: deliberately broke one regex (`\b[0-9a-fA-F]{32,}\b(`) and **actually installed
  that build**, getting `W [start] redaction rules not applied: …`, with
  `["\\b[0-9a-fA-F]{32,}\\b("]` in the report, and `testEveryRuleCompiles` reporting the same
  pattern. The regex was restored; the warning disappeared and the field returned to `[]`.

### N13 (P1)　✅ Fixed (`2800947`)　The file a crash leaves behind lies by omission

- Location one: `Core/Pure/CrashLogFormatter.swift:91` — the fallback `return "{}"`, described by its
  comment as a dead path ("this struct is fully Codable with value types"). **It is not dead**:
  `occurredAt` is a `Double`, and `JSONEncoder`'s default policy for non-finite floats is `.throw`,
  so one NaN date triggers it. `{}` parses, looks complete, and says nothing — a reader will assume
  this crash simply carried no information.
  → Changed to return valid JSON stating the reason for the failure (generated through
  `JSONSerialization`, so the reason is escaped rather than concatenated), with a test:
  `Date(timeIntervalSince1970: .nan)` triggers it and would fail against `"{}"`.
- Location two: `Core/Services/CrashReporter.swift:317` — `catch { // Nothing left to fall back to }`,
  while **50 lines further down the same file** (`:358`) already records `Diag.warning` for the same
  failure. The stated reason is "this runs in the uncaught-exception handler", but `handleException`
  calls `logs.flushNow` immediately after — so a log line written here **does reach disk**. By not
  recording it, the app swallows both the exception and the fact that it swallowed one.
- Basis: Clean Code, "don't swallow errors"; two opposite treatments inside one file are a signal in
  themselves.

### P1-5 re-graded: the symptom is real, the prescription does not hold

The re-review wrote "engine God class (2,530 lines / 19 sections), needs one dedicated split
design". That design is written in **`docs/en/engine-split-design.md`**, and its conclusion is:

| | What the re-review wrote | What was measured (`2800947`) |
|---|---|---|
| Symptom | 2,530 lines / 19 sections | The line count holds; 70% of the 2,536 lines is code |
| Diagnosis | God class (does too many things) | **A coordinator**: 134 functions, median 8 lines, longest 57, **0 over 80 lines** |
| Prescription | Extract Class by section | Does not hold for the four sections holding 47% of the code |

The key numbers: of the 19 sections only **5 `EngineState` fields** and **6 verbs** are shared;
sections barely talk to each other, they all talk only to this small core. Move those four sections
into new files and the new files still read and write the same fields — **lines move, coupling does
not**.

The real defect is **the nature of the boundary**: the 19 MARK sections are a commenting convention,
not a structure, and `private` provides no isolation inside this class.

- **Done (`c336096` + `8469003`)**: slice 1 = the `Diagnostics` section — the only row in the whole
  table with `state.` writes = 0, so moving it structurally cannot change behaviour. Assembly went
  into `Core/Pure/DiagnosticsReportBuilder` (a 22-field `Input`), and the engine keeps only "naming
  these values". **The point is not the 23 lines that left the engine but that this path could
  previously only be verified end to end and now has 6 unit tests.** Quantified equivalence: the
  self-test JSON is still 29 keys with none added or dropped, the settings screenshot is
  byte-identical, the panel metrics are word-identical. 546 tests (+6).
- **Along the way (`c336096`)**: `ScanState` moved from `Core/AX/MenuScanner.swift` to `Core/Pure`.
  It is referenced by bare name from 5 files across layers, and living in the producer file made
  every reader depend on that file; more importantly — **the test target compiles only `Core/Pure`
  (`Package.swift:13`)**, so in its original position it could never get a unit test no matter how
  pure it is. That boundary was only discovered this round; see §7 of the design document.
- **Not done**: the order and criteria for the other 18 sections are in §5 of the design document;
  the precondition is narrowing the shared core first (`prefix` / `phase` / `pending`), otherwise
  moving those four sections just yields four new files that reference each other.
