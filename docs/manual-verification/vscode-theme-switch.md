# VS Code theme switching and Undo

Use this checklist to verify issue #20 against a real connected VS Code Target Instance. Complete the connection steps in [`vscode-connection.md`](vscode-connection.md) first.

## Apply and acknowledgement

1. Start Oh My Theme and VS Code with the selected edition's Default profile connected. Keep two windows in that profile open, plus one named-profile window and one window in the unselected edition.
2. Prepare Catppuccin Mocha. Confirm the preview names the upstream source revision and the intended `workbench.colorTheme` value.
3. Apply the preview.
4. Confirm both concurrent windows in the selected Default profile change without a reload and its profile setting now contains the requested theme name.
5. Confirm the named-profile window and the unselected edition remain unchanged.
6. Confirm the Apply Report identifies the selected edition and Default profile, then reports `Theme`, `Updated`, `Current windows`, and `Undo available`.

The pinned companion includes the generated `Oh My Theme Aurora` color theme. Upstream themes such as `Catppuccin Mocha` must otherwise be installed in VS Code. If the requested theme is missing, the result must say that the theme is unavailable rather than claiming a successful switch.

## Workspace override

1. Open a workspace and set `workbench.colorTheme` in `.vscode/settings.json` to a different installed theme.
2. Apply the same Theme Variant again.
3. Confirm the profile-level setting contains the requested theme.
4. Confirm the current window keeps the workspace theme.
5. Confirm the Apply Report names the workspace override and does not report current-instance activation.

Remove the workspace setting after this check.

## Guarded Undo

1. Apply a Theme Variant and note the profile-level theme that existed before Apply.
2. Choose Undo Last Theme Change.
3. Confirm the companion acknowledges a second configuration update.
4. Confirm the prior profile-level setting is restored. If no profile setting existed before Apply, confirm Undo removes the setting and VS Code returns to its inherited default.

## External-edit conflict

1. Apply a Theme Variant through Oh My Theme.
2. Change the profile-level color theme manually in VS Code.
3. Choose Undo Last Theme Change.
4. Confirm Undo reports a conflict and leaves the manually selected theme unchanged.

## Interrupted request recovery

1. Begin Apply, then stop the Oh My Theme process after VS Code changes but before the acknowledgement is durable.
2. Relaunch Oh My Theme.
3. Confirm launch reconciliation inspects the intended registered Target Instance before another mutation.
4. Confirm it classifies the setting as intended-after-change and reconstructs a recovery receipt. If the setting differs from both the captured and intended values, confirm reconciliation reports a conflict and does not write.

## Limits

- The companion changes only `workbench.colorTheme` at VS Code's global profile scope.
- Workspace, workspace-folder, language-specific, and remote overrides are reported but not changed.
- The apply route addresses one authenticated companion registration selected by the connected Target Instance.
- A timeout or disconnect is not treated as failure proof. Oh My Theme inspects the setting before it decides whether the request changed VS Code.
