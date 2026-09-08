# Manual verification: app presence lifecycle

Covers the window, Dock, menu bar, Settings, and Launch at Login behavior from issues #2, #22, and #27 that unit tests cannot prove on their own.

Re-run this checklist whenever the app's scenes, activation policy, signing, Launch at Login, or menu bar presence code changes.

## Preparation

```bash
./Scripts/build-app.sh -configuration Release
APP="$PWD/.build/DerivedData/Build/Products/Release/OhMyTheme.app"
mkdir -p "$HOME/Applications"
ditto "$APP" "$HOME/Applications/OhMyTheme.app"
APP="$HOME/Applications/OhMyTheme.app"
```

Use a stable location because macOS records the app URL for Launch at Login. Record the selected Theme Variant and the hashes of connected Target paths before testing. Also record the current macOS appearance if that Target is connected.

## Checks

### 1. Window-first launch

```bash
/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$APP/Contents/Info.plist"              # true
/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" # 14.0
codesign -dvv "$APP" 2>&1 | grep Signature                                             # adhoc (local signing)
codesign -d --entitlements - "$APP" 2>/dev/null | grep app-sandbox                     # no match
open "$APP"
```

Confirm one main window opens with Overview, Themes, and Apps in the sidebar. The Dock icon and menu bar item must both be visible.

### 2. Minimal menu

Open the menu bar item. It must contain only Workspace health, **Open Oh My Theme**, and **Quit Oh My Theme**. It must not contain theme, Target, setup, apply, or Launch at Login controls.

### 3. Reusable main window

With the main window open, select **Open Oh My Theme** several times and launch the app again from Finder or Spotlight. The existing window must come forward. No duplicate main window may appear.

Close the main window. Confirm the Dock icon disappears while the menu bar item and process remain. Select **Open Oh My Theme** and confirm the same main window returns and the Dock icon reappears.

### 4. Settings and notification status

Open Settings and confirm it contains menu bar visibility, Launch at Login, and the current notification permission status. Change notification authorization in System Settings, reopen Settings, and confirm the displayed status refreshes.

### 5. Launch at Login is opt-in

Use a macOS account that has not registered `com.ohmytheme.OhMyTheme` before. Confirm **Launch at login** is off.

Turn it on. Confirm **OhMyTheme** appears in **System Settings > General > Login Items & Extensions > Open at Login**. If approval is required, confirm Settings explains where to approve it.

Turn it off and confirm OhMyTheme disappears from **Open at Login**.

### 6. Hiding the menu bar item

Enable Launch at Login, then turn off **Show menu bar item**. Confirm Oh My Theme first unregisters Launch at Login, then hides the menu bar item. The Launch at Login control must become unavailable and explain why.

If unregistering fails, the menu bar item must remain visible and Settings must show the failure. Do not accept a state where the menu bar item is hidden while Launch at Login remains active.

Launch the running app from Finder or Spotlight and confirm the main window still reopens. Turn **Show menu bar item** back on and confirm the item returns.

### 7. Menu-bar removal recovery

Hold Command and drag the Oh My Theme icon out of the menu bar. Quit and relaunch the app. The icon must return when the app preference still says to show it.

The removal preference can also be simulated without a mouse:

```bash
defaults write com.ohmytheme.OhMyTheme "NSStatusItem Visible OhMyThemeItem-0" -bool false
defaults write com.ohmytheme.OhMyTheme "OhMyThemeUnrelatedPreference" -bool true
open "$APP"; sleep 4
defaults read com.ohmytheme.OhMyTheme   # visibility key gone, unrelated preference intact
```

### 8. Quit preserves Workspace state

Enable Launch at Login, then select **Quit Oh My Theme** from the menu bar. The icon and Dock entry disappear, and no process remains:

```bash
pgrep -lf "OhMyTheme.app/Contents/MacOS/OhMyTheme"   # no output
```

Confirm OhMyTheme remains enabled in **Open at Login**. Recompute the recorded Target path hashes and check the macOS appearance. Quit must not change them. Turn Launch at Login off after this check if you do not want the app to open at the next login.

## Record

| Date | Version | macOS | Xcode | Result |
| --- | --- | --- | --- | --- |
| Pending | Pending | Pending | Pending | Run required for the window-first app |

The automated app-presence tests cover state transitions and platform requests through fakes. A human run must still verify actual Dock behavior, SwiftUI window reuse, menu insertion, ServiceManagement registration, and notification authorization reporting on macOS.
