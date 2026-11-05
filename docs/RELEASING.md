# Releasing

## One-time setup

```sh
./scripts/setup_signing.sh
```

Creates the stable self-signed `KagiPeek Local` identity in its own keychain (see
[Signing keychain](#signing-keychain)), not in the login keychain. Its designated requirement
(`identifier com.voltline.kagipeek and certificate root = …`) does not change when the code
does, so the Accessibility grant survives rebuilds **on this machine and keychain**. For a
downloadable release, use a Developer ID Application certificate instead
(`KAGIPEEK_SIGN_IDENTITY`) and a `notarytool` keychain profile (`KAGIPEEK_NOTARY_PROFILE`).

## Signing keychain

The `KagiPeek Local` private key lives in a dedicated keychain so `codesign` never has to ask
for authorization:

| Item | Path | Mode |
| --- | --- | --- |
| Keychain | `~/Library/Keychains/kagipeek-signing.keychain-db` | `600` |
| Keychain passphrase | `~/Library/Application Support/KagiPeek/signing/keychain-pass` | `600` |
| `.p12` backup | `~/Library/Application Support/KagiPeek/signing/KagiPeek-Local.p12` | `600` |
| `.p12` passphrase | `~/Library/Application Support/KagiPeek/signing/p12-pass` | `600` |

The `signing/` directory is `700`. Nothing here is in the repository. `scripts/build_swiftc.sh`
reads the passphrase, runs `security unlock-keychain`, and passes `--keychain` to `codesign`;
the passphrase is never echoed. The keychain auto-locks after 12 hours (`-t 43200`) so an
unattended build day never hits a lock, while the file stays encrypted at rest.

**Why not the login keychain.** The key there is visible to `codesign`, but macOS still shows
the "wants to use your key" dialog. Clicking **Always Allow** does not stick for CLI signing:
the effective grant is the key's ACL and partition list, which the login keychain manages and
resets per process. A dedicated keychain imported with `-A` and configured with
`set-key-partition-list` signs without any prompt.

### Move an existing identity (one time)

Keep the same certificate. A new certificate changes the designated requirement and every TCC
permission would have to be granted again.

```sh
KC="$HOME/Library/Keychains/kagipeek-signing.keychain-db"
SIGN="$HOME/Library/Application Support/KagiPeek/signing"
LOGIN="$HOME/Library/Keychains/login.keychain-db"

# 1. Export the identity to a .p12 (use a random passphrase, store it in "$SIGN/p12-pass", 600)
security export -k "$LOGIN" -t identities -f pkcs12 -P "<p12 passphrase>" \
  -o "$SIGN/KagiPeek-Local.p12" "KagiPeek Local"

# 2. Create the keychain; store a random passphrase in "$SIGN/keychain-pass" (600). The dir is 700.
security create-keychain -p "<keychain passphrase>" "$KC"
security set-keychain-settings -t 43200 "$KC"

# 3. Import with -A (allow codesign to use the key without a prompt), then set the partition list
security import "$SIGN/KagiPeek-Local.p12" -k "$KC" -f pkcs12 -P "<p12 passphrase>" -A
security unlock-keychain -p "<keychain passphrase>" "$KC"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "<keychain passphrase>" "$KC"
security list-keychains -d user -s "$LOGIN" "$KC"

# 4. Prove signing works, then remove the login copy
codesign --force --sign "KagiPeek Local" --keychain "$KC" /tmp/some-binary-copy
security find-identity -v -p codesigning   # exactly one KagiPeek Local line
security delete-identity -c "KagiPeek Local" "$LOGIN"
```

`security delete-identity` removes both the certificate and its private key from the login
keychain; omit `-t` so the user trust settings survive. Afterwards
`security find-identity -v -p codesigning` must print exactly one **KagiPeek Local** line.
The designated requirement can be compared before and after with `codesign -d -r-`; the
`certificate root = H"…"` hash must stay identical, which is the evidence that Accessibility
was not re-asked.

### New machine / restore

Run `./scripts/setup_signing.sh`. It creates the identity directly in the dedicated keychain,
writes the passphrase file, sets the partition list and the 12-hour lock, and refuses to
create a second certificate when one already exists outside that keychain. To restore from a
`.p12` backup, follow step 3 above and then verify with step 4. The certificate must be
trusted (`security add-trusted-cert -r trustRoot -k "$KC" cert.pem`, or Keychain Access) for
`find-identity -v` to list it; trust settings are user-wide and survive moving the key.

## Steps

1. **Decide the version.** `MARKETING_VERSION` in `KagiPeek.xcodeproj/project.pbxproj` (both
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
   # build/KagiPeek-<version>.dmg, build/KagiPeek-<version>.dmg.sha256, and the signed .app
   ```

   The script reads the version from the built bundle and refuses to continue if it does not
   match the project file. It signs the `.app` **and** the `.dmg`, notarizes and staples both
   when a notary profile is configured, and writes `build/KagiPeek-<version>.dmg.sha256`.

   It also stamps the build: `build/.release-stamp` holds one line, `<version> <HEAD>`, with
   `-dirty` appended when the tree had uncommitted changes. `scripts/publish_release.sh`
   compares that stamp with the current `HEAD` and rebuilds when it does not match, because an
   unchanged version number would otherwise re-publish whatever the previous checkout left in
   `build/` — the tag and the code inside the DMG could disagree with nothing in the output
   saying so. A `-dirty` stamp publishes with a warning: that DMG contains code no commit has.

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

5. **Write the notes.** The body of the GitHub release is generated by the publish script from
   the commits since the previous tag, so the only mandatory input is a clean commit history. If a
   release needs prose — a behaviour change users must understand, a migration step — put it in
   `docs/RELEASES.md` under **Highlights**, **Fixes worth knowing about** or **Upgrade notes**, and
   copy the engine's behaviour from the code, not from the previous notes. A hand-written body for
   one release can still be dropped at `docs/releases/<tag>.md`; it wins over the generated one.

6. **Publish.**

   ```sh
   ./scripts/publish_release.sh
   ```

7. **Install locally and smoke test.** `./scripts/install.sh` (it stages the bundle, verifies the
   signature, copies the replaced build to `~/Library/Application Support/KagiPeek/backups/`,
   then swaps the new one in). The installer refuses an ad-hoc build: only `KagiPeek Local` or a
   Developer ID signature may sit in `/Applications`. Then the short list:
   trigger the panel, narrow it with ⌘, run a menu item, copy a menu item, open the palette with `/`, switch
   its app scope, export Markdown, search and press Return, open Settings and check the
   Statistics and Conflicts tabs.

## Backups and rollback

Every install keeps one backup, named for the day, the build and the identity it carried:

```
KagiPeek-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app
```

They live in `~/Library/Application Support/KagiPeek/backups/`, never in `/Applications`
(a second copy of the same bundle id is registered by LaunchServices, and an ad-hoc copy gets
its own TCC identity). The newest five are kept; older ones are pruned by
`scripts/backup_app.sh`. Raise or lower the count with `KAGIPEEK_BACKUP_KEEP`.

Roll back to one of them (copy-paste; replace `<backup.app>` with the full path):

```sh
osascript -e 'tell application id "com.voltline.kagipeek" to quit'; sleep 2
rm -rf /Applications/KagiPeek.app.new && ditto "<backup.app>" /Applications/KagiPeek.app.new
rm -rf /Applications/KagiPeek.app && mv /Applications/KagiPeek.app.new /Applications/KagiPeek.app
open /Applications/KagiPeek.app
/usr/libexec/PlistBuddy -c "Print :KagiPeekCommit" /Applications/KagiPeek.app/Contents/Info.plist
```

The last command must print the commit embedded in the backup's name; compare the two before
declaring the rollback good. A backup carries the signature it was installed with, so a
`local` backup keeps the Accessibility grant, while restoring an `adhoc` one asks again.

A bad release: delete the GitHub release and mark the tag as withdrawn; the DMG is immutable, so
publish a new patch version rather than replacing the asset.
