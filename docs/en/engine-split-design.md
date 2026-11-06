# ShortcutEngine split design

[English](engine-split-design.md) · [中文](../zh-CN/engine-split-design.md)


The second review round recorded P1-5 as "engine God class (2,530 lines / 19 sections), heavier than
any other finding, deserving its own split design — open a separate round for it". This document
is that design.

**Measurement baseline**: `2800947` (before slice 1). Every number comes from
`scripts/code-metrics.py` plus the two one-off scripts described below, and can be re-run against
any commit.

**Conclusion first**: the file's **line count** is real, the **"God class" diagnosis is wrong**. It
is a coordinator — wide, not deep. Cutting it into 19 files along the 19 MARK sections would not
reduce coupling; it would turn coupling from "calls inside one file" into "calls across files".
What is actually worth doing is two other things, and this document gives their order and
acceptance criteria.

---

## 1. The measured shape

2,536 lines, of which **70% is code (1,784)**, 22% comments (560), 7% blank.

**Function-length distribution** (brace matching, comments stripped):

| | |
|---|---|
| Functions | 134 |
| Median body | **8 lines** |
| Longest body | **57 lines** (`reloadCatalog`) |
| Functions over 80 lines | **0** |

That is the decisive number. R2's *Large Class* describes "one class doing too much", whose typical
symptoms are long methods and a pile of fields only some methods touch. Here there are **no long
methods**: 134 short functions, median 8 lines. The project's other two >80-line functions live
outside this file (`PreviewScenarios.startPreview` 149, `CatalogLoader.scan` 81).

## 2. How coupled the nineteen sections really are

Per section: code lines, `state.` reads, `state.` **writes**, and how many collaborators it uses.

| Section | Code | `state.` reads | `state.` writes | Collaborators |
|---|---:|---:|---:|---:|
| State | 1 | 0 | 0 | 0 |
| Collaborators | 35 | 1 | 1 | 23 |
| Lifecycle | 98 | 10 | 6 | 15 |
| Settings | 73 | 9 | 6 | 2 |
| Permissions | 126 | 17 | 13 | 8 |
| Catalog | 94 | 39 | 23 | 4 |
| Input | 259 | 70 | 8 | 5 |
| Panel lifecycle | 107 | 48 | 13 | 4 |
| Panel content | 220 | 70 | **2** | 4 |
| Favourites and panel actions | 111 | 35 | 3 | 3 |
| Panel execution | 156 | 33 | 1 | 4 |
| Statistics | 68 | 20 | 3 | 5 |
| Cross-app conflicts | 4 | 0 | 0 | 0 |
| Third-party config files | 44 | 16 | 4 | 2 |
| Live shortcut test | 29 | 7 | 4 | 1 |
| Search | 211 | 91 | 10 | 6 |
| Hotkey recording | 58 | 6 | 5 | 1 |
| Commands from the UI | 26 | 6 | 1 | 2 |
| Diagnostics | 47 | 14 | **0** | 3 |

The **writes** column is the test for whether a section can be moved safely: a read of `state` can
become a passed-in value, but a write means the moved section must be able to change shared state
back — which means moving `EngineState` too, or injecting a reference, and the latter removes
nothing.

## 3. The coupling sits in two places, neither between sections

**Shared verbs** (how often other sections call them):

| Call | Count | Defined in |
|---|---:|---|
| `rebuildPanel` | 16 | Panel content |
| `dismissPanel` | 15 | Panel lifecycle |
| `publishInputState` | 9 | Input |
| `applyHotkeySwallowing` | 7 | Input |
| `reloadCatalog` | 6 | Catalog |
| `dismissEverything` | 6 | Panel lifecycle |

**Shared fields** (`EngineState` fields read by three or more sections):

| Field | Sections |
|---|---:|
| `prefix` | 6 |
| `phase` | 5 |
| `orderedHitsCache` | 5 |
| `searchCorpus` | 5 |
| `pending` | 3 |

Of roughly 28 fields only 5 are shared; the rest are local to one or two sections.

These two tables do not show "19 responsibilities crammed together". They show **19 sections
around a very small shared core (5 fields, 6 verbs)**. The sections barely talk to each other; they
all talk to the core.

## 4. Correcting the diagnosis

| | What the review said | What the measurement says |
|---|---|---|
| Symptom | 2,530 lines / 19 sections | The line count holds; but 134 functions with a median of 8 lines, longest 57, none over 80 |
| Diagnosis | God class (doing too much) | Coordinator (orchestrating 23 collaborators plus a dozen Pure types) |
| Implied prescription | Extract Class, cut along sections | Does not hold for most sections — see below |

`Panel content` (220 code lines) is a good example: it reads `state` 70 times and writes it twice.
And it **already delegates the logic to Pure types** — `OverlayMetrics`, `FavoritesPolicy`,
`RowBudgetKey`, `PrefixResolver`, `PanelBudget`, `PanelRowBuilder`. What remains in the engine is
orchestration. Move that orchestration into a new file and the new file still reads the same 70
times: the lines move, the coupling does not.

**The real defect is not size but the nature of the boundary**: the 19 MARK sections are a
**comment convention**, not a structure. `private` provides no isolation inside this class — all
134 methods can call each other. So "some section depends on another" is today neither prevented
nor recorded by the compiler; only a human reading it can tell.

## 5. Slice plan (increasing risk, each independently revertible)

Criteria: **`state.` writes = 0 or very few**, **collaborators ≤ 3**, **moving it buys tests**.

| Slice | Section | Code | Writes | Collaborators | Criteria |
|---|---|---:|---:|---:|---|
| **1** ✅ | Diagnostics | 47 | **0** | 3 | Done (`8469003`) — see section 6 |
| 2 | Cross-app conflicts | 4 | 0 | 0 | Already pure delegation; moving it is a documentation gain, lowest priority |
| 3 | Commands from the UI | 26 | 1 | 2 | One write; confirm which field is written first |
| 4 | Live shortcut test | 29 | 4 | 1 | Only `shortcutTester`; the four writes are mostly task fields |
| 5 | Third-party config files | 44 | 4 | 2 | Task fields plus `searchCorpus`; split the cache out first |
| 6 | Hotkey recording | 58 | 5 | 1 | Five writes, mostly the recording state machine |

**The four sections not worth splitting as they stand** (47% of the engine's code): `Search`
(211 / 10 writes), `Panel content` (220 / 2 writes), `Input` (259 / 8 writes), `Panel execution`
(156 / 1 write).

What they share is not "being too big" but that **they are operations on those few shared
`EngineState` fields**. To make them movable, something else has to happen first:

> **Narrow the shared core first.** `prefix` / `phase` / `pending` are read and written by 5–6
> sections and are what these four genuinely share. If they could be collected into one explicit
> value (say a `PanelMatchState`, produced by the Input section and consumed **read-only** by these
> four), their write counts would fall to near zero, and only then would moving them mean anything.
> The order must be: narrow the core, then move sections. Doing it the other way round only
> produces four new files that reference each other.

## 6. Slice 1: done (`c336096` + `8469003`)

Diagnostics was chosen because it is the only section in the whole table with `state.` writes = 0 —
**moving it cannot structurally change behaviour**.

- `DiagnosticsReportBuilder` (`Core/Pure`) takes a 22-field `Input`; the engine keeps only "naming
  these values", the one thing nobody else can do.
- Three decisions made it testable: `generatedAt` is passed in by the caller (so the output is
  deterministic), `windowTitles` is passed in by the caller (so AppKit stays outside the new file),
  and `scanState` reuses `ScanState.diagnosticCode` instead of rewriting three lines.
- `ScanState` moved from `Core/AX/MenuScanner.swift` to `Core/Pure`: five cross-layer files
  referenced it by bare name, living in the producer file made every reader depend on that file,
  and **it could therefore never be tested** — the test target compiles only `Core/Pure`
  (`Package.swift:13`), with `Core/AX` and `Core/Engine` outside it. This is what this round
  discovered: the test net's boundary is Pure, so anything outside Pure gets no unit tests no
  matter how pure it is.

**Acceptance** (equivalence was measured, not eyeballed):
- `KANAME_SELFTEST=1` produces the same 29 top-level keys, none missing, none extra;
- the settings preview screenshot is byte-identical to before the change (`b43e2206…`; that
  scenario is deterministic — see review finding N6);
- the panel log metrics are identical word for word: `app=57 system=79 page=1/6 rows=24`, 182
  items, 201 shortcuts, `state=ok`;
- 6 new tests (546 total); the Core standalone typecheck reports 0 diagnostics across 115 files.

The engine went from 2,536 to 2,513 lines. **The 23 lines are not the point**; the point is that
this path could previously only be verified end to end, and now it has unit tests.

## 7. What the next round should look at

1. **The test target covers only Pure** (`Package.swift:13`). That is the root cause behind "what
   is missing is tests for the engine/input layer", not "there are too few tests". Whether to bring
   all of `Core/` into the test target is a separate decision — it drags in AppKit dependencies,
   and the `StrictConcurrency` experimental feature and the app's `complete` mode may not produce
   the same diagnostics, so try it before committing.
2. **Narrowing the shared core** (section 5), the precondition for making those four sections
   movable.
3. `Lifecycle` (15 collaborators) and `Collaborators` (23) are themselves "assembly", not logic;
   they are big because there are many collaborators. If the engine really should get smaller,
   reducing collaborators beats moving methods.
