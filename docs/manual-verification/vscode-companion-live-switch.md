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

Run these on a macOS 14+ machine with a stable installation of
Microsoft VS Code (Stable channel) and the companion extension
installed as a `.vsix` under the intended profile.

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

## Scope limits

- Only `workbench.colorTheme` is exchanged in this proof.
- Only `ConfigurationTarget.Global` is a supported apply target.
- Overrides at workspace, workspace-folder, and remote scope are
  reported but not modified.
- Insiders, remote windows, and custom `--user-data-dir` sessions are
  each their own extension instance and produce their own receipts.
