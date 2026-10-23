# Permissions

KagiPeek needs **Accessibility** to work. **Input Monitoring** is an optional fallback for systems where macOS does not deliver key events to KagiPeek with Accessibility alone. Both are used locally, and neither gives KagiPeek access to your documents, accounts, or the text you type.

| Permission | Status | What KagiPeek uses it for | What happens without it |
| --- | --- | --- | --- |
| **Accessibility** | **Required** | Reading the frontmost app's menu bar through the Accessibility API, creating the global key tap, and pressing a menu item when you explicitly enable one of the execute options (search or panel) | No live menu data and no key tap: KagiPeek can only show the built-in fallback catalog and cannot react to your keys. |
| **Input Monitoring** | Optional fallback | Receiving global key events on systems where the tap created with Accessibility alone does not receive them | On most Macs nothing. If your system gates key events, the panel cannot be triggered until this is granted. |

macOS sometimes labels these panes slightly differently between releases. Accessibility and Input Monitoring are always separate toggles.

## Why Accessibility is required

Accessibility is the primary grant, and it covers the three things KagiPeek does:

- **Reading menus.** KagiPeek walks the frontmost app's `AXMenuBar` → `AXMenuBarItem` → `AXMenu` → `AXMenuItem` tree and reads `AXMenuItemCmdChar`, `AXMenuItemCmdVirtualKey`, `AXMenuItemCmdGlyph`, `AXMenuItemCmdModifiers`, and `AXEnabled`. It never reads window contents, text fields, or documents.
- **Creating a global key tap.** The tap observes modifier and key state so the panel can open and be navigated. It passes events through untouched except its own panel, search, and switch hotkeys and the active panel's navigation keys, which it consumes so the front app does not also receive them. A shortcut that completes a row is not consumed: the front app still receives it. It never records or synthesizes events.
- **Pressing a menu item on request.** If you turn on **Execute menu commands from search** or **Execute menu commands from the panel**, Return (or a click in the panel) calls `AXPress` on the selected menu item. Both are off by default and still use Accessibility, not synthetic keystrokes.

The enabled macOS system shortcuts (Spotlight, Mission Control, …) that appear in the conflict list are read through Carbon's `CopySymbolicHotKeys`, which needs no privacy grant. KagiPeek only reads that list to report collisions; it never binds, changes, or disables a system shortcut.

## When Input Monitoring is needed

Some macOS versions and configurations do not deliver key events to a tap created with Accessibility alone. On those systems, grant **Input Monitoring** as a fallback. KagiPeek checks the two grants separately and points to Input Monitoring only when it is the missing piece.

In practice:

1. Grant Accessibility first.
2. Try holding ⌘. If the panel opens, you do not need Input Monitoring.
3. If nothing happens, grant Input Monitoring and relaunch KagiPeek.

Input Monitoring does not help with menu reading, and Accessibility alone cannot read a menu without being granted. They are never a substitute for each other; Input Monitoring is only about key delivery.

## Granting permission

1. Launch KagiPeek. The main window appears; if Accessibility is missing it shows a banner. **Settings → Permissions** lists both grants, their current status, and marks Accessibility as required.
2. In KagiPeek, open **Settings → Permissions** and click **Request** next to **Accessibility**. KagiPeek shows the system authorization prompt **and** opens **System Settings → Privacy & Security → Accessibility** for you; switch KagiPeek on there.
   - If KagiPeek is not in the list, drag the KagiPeek icon shown in the Permissions tab straight into the list, or click **+**, choose **Applications → KagiPeek.app**, and switch it on.
3. Try holding ⌘ in another app. If the panel appears, you are done.
4. If no panel appears, quit KagiPeek. Click **Request** next to **Input Monitoring** (it likewise opens the matching pane), switch KagiPeek on there, then reopen KagiPeek.
5. Check **Settings → Permissions** in KagiPeek to confirm the current state.

The macOS authorization dialog is shown by the system, not by KagiPeek. KagiPeek never asks for an administrator password and does not install a privileged helper.

The Permissions tab's icon is a real drag source. Dropping it on the Accessibility or Input Monitoring list adds the running app even when the list is empty; this is often faster than using **+**, and it is the same app macOS will later remember. The icon only adds the entry — you still have to toggle it on.

> If you use a managed Mac, an MDM profile may pre-approve or block these permissions. In that case the toggles can be greyed out; contact your administrator.

## Installing over an older version or replacing a build

macOS remembers privacy grants by a combination of bundle identifier, code-signing identity, and app location. **Replacing KagiPeek with a build that has a different signature invalidates the old grant**, and the app will not work until the new copy is approved again.

- **v1.1 → v1.2:** the bundle identifier changed from `com.Voltline.KagiPeek` to `com.voltline.kagipeek`, so macOS treats v1.2.0 as a new app. Re-grant Accessibility (and Input Monitoring if you use it).
- **v1.2 → v2.0 and v2.0 → v2.1:** the bundle identifier did not change, so a signed update keeps its existing grants. The v1.1 → v1.2 exception above still applies if you skipped a release.
- **Replacing a local or ad-hoc build:** every rebuild can look like a different app. Remove the old KagiPeek entry with the **−** button, add the new build, and enable it.
- **Official signed releases:** a Developer ID build with a stable identity normally keeps its grant across updates, but the v1.1 → v1.2 bundle identifier change is an exception and requires re-approval.
- **Two copies** (for example one in `/Applications` and one in `~/Downloads`) create separate entries. Keep a single copy.

If the toggle looks enabled but KagiPeek still reports a missing permission, remove the entry and add it again, or reset the grant below.

## Resetting permissions

```bash
# Reset the Accessibility grant for KagiPeek
tccutil reset Accessibility com.voltline.kagipeek

# Reset the Input Monitoring grant (only relevant if you granted it)
tccutil reset ListenEvent com.voltline.kagipeek

# Or reset every privacy grant for KagiPeek at once
tccutil reset All com.voltline.kagipeek
```

Then relaunch KagiPeek and grant the permissions again. The service names used by `tccutil` are not part of a public API, but `Accessibility` and `ListenEvent` are the names used by current macOS releases. If your macOS version does not recognise them, remove KagiPeek from each pane with the **−** button instead.

Resetting permissions only forgets that you approved KagiPeek. It does not delete KagiPeek's settings or usage statistics — those are separate JSON files in `~/Library/Application Support/KagiPeek/` (`settings.json`, `usage.json`), independent of the privacy database. Remove that folder if you want a full reset.

## Secure input

Some apps — password fields, login windows, and certain terminals — turn on macOS **secure event input**. While it is active, macOS deliberately hides key events from event taps and from other apps. KagiPeek detects secure input and hides its panel immediately. This is intentional and is one of the reasons KagiPeek never records raw keystrokes.

KagiPeek does post events in exactly one situation: when you run a row (the run key, a click, or Return in the search palette), it replays that row's single chord into the front app and stops. Nothing is posted while you browse the panel, and the copy key never posts anything.

If the panel refuses to reappear after you leave a password field, another app may still be holding secure input. Quit the app that owns the focused password field, or log out and back in. You can inspect the current owner of secure input with:

```bash
ioreg -l -w 0 | grep SecureInput
```

## What KagiPeek never asks for

KagiPeek does not request, and does not need:

- Screen Recording
- Full Disk Access
- Automation / Apple Events
- Camera, Microphone, Contacts, or Calendars
- Network access for analytics or accounts

The only network request KagiPeek makes is the manual update check: when you press **Check for updates** in **Settings → About**, it downloads the public GitHub release document once. The request carries no personal, app, or shortcut data, and nothing runs in the background.

The app is distributed outside the Mac App Store with App Sandbox disabled, because reading another app's menu bar and observing global key events are incompatible with the sandbox. See the [FAQ](FAQ.md#why-isnt-kagipeek-on-the-mac-app-store) for the longer explanation.

## Verifying a downloaded build

If you want to check what you are running before granting permissions:

```bash
# Show the signing identity and bundle identifier
codesign -dv --verbose=4 /Applications/KagiPeek.app

# Verify the signature and sealed resources
codesign --verify --deep --strict --verbose=2 /Applications/KagiPeek.app

# Ask Gatekeeper how it assesses the app
spctl --assess --type execute --verbose=4 /Applications/KagiPeek.app
```

A notarized release reports `source=Notarized Developer ID`. An ad-hoc build reports `Signature=adhoc` and will not be notarized; that is expected for local builds.

## Troubleshooting

| Symptom | What to try |
| --- | --- |
| Permission toggle is on, but KagiPeek says it is missing | Remove KagiPeek with **−** in that pane, add the current app again, and relaunch. Replacing the app changes its signature. |
| KagiPeek does not appear in the Accessibility list | Launch the app first, then open the pane; drag the icon from **Settings → Permissions** into the list, or add `/Applications/KagiPeek.app` with **+**. |
| Menu shortcuts work, but holding keys does nothing | Grant Input Monitoring (optional fallback), quit, and reopen KagiPeek. |
| Panel disappears in password fields | Secure input is active; this is intentional. |
| Permission resets after every rebuild | Ad-hoc signing changes the app identity. Use a Developer ID build for stable grants, or re-add the build each time. |