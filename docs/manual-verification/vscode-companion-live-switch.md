# VS Code companion live-switch proof

This document records how the Oh My Theme VS Code companion proof is
verified end to end. It complements the design in
[`docs/architecture/vscode-companion-protocol.md`](../architecture/vscode-companion-protocol.md)
and the research finding in
[`docs/research/vscode-companion-proof.md`](../research/vscode-companion-proof.md).

Automated coverage is in the `PlatformClientsTests` suites for the
Swift side and in `Extensions/VSCode/oh-my-theme-companion/src/test`
for the extension side. Manual verification is required only for
matters an extension-host test cannot cover from CI.

## Automated coverage

- `Scripts/test-package.sh` — Swift protocol codec, session state
  machine, and Unix-domain socket integration (permissions, rendezvous
  file, malformed frames, stale nonce, reconnect).
- `Scripts/prove-vscode-companion.sh` — extension unit tests and (when
  a VS Code test host can be downloaded) the extension-host tests that
  boot a real VS Code and verify inspect, apply, and guarded Undo round-trips.
- `Extensions/VSCode/oh-my-theme-companion/src/test/host/` — the
  extension-host test that connects to a native stub server, applies an
  installed theme, acknowledges guarded Undo, and confirms the original
  profile setting is restored.

## Manual proof cases

Run these on a macOS 14+ machine with standard Microsoft VS Code Stable and Insiders installations at version 1.90 or later in the 1.x line. The app installs the pinned companion in the selected edition's Default profile after approval.

### 1. Cold-launch registration

1. Quit VS Code.
2. Delete `~/Library/Application Support/OhMyTheme/companion/rendezvous.json`
   if present.
3. Start the Oh My Theme macOS app. Confirm `rendezvous.json` appears
   with mode `0600` and contains the current launch id and nonce.
4. Launch VS Code. Verify the extension log line
   `[oh-my-theme] not connecting` is absent and the extension holds an
   open socket to the app (`lsof -U | grep companion.sock`).

### 2. Registration rejection on stale nonce

1. With VS Code closed, replace the `launchNonce` value in
   `rendezvous.json` with a random string.
2. Launch VS Code and open the extension's log. Confirm the extension
   reports `register rejected: invalid_nonce` and does not attempt to
   change `workbench.colorTheme`.
3. Restart the app to publish a fresh nonce and confirm the extension
   registers on the next VS Code launch.

### 3. Live theme switch

1. With the extension connected, apply a theme through the Oh My
   Theme app (for example, `Catppuccin Mocha`).
2. VS Code's title bar and editor colors change without any prompt.
3. In VS Code, run `> Preferences: Open User Settings (JSON)` and
   confirm `workbench.colorTheme` is set to the requested value.
4. Run Undo Last Theme Change and confirm a second acknowledged update
   restores the prior profile setting.

### 4. Override reporting

1. In VS Code, open a workspace and set
   `workbench.colorTheme` in `.vscode/settings.json` to a different
   theme than the app's selection.
2. Trigger an apply through the app.
3. Inspect the app's most recent Apply Report. It must show the
   requested theme, the effective theme (which will be the workspace
   value), and an override entry with scope `workspace`.

### 5. Reconnect across VS Code restart

1. With the extension connected, quit and relaunch VS Code (leaving
   the app running).
2. Confirm the extension reconnects to the same socket, re-registers
   with the same launch nonce, and receives a fresh `register_ack`.

### 6. Reconnect across app restart

1. Quit the Oh My Theme app. The extension's socket closes; the
   extension logs a benign disconnect.
2. Restart the app. The rendezvous nonce changes.
3. Restart VS Code (or watch the file for changes). The extension
   picks up the new rendezvous and registers again.

### 7. Duplicate request id

1. With the extension connected, exercise the internal path that
   sends two `apply_theme` requests reusing the same request id (this
   is testable through the developer inspector, not through the app
   UI).
2. Confirm the extension logs a `protocol_error` with code
   `duplicate_request_id` and applies the theme only once.

### 8. Socket permission audit

1. With the app running, run
   `stat -f "%p %u" ~/Library/Application Support/OhMyTheme/companion/*/companion.sock`.
2. Confirm the mode ends in `0600` and the owner matches the current
   user's UID. Repeat for the rendezvous file.
3. Record only the mode and owner-match result. Do not put socket paths, nonces, profile IDs, process IDs, or window IDs in the committed verification record.

### 9. Edition, profile, and concurrent-window matrix

Use a fresh account or a completed in-app Restore and Disconnect between the Stable-selected and Insiders-selected runs.

1. Install Stable and Insiders. Keep two Default-profile windows open in each edition.
2. Create one named test profile in each edition and open one window for it. Do not record its opaque profile identifier.
3. In Oh My Theme, choose one edition's `Default profile` during `Review connection`, then select `Approve and connect`.
4. Apply Aurora. Confirm both Default-profile windows in the selected edition change without reload.
5. Confirm the selected edition's named-profile window and every window in the unselected edition remain unchanged.
6. Confirm the report names the selected edition and Default profile, then shows `Theme`, `Updated`, `Current windows`, and `Undo available`.
7. Add a workspace-level `workbench.colorTheme` override in one selected Default-profile window and apply Catppuccin Mocha.
8. Confirm the profile setting is stored, the override stays active, and the report does not claim `Current windows`. Its detail must say the current workspace setting overrides the stored profile theme.
9. Remove the workspace override, apply again, and confirm both selected Default-profile windows now show Catppuccin.
10. Select `Undo Last Theme Change`. Confirm only the selected Default profile returns to its preceding profile setting.
11. Repeat with the other edition selected.

Record the four scopes for each run:

| Scope | Expected result |
| --- | --- |
| Selected edition, Default profile, first window | Changes and acknowledges the request |
| Selected edition, Default profile, second concurrent window | Changes because the global profile setting is shared |
| Selected edition, named profile | Unchanged |
| Unselected edition, any profile | Unchanged |

A change outside the selected edition's Default profile is a hard failure. The production UI does not support choosing a named profile or targeting only one window.

## Scope limits

- Only `workbench.colorTheme` is exchanged in this proof.
- Only `ConfigurationTarget.Global` in the selected Default profile is a supported apply target.
- Overrides at workspace, workspace-folder, and remote scope are reported but not modified.
- Standard Microsoft VS Code Stable and Insiders are supported at version 1.90 or later in the 1.x line. Qualify each edition separately.
- Named profiles, remote extension hosts, custom `--user-data-dir` sessions, and single-window selection are outside the production UI support boundary.
- The app addresses one authenticated companion registration for acknowledgement. The live matrix must prove whether the resulting global profile change reaches all concurrent windows in the selected Default profile.
