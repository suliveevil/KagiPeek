# PERMISSIONS

[English](PERMISSIONS.md) · [中文](../zh-CN/PERMISSIONS.md)


What macOS permissions, signing and the runtime environment actually are for this app. Written
2026-11-04, re-checked 2026-11-05 against this repository's code, `scripts/Info.plist`,
`scripts/build_swiftc.sh` and measured `codesign` output — not general macOS folklore. Re-check
it after code changes, especially the tap type and the signing configuration. Links are
repository-relative paths plus symbol names, never line numbers: line numbers drift with edits,
symbol names do not.

## 1. The system permissions this app actually needs

| Permission | Required? | Code evidence | Where the user grants it | What happens without it |
| --- | --- | --- | --- | --- |
| Accessibility | **Required** | `start()` in [KeyboardMonitor.swift](../../Kaname/Core/Input/KeyboardMonitor.swift) creates a `.cgSessionEventTap` with `.defaultTap` (a session-level tap that can swallow events); [CatalogLoader.swift](../../Kaname/Core/AX/CatalogLoader.swift) reads menus through `AXUIElementCreateApplication`; [MenuTrigger.swift](../../Kaname/Core/AX/MenuTrigger.swift) performs a cross-process `AXUIElementPerformAction` | System Settings → Privacy & Security → Accessibility → tick Kaname | The panel does not appear; the event tap fails to install; menu scans come back empty; running a menu item fails at the press. The settings page marks the permission as not granted and offers an "Open System Settings" entry |
| Input Monitoring | **Optional fallback** | [PermissionCenter.swift](../../Kaname/Core/AX/PermissionCenter.swift) checks it with `CGPreflightListenEventAccess()`; used only as a second gate alongside Accessibility | System Settings → Privacy & Security → Input Monitoring → tick Kaname | The app still works without it (Accessibility already covers the session-level tap); it matters only on system versions that gate on Input Monitoring rather than Accessibility |
| Screen Recording | **Not needed** | No `CGWindowListCreateImage`, no `SCShareableContent`, no screenshot API anywhere in the repository; panel placement uses AX window frames only ([WindowGeometry.swift](../../Kaname/Core/AX/WindowGeometry.swift)) | — | Irrelevant to this app. Screenshot and window capture belong to external tools (see the environment traps in STATUS) |
| Automation / Apple Events | **Not needed** | No `NSAppleEventsUsageDescription`, no `AEDeterminePermissionToAutomateTarget`; every cross-app action goes through AX | — | — |
| Full Disk Access | **Not needed** | Only `~/Library/Application Support/Kaname` and an export path the user chooses are read | — | — |

Supporting facts:

- **The tap is session-level and can swallow events**: `CGEvent.tapCreate(tap: .cgSessionEventTap, ..., options:
  .defaultTap)`, not HID-level (`.cghidEventTap`) and not `.listenOnly`. So it can both observe and
  intercept keys — which is why Accessibility is a hard prerequisite.
- **Injection goes through the HID layer**: `postKey(keyCode:flags:)` in
  [ShortcutInjector.swift](../../Kaname/Core/Input/ShortcutInjector.swift) builds a key with
  `CGEventSource(stateID: .hidSystemState)` and posts the down/up through
  `post(tap: .cghidEventTap)`. The code sets no private event source, and `KeyboardMonitor`
  does not filter events by source; injection happens only after the surface has closed and the
  tap no longer captures keys.
- **The test tap is `.listenOnly`**: `installTaps()` in
  [ShortcutTester.swift](../../Kaname/Core/Input/ShortcutTester.swift) creates two
  `.listenOnly` taps, head and tail, which observe without intercepting. The worst a failed test
  can do is observe nothing; it cannot freeze input.

## 2. How signing relates to the TCC grant

macOS records the grant against the app's **designated requirement**, not just its path. A new
signature means a new identity, which means the old grant no longer matches — visible as a ticked
checkbox in System Settings while the app still reports that it has no permission.

| Signing method | Actual state this round | Effect on TCC | When to use |
| --- | --- | --- | --- |
| ad-hoc (`codesign -s -`) | The build script's fallback when no certificate exists | The fingerprint changes with the code on every build; **every rebuild may need a re-grant** | Local throwaway builds only |
| `Kaname Local` (self-signed certificate) | **What the current install uses**; `codesign -dv` reports `Authority=Kaname Local` | As long as the certificate and bundle id do not change, a reinstall usually keeps the grant | Everyday local use |
| Developer ID | Not used (no `TeamIdentifier`) | Distribution; Gatekeeper stops blocking once notarized, and TCC still binds to the signing identity | Published releases |

**Fastest recovery after changing the signature**: confirm the stale Kaname entry is gone from
System Settings (click `−` if needed), then launch the app so it asks again. If that still does
not work, quit the app, run
`tccutil reset Accessibility com.suliveevil.kaname` (this clears every Accessibility grant for
that app, so you must tick it again), and reopen the app. Do not delete
`~/Library/Application Support/Kaname` — that loses settings and statistics. Records left over
from before the rename can be cleared with `tccutil reset Accessibility com.suliveevil.kaname`.

What keeps the grant stable: a fixed bundle id (`com.suliveevil.kaname`), a fixed signing
certificate (`Kaname Local`), and no other identity field besides `CFBundleVersion` changing per
build.

### 2.1 Somebody else's Mac: what happens without the `Kaname Local` certificate

| Check | Result | Why |
| --- | --- | --- |
| `codesign --verify --strict` | Usually passes | It checks only that the signature is complete and the code untampered; the self-signed leaf certificate travels inside the CMS signature in the app |
| `codesign -dv` | `Authority=Kaname Local`, `TeamIdentifier=not set` | A self-signed certificate has no Team ID |
| `spctl --assess` | Rejected | No Developer ID and no notarization ticket |
| First launch | Blocked by Gatekeeper | The download carries `com.apple.quarantine`, and assessment fails |
| TCC grant | Still matched by designated requirement | The requirement string is `identifier "com.suliveevil.kaname" and certificate root = H"…"`; the root hash comes from the signature itself, so the user is never asked to import the certificate into a keychain |

What the user actually sees is "cannot verify the developer" / "Apple cannot check it for
malicious software", followed by either:

- **System Settings → Privacy & Security → Open Anyway**; or
- `xattr -dr com.apple.quarantine /Applications/Kaname.app`.

Homebrew 7 removed `--no-quarantine`, so there is no "skip quarantine at install time" spelling;
every `brew upgrade` downloads and quarantines again, and the first launch needs approving once
more.

**Do not tell users to import the `Kaname Local` root certificate and trust it.** It does not
make Gatekeeper pass (what is missing is Apple's notarization, not a local trust setting), and
it puts a self-signed CA into the user's trust chain — a clear security anti-pattern. Self-signing
is for this machine and for beta; distribution needs Developer ID plus notarization.

**When the grant stops working.** TCC binds to the signing identity, so any of the following
produces the "ticked in System Settings, app still says no permission" state: a regenerated
certificate (`scripts/setup_signing.sh` with a new CN or key), a certificate expiry (currently
3650 days), a changed bundle id, or one release built with Developer ID or ad-hoc. Recovery: remove
the stale Kaname entry from System Settings, then launch the app; if that fails,
`tccutil reset Accessibility com.suliveevil.kaname` and grant again. A brew upgrade that keeps the
bundle id and certificate unchanged does not trigger this.

## 3. Entitlements and runtime environment

- **There is no entitlements file**: no `*.entitlements` exists in the repository, and the build
  scripts pass no `--entitlements` argument. So there is no
  `com.apple.security.app-sandbox` and no `com.apple.security.*` exception of any kind.
- **Sandboxing is impossible**, and the reasons are all in the code:
  1. a session-level global tap that can swallow events is unavailable inside a sandbox;
  2. the app must read AX menu trees across process boundaries and `AXPress` them
     ([CatalogLoader.swift](../../Kaname/Core/AX/CatalogLoader.swift),
     [MenuTrigger.swift](../../Kaname/Core/AX/MenuTrigger.swift));
  3. it reads third-party configuration outside its container (Karabiner, Hammerspoon and
     others — see `ConfigScanner`);
  4. the panel must cover other apps and position itself from AX coordinates.
- **Hardened Runtime is on**: the build scripts pass `codesign --force --options runtime`, and a
  measured build reports `flags=0x10000(runtime)`. With no extra entitlements, the default
  hardened-runtime restrictions (JIT, arbitrary dylib injection) stay in force; this app
  depends on none of them.
- **`LSUIElement = true`**: menu-bar resident, no Dock icon by default, no main window. The
  setting that shows a Dock icon flips `NSApp.setActivationPolicy(.regular)` at runtime and does
  not touch `Info.plist`. Because there is no main window, helper tools such as
  `agent-desktop` cannot grab a window before the panel appears (see the environment traps in
  STATUS).

## 4. One-line self-check

```
codesign -dv --verbose=4 /Applications/Kaname.app && ls "$HOME/Library/Application Support/Kaname/logs"
```

- `Authority=Kaname Local`, `flags=0x10000(runtime)` and `TeamIdentifier=not set` are the
  expected values for this round's install; if it reads `Signature=adhoc`, the fallback signing
  was used and the TCC grant may already be void.
- Logs live in `~/Library/Application Support/Kaname/logs/kaname-YYYY-MM-DD.log`; once
  **Settings → General → Diagnostics** has logging on, Accessibility and tap decisions are
  written under the `input` and `ui` categories.
- The authoritative source for whether Accessibility passed is the app's own status in
  **Settings → Permissions** plus the switch in System Settings → Privacy & Security →
  Accessibility; do not trust a single return value from `AXIsProcessTrusted()`, which caches.

## 5. Known documentation/code disagreements (found this round)

- An older version of this page said injection required turning on "Execute menu commands"; the
  current code has removed the `allowPanelExecute` / `allowSearchExecute` switches (see the
  migration comments in `AppSettingsModel`: version 2/3 deleted them). The semantics now are:
  both surfaces take over the keyboard, and running a menu item closes the surface first and
  presses that menu item through Accessibility; the original shortcut is replayed only when there
  is no menu item to press or the press is refused. There is no "execute" switch for the user to
  turn on.
- An older version said flatly that "the tap fails to install"; there are in fact two layers:
  the `.cgSessionEventTap` failing to install (permissions/environment) and the local run-loop
  source failing to install (rolled back in code — see the tap recovery path in
  `KeyboardMonitor`).
