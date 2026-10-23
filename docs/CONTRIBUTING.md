# Contributing

## Build environment

- macOS 14 or later, full **Xcode** (Command Line Tools alone cannot expand the SwiftUI
  macros).
- No third-party dependencies; there is nothing to install or pin.

```sh
xcodebuild -project KagiPeek.xcodeproj -scheme KagiPeek -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

swift test        # pure-logic suite (KagiPeekCore)
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
| Pure logic | `KagiPeek/Core/Pure` | Foundation only — no AppKit, no SwiftUI, no `NSWorkspace`. Compiled twice: into the app and into the `KagiPeekCore` SwiftPM target that `swift test` runs. |
| AX | `KagiPeek/Core/AX` | Accessibility and `NSWorkspace` access. |
| Input | `KagiPeek/Core/Input` | The event tap, injection, and the AppKit→pure bridges. |
| Storage | `KagiPeek/Core/Storage` | The only code that touches disk. |
| Engine | `KagiPeek/Core/Engine` | `ShortcutEngine` wires the layers together. |
| UI | `KagiPeek/UI` | SwiftUI views and `NSWindow` controllers. |

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
4. `README.md` — the configuration table (and the feature table if it is user-visible).
5. `Tests/KagiPeekCoreTests` — a default-value assertion, and a decode test if the change can
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
- `Tests/KagiPeekCoreTests` is the only test target. There is no UI test target, so anything you
  cannot reach from `KagiPeekCore` is untested by definition — another reason to keep decisions
  out of the views.

## Style

- Swift 5 language mode, macOS 14 deployment target, no dependencies.
- Comments explain **why**. A comment that restates the code is noise; a comment that says
  "this looks wrong but is deliberate because X" is the valuable kind.
- Log through `AppLog` (`scan` / `input` / `storage` / `ui`), never `print`. A failure that says
  nothing is the bug report you cannot answer.
- British spelling in prose ("behaviour", "favourite") — the code and identifiers are English,
  and this is only about consistency in the docs.

## Commits and releasing

Commit messages: a `type:` prefix (`feat:`, `fix:`, `docs:`, `test:`, `chore:`) and a body that
says what changed and why. Update `CHANGELOG.md` under `[Unreleased]` in the same commit as the
change — see [RELEASING.md](RELEASING.md) for the release steps.

## Reporting bugs

Include the version (**Settings → About**), macOS version, and the diagnostics export
(**Settings → About → Export diagnostics…**). It contains permissions, the listener state, the
last scan result, your settings, and the command that prints the matching log lines — no
documents, no typed text, and nothing is uploaded.
