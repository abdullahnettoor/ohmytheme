# My Mac Workspace theme apply

Use this checklist to qualify issue #21 behavior as part of issue #23. Run it through the menu-bar app on a fresh local test account with synthetic Ghostty and Starship configs. Do not record config contents, private paths, profile IDs, nonces, or raw user values.

## Start clean

1. Complete [`clean-machine-fresh-account.md`](clean-machine-fresh-account.md) through target connection.
2. Open the paint-palette item in the menu bar.
3. Confirm My Mac lists macOS, Ghostty, Visual Studio Code, and Starship at the application level.
4. Confirm normal rows do not expose internal Target Instance identifiers. Ambiguous or unavailable rows may show installation, profile, or configuration-path detail for review, but do not copy those values into this record.
5. Set macOS to Dark before the repeated-switch run. Both bundled variants are dark.
6. Install Catppuccin Mocha in the selected VS Code Default profile. The pinned companion includes Oh My Theme Aurora.
7. Keep two windows open in the selected VS Code edition's Default profile. Keep a named-profile window and a window in the unselected edition open as negative controls.
8. Open two Ghostty windows and one Starship shell.

Both bundled variants contain no wallpaper. Catppuccin Mocha and Oh My Theme Aurora must leave wallpaper unchanged on every display and Space.

## Connect Targets

Each setup uses two steps. `Review connection` is read-only. `Approve and connect` executes the reviewed plan after write-boundary validation.

- **macOS:** Review the Automation disclosure, then connect System Appearance. Grant the prompt for the full-switch run. Use the denial case below to prove partial behavior separately.
- **Ghostty:** Confirm setup names the managed fragment, include, and `Press cmd+shift+,`. A linked synthetic source requires explicit approval. Nix-managed or ambiguous configurations remain unavailable.
- **Visual Studio Code:** Choose Microsoft VS Code Stable or Insiders 1.90 or later in the 1.x line. Review the pinned companion, selected application executable, Default profile, global setting scope, and local Unix socket behavior. Approve installation, then keep the selected Default-profile windows open so the companion can register.
- **Starship:** Confirm setup limits ownership to registered palette keys. Connection is read-only and reports `Next launch`; applied themes report `Next prompt`.

The production menu supports one VS Code edition's Default profile at a time. Named profiles, custom user-data directories, remote extension hosts, and single-window selection are outside this live support boundary.

## Preview

1. Choose `Oh My Theme Aurora`.
2. Select `Preview workspace change`.
3. Confirm the preview names the generated source, source revision, expected changes, permissions, setup needs, conflicts, unavailable Targets, and expected reach.
4. Confirm preparation changes no target. Existing Ghostty colors, VS Code themes, Starship prompt, system appearance, and wallpapers must remain unchanged.
5. Confirm the preview has no wallpaper plan.
6. Select `Apply to ready Targets` only after reviewing every Target plan.

## Repeated full-Workspace switches and exact reports

Use this deterministic sequence after macOS starts in Dark mode and all four Targets are connected:

1. Apply Oh My Theme Aurora.
2. Activate Ghostty with `cmd+shift+,` and create the next Starship prompt.
3. Apply Catppuccin Mocha.
4. Activate Ghostty with `cmd+shift+,` and create the next Starship prompt.
5. Apply Oh My Theme Aurora again.
6. Activate Ghostty with `cmd+shift+,` and create the next Starship prompt.

Each run must have the title `Theme applied` and the following groups. Detail text may include the selected theme name, but it must not expose config values or private identifiers.

| Group | Capability | Configuration | Reach | Rollback |
| --- | --- | --- | --- | --- |
| System Appearance | `Appearance` | `Already set` | `Current windows` | `No rollback needed` |
| Ghostty | `Theme` | `Updated` | `Reload required` | `Undo available` |
| Selected VS Code edition, Default profile | `Theme` | `Updated` | `Current windows` | `Undo available` |
| Starship | `Theme` | `Updated` | `Next prompt` | `Undo available` |

The report must have no Wallpaper group. After every run:

- Ghostty windows keep their previous colors until the user presses `cmd+shift+,`. Both existing windows must then repaint without relaunching Ghostty.
- Both concurrent windows in the selected VS Code Default profile change without reload.
- The named VS Code profile and the unselected edition remain unchanged.
- The already-rendered Starship prompt remains unchanged. The next prompt uses the selected palette.
- Every wallpaper remains unchanged.
- Ghostty settings outside the managed fragment and Starship keys outside the registered palette ownership boundary remain unchanged.

If Catppuccin is absent from the selected VS Code profile, VS Code must report `Unavailable` and the Workspace title must be `Theme applied with remaining work`. Install the theme and repeat before claiming a full-Workspace pass.

## Clean Automation denial and revocation

### First denial

1. Run `/usr/bin/tccutil reset AppleEvents com.ohmytheme.OhMyTheme` before connecting System Appearance.
2. Confirm the System Appearance row shows the Automation disclosure before any prompt.
3. Select `Review connection`, then deny the macOS prompt shown by the first appearance read.
4. Confirm review preparation stops, the visible operation error identifies permission denial, and the row remains unconnected. No Connection Report should exist because `Approve and connect` was never reached.
5. Confirm Ghostty, VS Code, Starship, and wallpaper discovery remain usable.

### Revocation or reset after connection

1. Grant Automation and connect System Appearance.
2. Connect Ghostty, the selected VS Code Default profile, and Starship.
3. Reset Apple Events consent with `/usr/bin/tccutil reset AppleEvents com.ohmytheme.OhMyTheme`, or revoke Oh My Theme under System Settings > Privacy & Security > Automation.
4. Choose Aurora and select `Preview workspace change`.
5. Deny the prompt if macOS presents it.
6. Select `Apply to ready Targets`.
7. Confirm the title is `Theme applied with remaining work` when another Target updates.
8. Confirm System Appearance shows `Appearance`, `Permission required`, no reach line, and `No rollback needed`.
9. Confirm independent ready Targets keep their own successful results and rollback availability.

Permission denial must never appear as `Already set`, `Failed`, or `Current windows`.

## Undo

1. Complete the final Catppuccin to Aurora switch with no conflicts.
2. Select `Undo Last Theme Change` once.
3. Confirm the title is `Theme change undone`.
4. Confirm each changed developer Target returns to Catppuccin, the immediately previous state.
5. Confirm each successful rollback says `Restored`.
6. Confirm Ghostty says `Reload required`; press `cmd+shift+,` and verify both existing windows.
7. Confirm the selected VS Code Default profile says `Current windows`; verify both concurrent windows.
8. Confirm Starship says `Next prompt`; verify the next prompt and leave the existing prompt unchanged.
9. Confirm System Appearance and all wallpapers remain unchanged.
10. Confirm `Undo Last Theme Change` no longer offers the same completed transaction as a second undo point.

## External-edit conflicts

Use only fresh-account synthetic files. Keep a private local backup and record hashes, never contents.

### Guarded Undo for Ghostty and Starship

1. Apply Aurora and confirm Ghostty, VS Code, and Starship report `Updated`.
2. Add one syntax-valid harmless comment to the managed Ghostty fragment.
3. Add one syntax-valid harmless comment outside Oh My Theme's owned Starship palette keys.
4. Record both post-edit hashes.
5. Select `Undo Last Theme Change`.
6. Confirm Ghostty shows `Theme`, `Conflict`, no reach line, and `Restore blocked`.
7. Confirm Starship shows `Theme`, `Conflict`, no reach line, and `Restore blocked`.
8. Confirm both post-edit hashes are unchanged after Undo.
9. Confirm the selected VS Code Target safely returns to its prior theme and says `Restored`.
10. Confirm the report title is `Theme change undone with remaining work`.
11. Restore the synthetic files from private backups before continuing.

### Write-boundary conflicts

Run once for Ghostty and once for Starship:

1. Prepare a Workspace preview.
2. Before selecting `Apply to ready Targets`, add a valid harmless comment to the Target's synthetic file.
3. Apply the prepared preview.
4. Confirm that Target shows `Conflict`, no reach line, and `Restore blocked`.
5. Confirm the external edit remains unchanged while independent Targets continue.
6. Confirm the overall title is `Theme applied with remaining work` when another Target updates.

For VS Code, follow [`vscode-theme-switch.md`](vscode-theme-switch.md), section `External-edit conflict`. Its manually selected profile theme must remain unchanged after guarded Undo refuses.

## Restore and Disconnect qualification

Restore and Disconnect is one guarded action. It uses the original Connection Baseline, not the immediately previous Apply state, and removes the Target from My Mac only after safe restoration.

Open `Connection recovery`, select `Disconnect…`, review the confirmation, and use this matrix:

| Target | Restore and Disconnect procedure and expected reach |
| --- | --- |
| System Appearance | Apply away from the Connection Baseline, confirm Restore and Disconnect, verify the baseline returns with `Current windows`, and confirm the Target is no longer connected. |
| Ghostty | Apply a theme, confirm Restore and Disconnect, verify the original parent/include and fragment baseline returns, require `Reload required`, press `cmd+shift+,`, and confirm the Target is no longer connected. |
| Selected VS Code Default profile | Apply a theme, confirm Restore and Disconnect, and verify it removes only a companion installation owned by Oh My Theme. A pre-existing pinned companion remains installed. Confirm the Target is no longer connected. |
| Starship | Apply a theme, confirm Restore and Disconnect, verify the exact Connection Baseline returns, require `Next prompt`, and confirm the Target is no longer connected. |

For every row, reconnect with a fresh synthetic baseline, apply, make a harmless external edit, and retry Restore and Disconnect. The action must refuse, report `Conflict` and `Restore blocked`, keep the Target connected, and preserve the edit. There is no force-overwrite pass condition.

## Available displays and Spaces

Follow [`macos-capabilities.md`](macos-capabilities.md), section `Bundled demo display and Space check`.

- Confirm the macOS row reports the available connected-display count.
- Visit every Space available to the test machine before and after the repeated sequence.
- Confirm both bundled variants leave wallpaper unchanged because neither contains a wallpaper.
- Record that public APIs do not enumerate every Space. No report or support statement may promise inactive-Space coverage, dynamic wallpaper, or scheduled collections.

## Recovery

1. Begin Apply and stop Oh My Theme after one Target changes but before the report is durable.
2. Relaunch the app.
3. Confirm recovery completes before Preview, Apply, connection, Undo, Restore, or Disconnect becomes available.
4. Confirm the next report or operation preserves safe partial results and does not repeat an uncertain mutation blindly.
5. If current state matches neither the captured state nor the intended state, confirm recovery reports a conflict and writes nothing.

## Record

| Date | App build | macOS | Ghostty | VS Code edition/version | Starship | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Pending | Pending | Pending | Pending | Pending | Pending | Pending |
