# Manual verification: menu-bar lifecycle

Covers the behavior in [issue #2](https://github.com/abdullahnettoor/ohmytheme/issues/2) that automated tests cannot prove on their own: that the locally signed app really runs as a menu-bar utility, recovers its menu-bar presence, relaunches normally, and quits when asked.

Re-run this checklist whenever the app's scene, activation policy, signing, or menu-bar presence code changes, and record the result below.

## Preparation

```bash
./Scripts/build-app.sh -configuration Release
APP="$PWD/.build/DerivedData/Build/Products/Release/OhMyTheme.app"
```

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

Click the menu-bar icon. The window shows the **My Mac** Workspace, the empty-state sentence explaining that no apps are connected yet, and a **Quit Oh My Theme** button.

### 3. Menu-bar removal recovery

Hold Command and drag the Oh My Theme icon out of the menu bar. The icon disappears; the app keeps running. Quit it (`osascript -e 'tell application id "com.ohmytheme.OhMyTheme" to quit'`) and launch it again: the icon returns.

The removal preference AppKit writes can also be simulated without a mouse:

```bash
defaults write com.ohmytheme.OhMyTheme "NSStatusItem Visible OhMyThemeItem-0" -bool false
defaults write com.ohmytheme.OhMyTheme "OhMyThemeUnrelatedPreference" -bool true
open "$APP"; sleep 4
defaults read com.ohmytheme.OhMyTheme   # visibility key gone, unrelated preference intact
```

### 4. Ordinary relaunch

Quit and launch again. The app returns to the menu bar with the same empty state, and does not open a window or change anything on the system.

### 5. Explicit Quit

Click **Quit Oh My Theme**. The icon disappears and no `OhMyTheme` process remains:

```bash
pgrep -lf "OhMyTheme.app/Contents/MacOS/OhMyTheme"   # no output
```

## Record

| Date | Version | macOS | Xcode | Result |
| --- | --- | --- | --- | --- |
| 2026-09-02 | 0.1.0 (build 1) | 26.5.2 | 26.1 (17B55) | Partial — machine-checkable steps pass, on-screen steps pending |

What the 2026-09-02 run proved:

- Check 1 (bundle and process): `LSUIElement` is `true`, `LSMinimumSystemVersion` is `14.0`, the signature is ad-hoc, no `app-sandbox` entitlement is present, and `lsappinfo` reported the running app as `type="UIElement"`.
- Check 3 (simulated removal): with `NSStatusItem Visible OhMyThemeItem-0` and `OhMyThemeUnrelatedPreference` seeded, the next launch removed the visibility key and left the unrelated preference untouched.
- Check 4 (relaunch): launching again produced a running process with no window.
- Check 5 (termination): quitting through the application's terminate path ended the process. The button that reaches that path is covered by the app-hosted test `testQuitAsksTheApplicationToTerminate`.

What the 2026-09-02 run did not prove, and a human at the machine still needs to do:

- Check 2 in full: nobody opened the menu window, so the on-screen Workspace name, empty state, and Quit button are unconfirmed.
- The Command-drag removal in check 3. Launching the app writes no status-item preferences at all (`defaults read com.ohmytheme.OhMyTheme` reports no domain), so the key AppKit writes when a user removes the item has not been observed for this app. `MenuBarPresence.visibilityKeyPrefix` assumes the conventional `NSStatusItem Visible` prefix. Record the key AppKit actually writes during the next run, and correct the prefix if it differs.
- The on-screen halves of checks 1 and 5: seeing the icon appear in the menu bar, and seeing it disappear after clicking Quit.

Menu-bar presence does not depend on that assumption alone: the app never persists its own insertion state (`OhMyThemeApp.isMenuBarItemInserted`), so an ordinary relaunch asks for the item again regardless. Clearing the remembered AppKit preference is the second half of that recovery.
