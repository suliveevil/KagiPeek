# Kaname code review (round four)

[English](code-review-2026-11-03.md) · [中文](../zh-CN/code-review-2026-11-03.md)


- Review date: 2026-11-03
- Repository: `/Users/suliveevil/Documents/GitHub/Kaname`
- Working tree at start: clean (HEAD `3b140a1`)
- References: *macOS Apprentice*, 3rd edition; Apple Human Interface Guidelines (macOS);
  *Clean Code*; *Clean Architecture*; *The Pragmatic Programmer*; *Migrating to Swift 6*
- Prior documents: `docs/en/code-review-2026-11-02.md`, `docs/en/code-review-2026-11-02-round2.md`,
  `docs/en/engine-split-design.md`, `docs/en/ARCHITECTURE.md`

---

## 1. Executive summary

Kaname has been through three rounds of review and continuous refactoring, and is now **a Swift 6
project of markedly higher quality than comparable macOS tools**: clear layering, a correct
dependency direction, concurrency isolated in ways the compiler can verify, pure logic that can be
unit tested, comments explaining "why" rather than "what". This round does not repeat the
conclusions the previous three rounds closed; after an independent close reading of the whole
repository it focuses on **the real duplication that remains and one user path with zero tests**, and
lands three behaviour-preserving refactors.

Results (all verified by building and testing):

- Cross-file duplicate blocks in the Core layer (`scripts/code-metrics.py` convention, ≥5 lines) fell
  from **4 to 2**; the 2 remaining were verified as reasonable (see §6.1).
- Tests went from **546 to 557** (11 added), `swift test` with 0 failures; the app target
  `xcodebuild` reports **BUILD SUCCEEDED** with zero code warnings.
- Search-field keyboard navigation — a path previously buried in a UI event monitor with **no tests
  at all** — had its decisions extracted into a pure, testable `SearchKeyRouter`.

Confidence grading follows the prior documents: `confirmed` (proved directly by source or runtime),
`inferred` (inferred from multiple pieces of evidence), `unknown` (no evidence obtained). Every
factual statement in this round's body is `confirmed` unless marked otherwise.

---

## 2. This round's positioning and methodology

The previous three rounds already covered systematically: dependency direction, Swift 6 concurrency
isolation, error swallowing (`try?`), the God class re-diagnosis, UI detail and accessibility. To
avoid "covering a small increment with a lot of length", this round applies the same discipline as
the prior documents:

1. **Read the code before judging**; never substitute a document's conclusion for source
   verification;
2. Every number comes from `scripts/code-metrics.py` or real `swift test`/`xcodebuild` output, with
   conventions exactly matching the prior documents;
3. Change only what can preserve behaviour and has a test safety net; for anything touching
   behavioural semantics, enumerate the net behaviour in full first, then refactor, and pin it with
   tests;
4. Actively look for a counter-example to every suspected issue (the prior documents stress
   repeatedly that "quantified is not looked at"). This round had one initial judgement overturned by
   a counter-example; recorded in the methodology note of §4.3.

Code scale (this round's baseline): 134 app source files / 21,802 lines, 28 test files; the longest
file is still `ShortcutEngine.swift` (2,513 lines), and its characterisation as "a coordinator rather
than a God class" agrees with `engine-split-design.md`, so this round does not re-argue it.

---

## 3. An independent assessment of the overall architecture (against the six references)

Before landing any change, the entry point, composition root, ports, engine, storage, services, AX
and UI layers were each read independently. Every conclusion below links back to source.

| Dimension / reference | Assessment (confirmed) | Main evidence |
|---|---|---|
| Dependency direction / Clean Architecture | Inner layers depend outward through port protocols, the App layer is the composition root, and dependency arrows always point inward | `Core/Ports/PresentationPorts.swift` is all protocols; `App/AppDelegate.swift` builds the concrete controllers and injects them through `EnginePresenters`; Core imports no AppKit UI layer |
| Ports–adapters / Hexagonal | UI, AX, injection and persistence all sit behind interfaces, and the engine collaborates only with abstractions | `OverlayPresenting`, `MenuBarPresenting`, `ShortcutInjecting`, `CatalogLoader` and so on; `StatusItemController` and the like are concrete adapters |
| Pure logic testable / Clean Code + Pragmatic | Decision logic concentrates in `nonisolated` pure enums and value types, with AppKit doing only assembly and side effects | `RowKeyRouter`, `NavigationKey`, `ConflictDetector`, `KeyOrder`, `MenuContentPolicy` and so on, each with matching tests |
| Concurrency / Migrating to Swift 6 | Shared mutable state is isolated in ways the **compiler can verify** — `@MainActor`, `Sendable`, private serial queues, lock boxes; dangerous escape points are marked explicitly and with a reason | `EngineState` is `@MainActor`; `FileLogStore` is `@unchecked Sendable` with state only on a private queue; `CrashReporter`'s `nonisolated(unsafe)` is bound by async-signal-safety |
| Function responsibility / Clean Code | The engine is a short-function coordinator delegating computation to Pure, with no long methods (only 2 functions over 80 lines, both in tests/loading assembly) | `metrics`: `functions >80 lines = 2` (`PreviewScenarios` 149, `CatalogLoader` 81) |
| Crash surface / Pragmatic (design by contract) | No `as!` anywhere, no `try!` (the 3 `try!` verified to be on test/encoding constant paths), no dangerous force unwrapping | See §6.2; the only `URL(string: "https://…")!` is a compile-time constant and necessarily valid |
| macOS conventions / HIG + macOS Apprentice | Non-activating panels, keyboard focus, reduced motion, VoiceOver labels, template status bar icons — all consistent with platform conventions | `PermissionGuidePanel.canBecomeKey = false`; `StatusItemController`'s template icon; `Interaction.swift` honours Reduce Motion; icon buttons all carry accessibility labels |

**Overall (inferred)**: this project's engineering practice agrees closely with the principles the
six references advocate, and has moved beyond "tidy style" into "express invariants with the type
system, pin contracts with tests". This round's marginal gain therefore lies not in macro style but
in the few remaining duplicates and test blind spots.

---

## 4. Refactors landed

### 4.1 Extract the conflict ordering comparator, removing a double copy (DRY)

**Problem**: the same `BindingConflict` ordering logic — "category descending → distinct owner count
descending → chord ascending" — was copied verbatim in two places:

- at the end of `conflicts(in:external:)` in `Core/Pure/ConflictDetector.swift`;
- in `CrossAppConflictBuilder.sorted()` in `Core/Engine/ConflictCenter.swift`.

Adding one more tiebreak level to the ordering would mean editing both in step, with drift risk.
This is precisely the DRY of *The Pragmatic Programmer* and *Clean Code*'s "the same knowledge
should have exactly one authoritative expression".

**Change**: give the value type a single comparator and have both call it.

- Added `nonisolated extension BindingConflict { static func bySeverity(_:_:)`
  (`ConflictDetector.swift:204`);
- `ConflictDetector.swift:315` → `conflicts.sorted(by: BindingConflict.bySeverity)`;
- `ConflictCenter.swift:228` → `conflicts.sorted(by: BindingConflict.bySeverity)`.

**A key detail (concurrency)**: the extension must be explicitly `nonisolated`. The app target sets
default `MainActor` isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION`), so an unannotated extension method
is inferred as `@MainActor` and the `sorted(by:)` call site, being nonisolated, reports "loses global
actor 'MainActor'". That error appeared in the first `xcodebuild` run and vanished with the explicit
`nonisolated` — consistent with the project's existing `nonisolated extension KeyChord`.

**Principle mapping**: DRY (Pragmatic), single source of knowledge (Clean Code), a pure value
comparison naturally nonisolated (Swift 6).

### 4.2 Extract the text-config scan skeleton, removing duplicated flow in two scanners

**Problem**: `HammerspoonScanner` and `SkhdScanner`'s `scan` methods shared the same "find the first
existing path → read as text → hand to the parser" `guard` chain, differing only in search paths and
parse function.

**Change**: provide a template method on the shared `ConfigFileScanner`, and reduce both scanners to
a one-line delegate.

- Added `ConfigFileScanner.scanTextConfig(searchPaths:homeDirectory:fileManager:parse:)`
  (`ConfigFileScanner.swift:145`);
- `HammerspoonScanner.swift:16` and `SkhdScanner.swift:13` now call that method, passing
  `ConfigTool.hammerspoon/skhd.relativeSearchPaths` and `bindings(from:)` respectively.

The "a missing or unreadable file returns an empty array" behaviour is preserved uniformly by the
template, exactly as the original inline `guard`. The other scanners (Karabiner, Keyboard Maestro,
BetterTouch Tool, Alfred) read plist/data rather than text and do not fit this template, so they were
not forced into it (avoiding over-abstraction).

**Principle mapping**: template method / shared skeleton (Clean Architecture, Pragmatic's
"orthogonality"), abstraction boundaries set by the actual scope of reuse (Pragmatic: don't
over-design for imagined reuse).

### 4.3 Extract search-field key routing into pure logic and add tests (test blind spot + readability)

**Problem**: the search field's key decisions were inlined in
`SurfacePanelController.installSearchKeyMonitor()`'s local event monitor, with **no unit tests at
all**; and the same "move the selection" behaviour was expressed through two paths — `NavigationKey`
covers only unmodified and pure-⌃ arrow keys, while other modifiers (⌘↓, ⇧↑) fall through to a
later catch-all branch, making the net behaviour hard to see at a glance.

**An initial judgement overturned by a counter-example (methodology record)**: this round first
judged the catch-all branch dead code, but enumerating path by path showed that `⌘↓` makes
`NavigationKey.direction` return `nil` (the modifiers are non-empty and not purely `[.control]`),
so it **really does** reach the catch-all. It is therefore not dead code but a readability problem —
"one behaviour, two paths". That correction decided the shape of the refactor: keep all behaviour and
only extract pure logic, rather than delete.

**The fully enumerated net behaviour (must be equivalent before and after)**:

- Bare `/` (no modifiers, empty query) → return to the panel; non-empty query or any modifier
  (including ⌘/ as the help key) → pass through;
- Up/down keys, **with any modifiers** (including the Emacs ⌃N/⌃P) → move the selection (−1/+1) and
  swallow the key;
- Left/right keys, **with any modifiers** (including ⌃B/⌃F) → pass through so the text field moves
  the caret;
- Esc (modifiers not checked) → close and swallow the key;
- Any other character → pass through.

**Changes**:

- Added the pure `Core/Pure/SearchKeyRouter.swift`: `SearchKeyAction`
  (moveSelection/close/returnToPanel/passThrough) and
  `SearchKeyRouter.action(keyCode:modifiers:isQueryEmpty:)` (`SearchKeyRouter.swift:23`), reusing
  `NavigationKey` to keep the Emacs keys;
- `SurfacePanelController.swift:219` became a thin wrapper of "get the decision → perform the action";
  the input-method composition state (`TextComposition.isComposing`), being panel state, stays in the
  controller and passes through early;
- Added `Tests/KanameCoreTests/SearchKeyRouterTests.swift`, 11 tests covering the physical arrows,
  the Emacs keys, arrow keys with modifiers, the regression point that `⌃⌘P/⌃⌥P must pass through`,
  Esc, slash and each boundary, and ordinary characters.

**Principle mapping**: decisions separated from mechanism (Clean Architecture, Pragmatic's
"separation of concerns"), pure logic that can be tested (Clean Code), implicit behaviour made
explicit and pinned (design by contract).

---

## 5. Change list

| File | Kind | Note |
|---|---|---|
| `Core/Pure/ConflictDetector.swift` | Modified | Added `BindingConflict.bySeverity`; this file's sorting now uses it |
| `Core/Engine/ConflictCenter.swift` | Modified | `CrossAppConflictBuilder.sorted()` switched to the shared comparator |
| `Core/Pure/ConfigFileScanner.swift` | Modified | Added the `scanTextConfig` template |
| `Core/Pure/HammerspoonScanner.swift` | Modified | Switched to `scanTextConfig` |
| `Core/Pure/SkhdScanner.swift` | Modified | Switched to `scanTextConfig` |
| `Core/Pure/SearchKeyRouter.swift` | Added | Pure search-field key routing (45 lines) |
| `UI/Surface/SurfacePanelController.swift` | Modified | Event monitor now calls the pure router (net −20 lines) |
| `Tests/KanameCoreTests/SearchKeyRouterTests.swift` | Added | 11 tests (145 lines) |

`git diff --stat` (tracked files): 6 files, +58 / −54; plus the two new files for 190 lines.

---

## 6. Remaining items and follow-up suggestions

The items below were argued sufficiently in the previous three rounds, so this round does not repeat
them, giving only handling suggestions based on the current source; none constitutes a current
correctness defect.

### 6.1 The 2 remaining "duplicate blocks" are verified reasonable, **suggested to keep**

- `ShortcutTester.verdict` and `ShortcutTestSession.verdict`: identical signatures, but the former
  (AppKit layer) only delegates to the latter (pure layer) — the project's deliberate
  "AppKit mechanism / pure decision" layering; identical signatures are inevitable there, not
  duplicated logic;
- `HammerspoonScanner` and `SkhdScanner`'s call sites of `scanTextConfig`: both now call the same API,
  so the call sites are naturally similar; there is no duplicated logic left, and removing the
  similarity further would take extra indirection, i.e. over-design.

### 6.2 Error swallowing and force unwrapping (carrying the prior conclusions)

- The 51 `try?` sites that swallow real errors (not counting the 5 `try? await Task.sleep`) were
  checked class by class in the previous three rounds; many cluster in `CrashReporter`
  (async-signal-safe), `FileLogStore` (log failure degrades silently) and cache/config scanning
  (which has `?? []` and similar fallbacks), all with legitimate reasons. **Suggested to leave as
  is**, and only to keep the discipline "use `try?` only when nothing can be done" in new code.
- No `as!` anywhere, no dangerous force unwrapping; the 3 `try!` sit on test/encoding-determined
  paths, and the constant URL's force unwrap is safe. No change needed.

### 6.3 Engine split (long term, per `engine-split-design.md`)

`ShortcutEngine` has completed slice 1 (assembly moved into the App layer). §7 of the design document
states the next precondition explicitly: **narrow the shared core** (`prefix`/`phase`/`pending`),
after which the four big sections (navigation/execution/recording/search) become movable. This round
did not touch that structure; suggested to proceed slice by slice per the document, building and
testing each slice independently, with no one-shot big-bang split.

### 6.4 Structural gaps in test coverage (inferred, non-blocking)

Pure-layer tests are ample, but the engine and input layer (event monitors, tap assembly) depend on
real AppKit/AX and are hard to unit test. This round extracted and tested the search key decision,
which was one of the purifiable parts; the remaining AppKit assembly logic should keep following the
gradual route "extract a pure decision wherever you can", rather than bringing in a heavyweight UI
testing framework.

---

## 7. Verification record

- `swift test`: **Executed 557 tests, with 0 failures** (including the 11 new `SearchKeyRouterTests`).
- `xcodebuild -scheme Kaname -configuration Debug build CODE_SIGNING_ALLOWED=NO`: **BUILD
  SUCCEEDED**; beyond a "multi-target destination selection" notice, no code warnings or errors.
- Duplication: `metrics`'s Core cross-file ≥5-line duplicate blocks **4 → 2**, with the remaining
  items verified reasonable in §6.1.
- Coverage and gaps: this round's conclusions rest on an independent close reading of representative
  files and tests across App/Core (Pure, Engine, Input, Ports, Services, Storage, AX)/UI; files not
  read line by line are not judged universally, and every "all/none" conclusion is bounded by what
  was actually checked.

---

## 8. Delivery note

This report and the changes sit in the project directory, ready for `git diff` review or commit.
Suggested to land this round's three refactors as one or several focused commits (such as
`refactor: share conflict ordering comparator`, `refactor: extract text config scan template`,
`refactor: extract search key router with tests`), keeping each commit's intent single.

---

## 9. Post-install runtime crash fix (EXC_BREAKPOINT / isolation mismatch)

After this round's build was installed over the old app, the app crashed while persisting usage in
the background. The problem is invisible to static reading and to compilation — it is a runtime
isolation assertion — so it is recorded separately.

### 9.1 Symptom and evidence (confirmed)

- The system report `~/Library/Logs/DiagnosticReports/Kaname-2026-11-03-020959.ips` shows
  `EXC_BREAKPOINT (SIGTRAP)`, with the crashing thread on the background queue
  `com.suliveevil.kaname.usage-write` and the stack
  `_dispatch_assert_queue_fail → dispatch_assert_queue → _swift_task_checkIsolatedSwift →
  swift_task_isCurrentExecutorWithFlagsImpl → closure #1 in UsageStore.flush()/schedulePersist()`.
- That is, the runtime detected "the current executor does not match the declared actor isolation"
  and deliberately trapped.

### 9.2 Root cause (two layers, both tied to default MainActor isolation)

1. **The storage type was implicitly isolated**: `JsonFileStore` (inside `DataDirectory.swift`)
   carried no `nonisolated`, so under the app target's `-default-isolation MainActor` it was inferred
   as `@MainActor`, making its `save` a MainActor-isolated method; dispatching it onto a background
   queue then failed the executor check.
2. **The closure itself was isolated (the easier one to miss)**: even after making `JsonFileStore`
   `nonisolated`, a `DispatchWorkItem` closure formed directly in a `@MainActor` context is still
   inferred as `@MainActor` **itself**, and running it on the background queue makes the runtime emit
   `warning: data race detected: @MainActor function ... was not called on the main thread`.

### 9.3 Fix (confirmed)

- `JsonFileStore` became `nonisolated struct ... Sendable`, gained an injectable `directory`
  (defaulting to `DataDirectory.url`), and now does its own `createDirectory` inside `save`, so
  storage can be tested against a temporary directory without polluting the real Application
  Support.
- `UsageStore` gained a `nonisolated static func makeWriteItem(...)` factory that creates the
  `DispatchWorkItem` in a non-isolated context, so the closure is non-isolated; the private `Payload`
  is explicitly `nonisolated ... Sendable`, so a payload built on the MainActor can be passed in
  safely. `flush`/`schedulePersist` both switched to that factory.

### 9.4 Verification (confirmed)

- Added `scripts/verify_usage_store_isolation.sh`: compiled with the same default MainActor isolation
  as the app, really executing a `DispatchWorkItem` write on a background queue, with double
  protection from `-warnings-as-errors` and a runtime grep for `data race detected`.
  **Negative**: the pre-fix code reliably prints `data race detected` at runtime; **positive**: the
  fixed code prints no warning and outputs `ok`.
- The real app: after reinstalling, `init`'s background `flush` writes successfully (`usage.json`
  regenerated, content valid), the process stays alive with no new system crash report and no data
  race; real keypresses through the event tap leave the process healthy. `swift test` 557 all green,
  both Debug and Release app targets build with zero warnings.
- Note: SPM's Core target points only at `Core/Pure` and cannot reach `Core/Storage`, and the Xcode
  project has no unit-test target, so the Storage layer is verified by a standalone script rather
  than by SPM tests; a standalone minimal program cannot reliably reproduce the production hard trap
  (it only reaches the data-race warning level), so the production hard trap is taken from the real
  `.ips`.

### 9.5 Lesson (inferred)

Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, "it compiles" does not mean "background execution
is safe": not only are type methods implicitly isolated, but **escaping closures formed in a
MainActor context are isolated too**. Work items crossing actors/queues should be built in an
explicit `nonisolated` factory and carry immutable payloads through `Sendable`; problems of this
kind need verifying on a real background queue at runtime, since static reading and compilation
cannot cover them.
