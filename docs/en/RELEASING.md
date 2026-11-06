# Releasing

[English](RELEASING.md) · [中文](../zh-CN/RELEASING.md)


## One-time setup

```sh
./scripts/setup_signing.sh
```

Creates the stable self-signed `Kaname Local` identity in its own keychain (see
[Signing keychain](#signing-keychain)), not in the login keychain. Its designated requirement
(`identifier com.suliveevil.kaname and certificate root = …`) does not change when the code
does, so the Accessibility grant survives rebuilds **on this machine and keychain**. For a
downloadable release, use a Developer ID Application certificate instead
(`KANAME_SIGN_IDENTITY`) and a `notarytool` keychain profile (`KANAME_NOTARY_PROFILE`).

## Signing keychain

The `Kaname Local` private key lives in a dedicated keychain so `codesign` never has to ask
for authorization:

| Item | Path | Mode |
| --- | --- | --- |
| Keychain | `~/Library/Keychains/kaname-signing.keychain-db` | `600` |
| Keychain passphrase | `~/Library/Application Support/Kaname/signing/keychain-pass` | `600` |
| `.p12` backup | `~/Library/Application Support/Kaname/signing/Kaname-Local.p12` | `600` |
| `.p12` passphrase | `~/Library/Application Support/Kaname/signing/p12-pass` | `600` |

The `signing/` directory is `700`. Nothing here is in the repository. `scripts/build_swiftc.sh`
reads the passphrase, runs `security unlock-keychain`, and passes `--keychain` to `codesign`;
the passphrase is never echoed. The keychain auto-locks after 12 hours (`-t 43200`) so an
unattended build day never hits a lock, while the file stays encrypted at rest.

**Why not the login keychain.** The key there is visible to `codesign`, but macOS still shows
the "wants to use your key" dialog. Clicking **Always Allow** does not stick for CLI signing:
the effective grant is the key's ACL and partition list, which the login keychain manages and
resets per process. A dedicated keychain imported with `-A` and configured with
`set-key-partition-list` signs without any prompt.

### Keep the old identity for rollback

The rename created a new certificate and key pair, so the designated requirement changed and
Accessibility must be granted again. The previous identity is left untouched as a rollback copy:

| Item | Path |
| --- | --- |
| Old keychain | `~/Library/Keychains/kaname-signing.keychain-db` |
| Old passphrase | `~/Library/Application Support/Kaname/signing/keychain-pass` |

`scripts/setup_signing.sh` appends the new keychain to the user search list instead of replacing
it, so the old keychain stays usable. To sign with it temporarily:

```sh
codesign --force --sign "Kaname Local" \
  --keychain "$HOME/Library/Keychains/kaname-signing.keychain-db" /tmp/some-binary-copy
```

Delete the old keychain and certificate only after the Kaname install has run normally for a
while. Removing it while old backups (signed `Kaname Local`) are still kept would make those
backups unverifiable; keep both until the old backups have aged out.

### New machine / restore

Run `./scripts/setup_signing.sh`. It creates the identity directly in the dedicated keychain,
writes the passphrase file, sets the partition list and the 12-hour lock, and refuses to
create a second certificate when one already exists outside that keychain. To restore from a
`.p12` backup, follow step 3 above and then verify with step 4. The certificate must be
trusted (`security add-trusted-cert -r trustRoot -k "$KC" cert.pem`, or Keychain Access) for
`find-identity -v` to list it; trust settings are user-wide and survive moving the key.

## Steps

1. **Decide the version.** `MARKETING_VERSION` in `Kaname.xcodeproj/project.pbxproj` (both
   the Debug and Release configurations) and make sure `CHANGELOG.md` has the entries under
   `[Unreleased]`. That file is the single source for both build paths: the Xcode build reads
   it directly, and the fallback build (`scripts/build_swiftc.sh`) overwrites
   `CFBundleShortVersionString` / `CFBundleVersion` in the plist it was handed with
   `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, printing the template's value when the two
   disagreed. A bump that only touched the plist used to produce a fallback build that named
   itself the previous release.
2. **Test.**

   ```sh
   swift test          # or: swift test --disable-sandbox
   ```

3. **Build, sign, package.**

   ```sh
   ./scripts/build_release.sh
   # build/Kaname-<version>.dmg, build/Kaname-<version>.dmg.sha256, and the signed .app
   ```

   The script reads the version from the built bundle and refuses to continue if it does not
   match the project file. It signs the `.app` **and** the `.dmg`, notarizes and staples both
   when a notary profile is configured, and writes `build/Kaname-<version>.dmg.sha256`.

   It also stamps the build: `build/.release-stamp` holds one line, `<version> <HEAD>`, with
   `-dirty` appended when the tree had uncommitted changes. `scripts/publish_release.sh`
   compares that stamp with the current `HEAD` and rebuilds when it does not match, because an
   unchanged version number would otherwise re-publish whatever the previous checkout left in
   `build/` — the tag and the code inside the DMG could disagree with nothing in the output
   saying so. A `-dirty` stamp publishes with a warning: that DMG contains code no commit has.

4. **Verify before publishing.**

   ```sh
   codesign -dv --verbose=4 build/DerivedData/Build/Products/Release/Kaname.app
   codesign --verify --strict build/DerivedData/Build/Products/Release/Kaname.app
   spctl -a -vv build/DerivedData/Build/Products/Release/Kaname.app   # Developer ID only
   xcrun stapler validate build/Kaname-<version>.dmg                  # notarized only
   lipo -info build/DerivedData/Build/Products/Release/Kaname.app/Contents/MacOS/Kaname
   ```

   With the local self-signed identity `spctl` and `stapler` will fail — that build is for this
   machine, not for distribution. Mark the release accordingly instead of pretending otherwise.

5. **Write the notes.** The body of the GitHub release is generated by the publish script from
   the commits since the previous tag, so the only mandatory input is a clean commit history. If a
   release needs prose — a behaviour change users must understand, a migration step — put it in
   `docs/en/RELEASES.md` under **Highlights**, **Fixes worth knowing about** or **Upgrade notes**, and
   copy the engine's behaviour from the code, not from the previous notes. A hand-written body for
   one release can still be dropped at `docs/en/releases/<tag>.md`; it wins over the generated one.

6. **Publish.**

   ```sh
   ./scripts/publish_release.sh
   ```

7. **Install locally and smoke test.** `./scripts/install.sh` (it stages the bundle, verifies the
   signature, copies the replaced build to `~/Library/Application Support/Kaname/backups/`,
   then swaps the new one in). The installer refuses an ad-hoc build: only `Kaname Local` or a
   Developer ID signature may sit in `/Applications`. Then the short list:
   trigger the panel, narrow it with ⌘, run a menu item, copy a menu item, open the palette with `/`, switch
   its app scope, export Markdown, search and press Return, open Settings and check the
   Statistics and Conflicts tabs.

## Backups and rollback

Every install keeps one backup, named for the day, the build and the identity it carried:

```
Kaname-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app
```

They live in `~/Library/Application Support/Kaname/backups/`, never in `/Applications`
(a second copy of the same bundle id is registered by LaunchServices, and an ad-hoc copy gets
its own TCC identity). The newest five are kept; older ones are pruned by
`scripts/backup_app.sh`. Raise or lower the count with `KANAME_BACKUP_KEEP`.

Roll back to one of them (copy-paste; replace `<backup.app>` with the full path):

```sh
osascript -e 'tell application id "com.suliveevil.kaname" to quit'; sleep 2
rm -rf /Applications/Kaname.app.new && ditto "<backup.app>" /Applications/Kaname.app.new
rm -rf /Applications/Kaname.app && mv /Applications/Kaname.app.new /Applications/Kaname.app
open /Applications/Kaname.app
/usr/libexec/PlistBuddy -c "Print :KanameCommit" /Applications/Kaname.app/Contents/Info.plist
```

A rollback to the pre-rename app is a separate move: quit `com.suliveevil.kaname`, copy the
`Kaname-*.app` backup from `~/Library/Application Support/Kaname/backups/` (or the old
`~/Library/Application Support/Kaname/backups/`) to `/Applications/Kaname.app`, then launch
by `com.suliveevil.kaname`. Remove `/Applications/Kaname.app` first so two event taps cannot run
at once.

The last command must print the commit embedded in the backup's name; compare the two before
declaring the rollback good. A backup carries the signature it was installed with, so a
`local` backup keeps the Accessibility grant, while restoring an `adhoc` one asks again.

A bad release: delete the GitHub release and mark the tag as withdrawn; the DMG is immutable, so
publish a new patch version rather than replacing the asset.
