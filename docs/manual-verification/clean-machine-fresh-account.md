# Clean-machine and fresh-account checklist

Use this checklist for issue #23's end-to-end manual run. A newly created local macOS test account is acceptable when a separate clean machine is unavailable. Do not use a personal account with irreplaceable Ghostty, Starship, VS Code, or wallpaper state.

All checks start as pending. Add a dated result only after performing the step on the named app build and target versions.

## 1. Privacy and recording rules

- [ ] Use a dedicated local test account with no copied dotfiles and no cloud-synced settings.
- [ ] Do not paste configuration contents into this record.
- [ ] Refer to targets as `System Appearance`, `display A`, `display B`, `Ghostty`, `VS Code Stable Default`, `VS Code Insiders Default`, `VS Code named profile`, and `Starship`.
- [ ] Record file hashes before and after a step, not file contents. Keep the hash worksheet outside committed files if it includes private paths.
- [ ] Do not record account names, home paths, wallpaper URLs, VS Code opaque profile IDs, process IDs, window IDs, socket paths, nonces, or raw logs containing those values.
- [ ] Take screenshots only after checking that they contain no source code, filenames, terminal history, account names, or config values.

## 2. Machine and target preparation

- [ ] Record the date, Oh My Theme version/build, macOS version, Mac model class, Xcode version, and whether this is a clean machine or fresh local account.
- [ ] Install Ghostty 1.3.x and record the exact version. Create a minimal synthetic config in the fresh account. Use comments and settings made only for this test.
- [ ] Install Starship and record the exact version. Create a minimal synthetic `starship.toml` and enable Starship in the test shell.
- [ ] Install standard Microsoft VS Code Stable and Insiders, each at version 1.90 or later in the 1.x line. Record both versions.
- [ ] In each edition, keep the Default profile and create one named test profile. Do not record the generated profile identifier.
- [ ] Install the Catppuccin Mocha color theme in the profiles used for the Catppuccin run. Oh My Theme Aurora is bundled with the pinned companion.
- [ ] Open two windows in the edition and Default profile that the run will select. Open one window in its named profile and one Default-profile window in the other edition.
- [ ] If more than one display is available, connect all displays before launching Oh My Theme. Create at least two Spaces on one display and, where macOS allows it, a full-screen Space.
- [ ] Set System Appearance to Dark before the repeated-switch sequence. Both bundled variants are dark, which makes the expected Appearance report deterministic.
- [ ] Record the visible wallpaper and placement for each display and Space using neutral labels only. Do not record wallpaper file URLs.

Both bundled Theme Variants, Catppuccin Mocha and Oh My Theme Aurora, contain no wallpaper. No step in this checklist should change wallpaper.

## 3. Build and first launch

Run from the repository root:

```bash
./Scripts/build-app.sh -configuration Release
APP="$PWD/.build/DerivedData/Build/Products/Release/OhMyTheme.app"
mkdir -p "$HOME/Applications"
ditto "$APP" "$HOME/Applications/OhMyTheme.app"
APP="$HOME/Applications/OhMyTheme.app"
open "$APP"
```

- [ ] Confirm the app appears only in the menu bar.
- [ ] Confirm no Dock icon and no ordinary app window appears.
- [ ] Open the menu and confirm the Workspace name is `My Mac`.
- [ ] Confirm Launch at Login is off.
- [ ] Confirm no Apply Report exists on first launch.
- [ ] Confirm the target rows are macOS, Ghostty, Visual Studio Code, and Starship.
- [ ] Confirm the macOS row gives the number of discovered displays and says wallpaper stays unchanged.
- [ ] Confirm the Theme Variant picker lists `Catppuccin Mocha` as upstream and `Oh My Theme Aurora` as generated.
- [ ] Confirm neither variant preview lists a wallpaper change.

## 4. Review and connect each Target

For every connection, select `Review connection` first. Record only the displayed categories and outcome text, not private path values.

### System Appearance

1. Reset Apple Events consent:

   ```bash
   /usr/bin/tccutil reset AppleEvents com.ohmytheme.OhMyTheme
   ```

2. Reopen Oh My Theme. Before clicking a connection action, confirm the System Appearance row says `Automation access to System Events is required to read and change the system Light/Dark appearance.` No prompt should appear during discovery.
3. Select `Review connection`. The review preparation performs the first appearance read, so macOS should now show the Automation prompt.
4. Grant the prompt. Confirm the completed review says it will record the current Light/Dark appearance and lists the same Automation requirement.
5. Select `Approve and connect`.
6. Confirm the connection report says `Connection updated`, then shows `Connection`, `Already set`, `Current windows`, and the detail that Automation is available and the current appearance was recorded.
7. Confirm System Appearance is now connected and no appearance change occurred during connection.

### Ghostty

1. Select `Review connection` for Ghostty.
2. Confirm the review names one managed include, one managed fragment, `Ghostty: configuration reload required`, and `Press cmd+shift+,`.
3. If the synthetic config is a symlink, confirm the resolved source requires a second explicit approval. Do not continue if the path is Nix or Home Manager managed.
4. Select `Approve and connect`.
5. Confirm the connection report says `Connection updated`, then shows `Connection`, `Updated` or `Already set`, `Reload required`, and the reload user action.
6. Press `cmd+shift+,` in Ghostty before continuing.

### Visual Studio Code

1. With Stable and Insiders both installed, confirm the Visual Studio Code row asks which edition should join My Mac.
2. Choose the edition assigned to this run and select `Review connection` for its `Default profile` option.
3. Confirm the review names the pinned companion, the selected standard Microsoft bundle, Default profile, global `workbench.colorTheme` scope, and local Unix socket behavior.
4. Select `Approve and connect`.
5. Keep both Default-profile windows for the selected edition open until the companion registers.
6. Confirm the connection report says `Connection updated`, then shows `Connection`, `Updated` or `Already set`, and `Current windows`.
7. Confirm the connected Target name identifies the selected edition and Default profile. The other edition and named profile remain unselected.

The current production UI supports the Default profile only. Named profiles, custom `--user-data-dir` sessions, remote extension hosts, and single-window selection are outside this qualification target.

### Starship

1. Select `Review connection` for Starship.
2. Confirm the review limits ownership to the theme palette keys and says activation occurs at the next prompt.
3. If the synthetic config is a symlink, approve only the dedicated test source. Do not continue if the path is Nix or Home Manager managed.
4. Select `Approve and connect`.
5. Confirm the connection report says `Connection updated`, then shows `Connection`, `Already set`, and `Next launch`. Connection itself does not edit the Starship config.

## 5. Clean Automation denial and partial Workspace report

This case starts with System Appearance already connected, so a later denial appears in the same Workspace Apply Report as successful developer Targets.

1. Confirm Ghostty, the selected VS Code Default profile, and Starship are connected.
2. Reset Apple Events consent again:

   ```bash
   /usr/bin/tccutil reset AppleEvents com.ohmytheme.OhMyTheme
   ```

3. Select `Oh My Theme Aurora`, then select `Preview workspace change`.
4. When macOS asks whether Oh My Theme may control System Events, choose `Don't Allow`.
5. Confirm the preview identifies an Automation permission need for System Appearance and still contains ready plans for independent Targets.
6. Select `Apply to ready Targets`.
7. Confirm the report title is `Theme applied with remaining work`.
8. Confirm the System Appearance group contains `Appearance`, `Permission required`, no reach line, and `No rollback needed`.
9. Confirm Ghostty reports `Updated`, `Reload required`, and `Undo available`.
10. Confirm the selected VS Code profile reports `Updated`, `Current windows`, and `Undo available`.
11. Confirm Starship reports `Updated`, `Next prompt`, and `Undo available`.
12. Confirm the unselected VS Code edition and named profile did not change.
13. Confirm every wallpaper on every observed display and Space is unchanged.
14. Select `Undo Last Theme Change`. Confirm the successful Ghostty, VS Code, and Starship changes return to their pre-apply state while the unchanged Appearance outcome needs no rollback.
15. Complete the required Ghostty reload and Starship next-prompt checks for that Undo.
16. In System Settings, grant Automation access before the full-switch sequence. Reopen the menu and prepare a new preview so it does not reuse the denied preview.

If any successful Target is rolled back only because Appearance was denied, or if Appearance says `Already set`, `Failed`, or `Current windows`, mark this check failed.

## 6. Repeated full-Workspace switches

Use the detailed expected report table in [`workspace-theme-apply.md`](workspace-theme-apply.md).

- [ ] Apply Aurora and capture the sanitized outcome text.
- [ ] Press `cmd+shift+,` in Ghostty and confirm both existing Ghostty windows repaint.
- [ ] Press Return in the Starship shell and confirm the next prompt changes while the previous prompt remains unchanged.
- [ ] Apply Catppuccin Mocha and repeat the Ghostty and Starship activation checks.
- [ ] Apply Aurora again and repeat the activation checks.
- [ ] After every apply, confirm both selected VS Code Default-profile windows change without reload.
- [ ] After every apply, confirm the named profile and the unselected edition remain unchanged.
- [ ] After every apply, confirm all wallpapers remain unchanged.
- [ ] Confirm no setting outside Ghostty's managed fragment or Starship's registered palette ownership changed by comparing the pre-run and current hashes or a syntax-aware diff in the test account. Do not commit the diff.

## 7. Undo

1. After the final Aurora apply, select `Undo Last Theme Change` once.
2. Confirm the title is `Theme change undone`.
3. Confirm Ghostty, selected VS Code Default profile, and Starship return to Catppuccin.
4. Confirm changed outcomes say `Restored`.
5. Confirm Ghostty says `Reload required`; press `cmd+shift+,` and verify the existing windows.
6. Confirm Starship says `Next prompt`; create the next prompt and verify it.
7. Confirm the unselected VS Code edition, named profile, and all wallpapers remain unchanged.

## 8. External-edit conflicts

Use only the synthetic files in the fresh account. Before editing, save a private local backup outside the repository. Never paste the file into the qualification record.

### Ghostty and Starship guarded Undo

1. Apply Aurora so both Ghostty and Starship report `Updated`.
2. Add one valid, harmless comment to the managed Ghostty fragment after Apply.
3. Add one valid, harmless comment outside Oh My Theme's owned Starship palette keys after Apply.
4. Record hashes of the two externally edited files.
5. Select `Undo Last Theme Change`.
6. Confirm Ghostty and Starship each show `Conflict` and `Restore blocked`.
7. Confirm both hashes still match the post-edit hashes. Oh My Theme must not remove either comment.
8. If another Target safely restores, confirm the report title is `Theme change undone with remaining work` and that Target says `Restored`.
9. Restore the synthetic files from the private backups before another qualification case.

### Write-boundary conflict

1. Prepare a Workspace preview.
2. Before selecting `Apply to ready Targets`, add a valid harmless comment to either the Ghostty managed fragment or Starship config.
3. Apply the prepared preview.
4. Confirm that Target reports `Conflict`, no reach, and `Restore blocked`, while independent ready Targets continue.
5. Confirm the external comment remains unchanged.

### VS Code conflict

Follow [`vscode-theme-switch.md`](vscode-theme-switch.md), section `External-edit conflict`. The manually selected theme must remain active after guarded Undo refuses.

## 9. Available displays and Spaces

1. Open each Space on each available display and note the wallpaper by neutral label.
2. Return to the first Space and open Oh My Theme.
3. Confirm the macOS row reports the correct connected-display count.
4. Preview and apply both bundled variants.
5. Revisit every observed Space and full-screen Space.
6. Confirm every wallpaper remains unchanged. Both bundled variants contain no wallpaper.
7. Record the number and type of Spaces observed, not wallpaper URLs.
8. Record this limitation exactly: Oh My Theme can discover connected displays through public APIs, but it cannot enumerate every Space. Static wallpaper support, when a future or test variant contains an asset, is limited to selected connected displays and the active Space behavior returned by macOS. It does not promise every Space, dynamic wallpaper, or scheduled collections.

## 10. VS Code edition and profile repeat

Repeat sections 3 through 8 with the other VS Code edition selected. Use another fresh local account or return every connected Target to its baseline and disconnect it through the app before starting. Do not delete Oh My Theme's persistence files by hand as a substitute for Disconnect.

- [ ] Stable selected, Stable Default windows changed, Stable named profile and Insiders unchanged.
- [ ] Insiders selected, Insiders Default windows changed, Insiders named profile and Stable unchanged.
- [ ] A workspace-level color-theme override stayed active, and the report said the current workspace setting overrides the stored profile theme without claiming `Current windows`.

## 11. Restore and Disconnect

Restore and Disconnect is one guarded action. It restores the original Connection Baseline and removes the Target from My Mac only when current state still matches Oh My Theme's managed state.

For System Appearance, Ghostty, the selected VS Code Target, and Starship:

1. Start from a fresh connection, apply a Theme Variant, and open `Connection recovery`.
2. Select `Disconnect…` for the Target.
3. Confirm the dialog names `Restore and Disconnect`, explains that the Connection Baseline will return, and says external changes will not be overwritten.
4. Confirm the action.
5. Confirm the report title is `Target restored and disconnected` and the Target is no longer connected.
6. Confirm the original Connection Baseline returned exactly.
7. For Ghostty, require `Reload required`, press `cmd+shift+,`, and verify existing windows.
8. For Starship, require `Next prompt` and verify the next prompt.
9. For System Appearance and VS Code, require `Current windows` when baseline restoration is active.
10. If the VS Code companion existed before connection, confirm the action leaves it installed. If Oh My Theme installed it, confirm the action removes only that owned installation.
11. Reconnect with another synthetic baseline, apply, make a harmless external edit, and retry Restore and Disconnect. Confirm the action refuses, reports `Conflict` and `Restore blocked`, keeps the Target connected, and preserves the edit.

## 12. Menu-bar lifecycle

Complete [`menu-bar-lifecycle.md`](menu-bar-lifecycle.md) without resetting the connected Workspace.

- [ ] Ordinary Quit and relaunch preserve the selection and connections without applying.
- [ ] Launch at Login starts passively and creates no Apply Report.
- [ ] Command-drag removal recovers on relaunch.
- [ ] Explicit Quit changes no target hash, appearance, VS Code theme, prompt config, or wallpaper.

## 13. Result record

| Date | App build | macOS | Target versions | Displays and Spaces | Result | Limits or failures |
| --- | --- | --- | --- | --- | --- | --- |
| Pending | Pending | Pending | Pending | Pending | Pending | Pending |

Apply the fail or narrow-support rule in [`issue-23-qualification-matrix.md`](issue-23-qualification-matrix.md). Developer ID, notarization, packaging, updates, telemetry, pricing, and external beta remain deferred and are not part of this run.
