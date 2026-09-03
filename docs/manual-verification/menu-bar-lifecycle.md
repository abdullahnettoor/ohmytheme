# Manual verification: menu-bar lifecycle

Covers the behavior in [issue #2](https://github.com/abdullahnettoor/ohmytheme/issues/2) and [issue #22](https://github.com/abdullahnettoor/ohmytheme/issues/22) that automated tests cannot prove on their own: the locally signed app runs as a menu-bar utility, registers through macOS Launch at Login only when asked, starts without applying a theme, recovers its menu-bar presence, and quits without changing connected Targets.

Re-run this checklist whenever the app's scene, activation policy, signing, or menu-bar presence code changes, and record the result below.

## Preparation

```bash
./Scripts/build-app.sh -configuration Release
APP="$PWD/.build/DerivedData/Build/Products/Release/OhMyTheme.app"
mkdir -p "$HOME/Applications"
ditto "$APP" "$HOME/Applications/OhMyTheme.app"
APP="$HOME/Applications/OhMyTheme.app"
```

Use a stable location because macOS records the app URL for Launch at Login. For the passive-startup and Quit checks, record the selected Theme Variant and hash every connected Target path disclosed by its connection review before proceeding. Also record the current macOS appearance if that Target is connected.

## Checks

### 1. Menu-bar utility, locally signed, no App Sandbox

```bash
/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$APP/Contents/Info.plist"          # true
/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" # 14.0
codesign -dvv "$APP" 2>&1 | grep Signature                                          # adhoc (local signing)
codesign -d --entitlements - "$APP" 2>/dev/null | grep app-sandbox                  # no match
open "$APP"
lsappinfo list | grep -A4 com.ohmytheme.OhMyTheme                                    # type="UIElement"
```

Then look at the screen: the Oh My Theme icon is in the menu bar, and no Dock icon or window appears.

### 2. Menu contents

Click the menu-bar icon. The window shows the **My Mac** Workspace, the current Targets and Theme Variant, a **Launch at Login** toggle, and a **Quit** button.

### 3. Launch at Login is opt-in

Use a macOS account that has not registered `com.ohmytheme.OhMyTheme` before. Launch the app and confirm **Launch at Login** is off. If this account has run an earlier build, turn the toggle off first and treat that as the baseline instead.

Turn the toggle on. Confirm **OhMyTheme** appears and is enabled in **System Settings > General > Login Items & Extensions > Open at Login**. If the menu says approval is required, approve it in that pane and reopen the Oh My Theme menu to confirm the status updates.

### 4. Login launch stays passive

With Launch at Login enabled, quit Oh My Theme, then log out and back in. Confirm its menu-bar item appears without opening a Dock window. Open the menu and confirm the selected Theme Variant and connected Targets are unchanged. Confirm there is no new Apply Report. Recompute the recorded Target path hashes and check the macOS appearance. None may have changed during login launch.

### 5. Disable Launch at Login

Turn **Launch at Login** off and confirm OhMyTheme disappears from **Open at Login**. Quit, log out, and log back in. Confirm Oh My Theme does not launch. Open it manually before continuing.

### 6. Menu-bar removal recovery

Hold Command and drag the Oh My Theme icon out of the menu bar. The icon disappears while the app keeps running. Quit it with `osascript -e 'tell application id "com.ohmytheme.OhMyTheme" to quit'`, then launch it again. The icon must return.

The removal preference AppKit writes can also be simulated without a mouse:

```bash
defaults write com.ohmytheme.OhMyTheme "NSStatusItem Visible OhMyThemeItem-0" -bool false
defaults write com.ohmytheme.OhMyTheme "OhMyThemeUnrelatedPreference" -bool true
open "$APP"; sleep 4
defaults read com.ohmytheme.OhMyTheme   # visibility key gone, unrelated preference intact
```

### 7. Ordinary relaunch

Quit and launch again. The app returns to the menu bar with the same presentation state. It must not open a Dock window, create an Apply Report, or change connected Target configuration.

### 8. Explicit Quit preserves state

Enable Launch at Login, then click **Quit**. The icon disappears and no `OhMyTheme` process remains:

```bash
pgrep -lf "OhMyTheme.app/Contents/MacOS/OhMyTheme"   # no output
```

Confirm OhMyTheme remains enabled in **Open at Login**. Recompute the recorded Target path hashes and check the macOS appearance. Quit must not change either one. Turn Launch at Login off after this check if you do not want the app to open at the next login.

## Record

| Date | Version | macOS | Xcode | Result |
| --- | --- | --- | --- | --- |
| 2026-09-02 | 0.1.0 (build 1) | 26.5.2 | 26.1 (17B55) | Partial — machine-checkable steps pass, on-screen steps pending |

What the 2026-09-02 run proved:

- Check 1 (bundle and process): `LSUIElement` is `true`, `LSMinimumSystemVersion` is `14.0`, the signature is ad-hoc, no `app-sandbox` entitlement is present, and `lsappinfo` reported the running app as `type="UIElement"`.
- The simulated-key portion of check 6: with `NSStatusItem Visible OhMyThemeItem-0` and `OhMyThemeUnrelatedPreference` seeded, the next launch removed the visibility key and left the unrelated preference untouched.
- The ordinary relaunch portion of check 7: launching again produced a running process with no window.
- The termination portion of check 8: quitting through the application's terminate path ended the process. The button that reaches that path is covered by the app-hosted test `testQuitOnlyAsksTheApplicationToTerminate`.

What the 2026-09-02 run did not prove, and a human at the machine still needs to do:

- Check 2 in full: nobody opened the menu window, so the on-screen Workspace name, empty state, and Quit button are unconfirmed.
- The Command-drag removal in check 6. Launching the app writes no status-item preferences at all (`defaults read com.ohmytheme.OhMyTheme` reports no domain), so the key AppKit writes when a user removes the item has not been observed for this app. `MenuBarPresence.visibilityKeyPrefix` assumes the conventional `NSStatusItem Visible` prefix. Record the key AppKit actually writes during the next run, and correct the prefix if it differs.
- The on-screen portions of checks 1 and 8: seeing the icon appear in the menu bar, and seeing it disappear after clicking Quit.

Menu-bar presence does not depend on that assumption alone: the app never persists its own insertion state (`OhMyThemeApp.isMenuBarItemInserted`), so an ordinary relaunch asks for the item again regardless. Clearing the remembered AppKit preference is the second half of that recovery.
