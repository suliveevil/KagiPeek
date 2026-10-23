# Releasing

## One-time setup

```sh
./scripts/setup_signing.sh
```

Creates the stable self-signed `KagiPeek Local` identity. Its designated requirement
(`identifier com.voltline.kagipeek and certificate root = …`) does not change when the code
does, so the Accessibility grant survives rebuilds **on this machine and keychain**. For a
downloadable release, use a Developer ID Application certificate instead
(`KAGIPEEK_SIGN_IDENTITY`) and a `notarytool` keychain profile (`KAGIPEEK_NOTARY_PROFILE`).

## Steps

1. **Decide the version.** `MARKETING_VERSION` in `KagiPeek.xcodeproj/project.pbxproj` (both
   the Debug and Release configurations) and make sure `CHANGELOG.md` has the entries under
   `[Unreleased]`.
2. **Test.**

   ```sh
   swift test          # or: swift test --disable-sandbox
   ```

3. **Build, sign, package.**

   ```sh
   ./scripts/build_release.sh
   # build/KagiPeek-<version>.dmg, .sha256, and the signed .app
   ```

   The script reads the version from the built bundle and refuses to continue if it does not
   match the project file. It signs the `.app` **and** the `.dmg`, notarizes and staples both
   when a notary profile is configured, and writes `build/KagiPeek-<version>.dmg.sha256`.

4. **Verify before publishing.**

   ```sh
   codesign -dv --verbose=4 build/DerivedData/Build/Products/Release/KagiPeek.app
   codesign --verify --strict build/DerivedData/Build/Products/Release/KagiPeek.app
   spctl -a -vv build/DerivedData/Build/Products/Release/KagiPeek.app   # Developer ID only
   xcrun stapler validate build/KagiPeek-<version>.dmg                  # notarized only
   lipo -info build/DerivedData/Build/Products/Release/KagiPeek.app/Contents/MacOS/KagiPeek
   ```

   With the local self-signed identity `spctl` and `stapler` will fail — that build is for this
   machine, not for distribution. Mark the release accordingly instead of pretending otherwise.

5. **Write the notes.** `docs/releases/v<version>.md`: highlights, fixes worth knowing, install
   notes, the real SHA-256, and upgrade notes. Copy the engine's behaviour from the code, not
   from the previous release notes.

6. **Publish.**

   ```sh
   ./scripts/publish_release.sh
   ```

7. **Install locally and smoke test.** `./scripts/install.sh` (it stages the bundle, verifies the
   signature, swaps atomically and keeps `KagiPeek.previous.app`). Then the short list:
   trigger the panel, narrow it with ⌘, run a row, copy a row, open the browser window, run a
   row from it, search and press Return, open Settings.

## Rollback

An install keeps the previous bundle:

```sh
mv /Applications/KagiPeek.previous.app /Applications/KagiPeek.app
```

A bad release: delete the GitHub release and mark the tag as withdrawn; the DMG is immutable, so
publish a new patch version rather than replacing the asset.
