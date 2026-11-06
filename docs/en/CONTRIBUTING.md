# Contributing

[English](CONTRIBUTING.md) · [中文](../zh-CN/CONTRIBUTING.md)


## Build environment

- macOS 14 or later, full **Xcode** (Command Line Tools alone cannot expand the SwiftUI
  macros).
- No third-party dependencies; there is nothing to install or pin.

```sh
xcodebuild -project Kaname.xcodeproj -scheme Kaname -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

swift test        # pure-logic suite (KanameCore)
```

If your environment cannot create nested sandboxes — the symptom is
`sandbox-exec: sandbox_apply: Operation not permitted` in both commands — use:

```sh
swift test --disable-sandbox
./scripts/build_swiftc.sh Debug     # same sources, compiled with swiftc
```

`swiftc` needs the macro plugins loaded explicitly, which is what `build_swiftc.sh` does:

```sh
swiftc … -load-plugin-library "$PLUG/libSwiftUIMacros.dylib" \
        -load-plugin-library "$PLUG/libSwiftMacros.dylib" \
        -load-plugin-library "$PLUG/libObservationMacros.dylib"
```

## Where code goes

| Layer | Path | Rules |
| --- | --- | --- |
| Pure logic | `Kaname/Core/Pure` | Foundation only — no AppKit, no SwiftUI, no `NSWorkspace`. Compiled twice: into the app and into the `KanameCore` SwiftPM target that `swift test` runs. |
| AX | `Kaname/Core/AX` | Accessibility and `NSWorkspace` access. |
| Input | `Kaname/Core/Input` | The event tap, injection, and the AppKit→pure bridges. |
| Storage | `Kaname/Core/Storage` | The only code that touches disk. |
| Engine | `Kaname/Core/Engine` | `ShortcutEngine` wires the layers together. |
| UI | `Kaname/UI` | SwiftUI views and `NSWindow` controllers. |

If a decision can be expressed without AppKit, put it in `Core/Pure` and test it there. The
row contract, list selection, the panel row builder and the header layout all moved there for
that reason; `ShortcutEngine` is large enough already.

## Adding or removing a setting

A settings change touches **six** places. Missing one is how this project's documentation and
tests drifted:

1. `Core/Pure/AppSettingsModel.swift` — the property with its default, the `CodingKeys` case,
   and a `decodeIfPresent` line in `init(from:)`.
2. `UI/Settings/SettingsView.swift` — the control, on the tab it belongs to.
3. `Core/Pure/L10n.swift` — the label in **both** languages.
4. `README.md` and `README.zh-CN.md` — the configuration table in both languages (and the
   feature table if it is user-visible). The same page under `docs/en/` and `docs/zh-CN/`
   (for example `docs/en/FAQ.md` and `docs/zh-CN/FAQ.md`). Every pair is kept in step by hand:
   a fix lands in both halves of the pair in the same commit.
5. `Tests/KanameCoreTests` — a default-value assertion, and a decode test if the change can
   affect an existing `settings.json`.
6. `CHANGELOG.md` — one line under `## [Unreleased]`, in the user's terms, not the type's.

**Removing** a key needs no migration step: `init(from:)` only decodes known keys, so an old
payload decodes and the key disappears on the next save. Bump
`AppSettingsSnapshot.currentSchemaVersion`, add the removal to `SettingsMigrator`'s comment, and
add a test that an old payload still decodes and re-encodes without the key.

Editing a behaviour that the documentation describes? Change the code comment in the same
commit. Three separate comments said "the trigger keys are not a prefix" while the code pushed
them onto the prefix — and the documentation had been written from the comments.

## Tests

- `swift test` must pass. It is pure-logic only.
- New pure logic needs a test; new AppKit code needs a note in the pull request describing how
  you checked it by hand.
- `Tests/KanameCoreTests` is the only test target. There is no UI test target, so anything you
  cannot reach from `KanameCore` is untested by definition — another reason to keep decisions
  out of the views.

## Style

- Swift 6 language mode, macOS 14 deployment target, no dependencies. The app target sets
  `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete` and
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; `Package.swift` compiles `KanameCore` in
  Swift 6 mode with `StrictConcurrency`. So a new type is main-actor-isolated unless it says
  `nonisolated` — that keyword is a contract, not decoration: it is how `Diag`,
  `CrashReporter`, `KeyboardMonitor` and the `Core/Pure` types are allowed to be called from
  the event-tap thread or a crash handler.
- Comments explain **why**. A comment that restates the code is noise; a comment that says
  "this looks wrong but is deliberate because X" is the valuable kind.
- Log through `Diag`, never `print`. One call writes both sinks:
  `Diag.info(.tap, "event tap installed")`, `Diag.error(.inject, "…")`, `Diag.debug(.scan, "…")`.
  The tag is a `DiagTag`: `start`, `perm`, `tap`, `scan`, `inject`, `net`, `run`, `settings`,
  `ui`, `crash`, `exit`, `export`. Methods are `verbose` / `debug` / `info` / `warning` /
  `error`, plus `Diag.action(_:target:)` for the crash report's action ring. Note that
  `Diag` is the *only* façade — a second one (`AppLog`) existed once and produced lines that
  never reached the file; do not reintroduce one. A failure that says nothing is the bug
  report you cannot answer.
- British spelling in prose ("behaviour", "favourite") — the code and identifiers are English,
  and this is only about consistency in the docs.

## Parallel agents and worktrees

Several people and several coding agents (WorkBuddy, Claude Code, Codex, …) work on this
repository at the same time. **The authoritative rule is
[AGENTS.md](../../AGENTS.md) → git（多 agent 协作）**; this section explains the reasoning and the
cases where the rule is not worth its cost.

What actually collides is not "the same file" but the single `HEAD`, single index and single
uncommitted-changes area of a shared working tree. A linked worktree shares refs, the object
database, remote-tracking refs and `refs/stash`, but keeps its own `HEAD`, index and files. That
gives two consequences worth remembering:

- Git refuses to check out the same branch in two worktrees. Treat that as a guard, not an
  obstacle — `--force` would put two agents back onto one shared `HEAD`.
- `stash` is **shared**. One agent's `stash` can be popped by another. Move work between lines
  only by committing and letting the integrator merge; never by leaving uncommitted files around.

The main working tree stays on `main` and does integration, review and release only. Pair the
two concepts — `branch` gives history a parallel line, `worktree` gives that line its own desk:

```sh
# Integrator, in the main working tree
git worktree add -b agent/pure-search ../kp-pure-search main
git worktree lock ../kp-pure-search --reason "agent A session"
git worktree list

# After tests pass: merge (step 2), then clean up immediately (step 3).
# Step 4 — ./scripts/install.sh — comes *after* cleanup, and only for code changes.
git merge --ff-only agent/pure-search       # --no-ff if main has moved on
git worktree unlock ../kp-pure-search
git worktree remove ../kp-pure-search       # refuses if uncommitted files remain
git branch -d agent/pure-search             # -d, never -D
git worktree prune
```

Write each agent's absolute worktree path into that agent's own configuration or prompt. Their
sessions, task lists and context are not shared, and each may run git commands itself, so a
verbal "please stay in your directory" is not a boundary. The same applies to global side
effects: `scripts/install.sh` writes `/Applications`, rotates backups under
`~/Library/Application Support/Kaname/backups/` and reads the signing keychain. Three agents
installing at once overwrite the same app on the same machine — worktrees cannot isolate that.
**One integrator, one install, run outside the sandbox.** Keep `build/` and `DerivedData/` per
worktree too: an incremental build once carried a stale `AppIcon.icns` into `/Applications`.

Treat `AGENTS.md`, `scripts/`, icon assets and CI as shared contracts: edit them in the main
working tree, then have other worktrees `rebase main`. Split work by layer
(`Core/Pure`, `Core/AX`, `Core/Engine`), keep branches short-lived, merge often.

This is not worth it for a single agent, a serial one-line change, or read-only research —
branch switching is enough there, though a detached read-only worktree is still a clean way to
inspect logs without touching the shared tree. Every worktree rebuilds its caches (this project
has thousands of `.pcm` files under `build/`), so **3–5 parallel worktrees** is the practical
ceiling; beyond that the merge cost outweighs the parallelism.

## Commits and releasing

Work is branched and merged as described above and in
[AGENTS.md](../../AGENTS.md): a fresh worktree + branch off `main` for every change, merged back by
the integrator once `swift test --disable-sandbox` is green, with the worktree removed
afterwards. Nothing is committed to `main` directly in the main working tree. Reinstall via
`./scripts/install.sh` only when the merge contains **code** changes — documentation-only merges
do not make the installed binary older.

Commit messages: a `type:` prefix (`feat:`, `fix:`, `docs:`, `test:`, `chore:`) and a body that
says what changed and why. Update `CHANGELOG.md` under `[Unreleased]` in the same commit as the
change — see [RELEASING.md](RELEASING.md) for the release steps.

## Reporting bugs

Include the version (**Settings → About**), macOS version, and a diagnostics export from
**Settings → General → Diagnostics** — *Export diagnostics archive…* writes a `.zip` of the log and crash
folders, *Export diagnostics report…* writes a single `.json` snapshot. Both live in the folded
Diagnostics group at the end of General; the About tab has no export button. The archive contains permissions, the
listener state, the last scan result, your settings, and the command that prints the matching
log lines — no documents, no typed text, and nothing is uploaded. `KANAME_EXPORT_DIAGNOSTICS=<path>`
does the same from a terminal when the window is the broken part.
