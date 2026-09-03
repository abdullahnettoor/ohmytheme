# VS Code connection and recovery

Issue: #19

## Supported applications

The vertical demo recognizes standard Microsoft application bundles only:

| Edition | Bundle identifier | Documented bundle CLI | Supported version |
| --- | --- | --- | --- |
| Visual Studio Code Stable | `com.microsoft.VSCode` | `Contents/Resources/app/bin/code` | `1.90.x` through current `1.x` |
| Visual Studio Code Insiders | `com.microsoft.VSCodeInsiders` | `Contents/Resources/app/bin/code` | `1.90.x` through current `1.x` |

Cursor, VSCodium, Code - OSS, portable installations, custom `--user-data-dir` instances, and remote extension hosts are not connected by this adapter. They can still register as protocol peers for diagnostics, but discovery does not present them as supported Target Instances.

When more than one supported bundle is found, discovery reports an ambiguity and requires the user to choose one. The selected bundle's identifier, version, and executable are verified again before setup. No `code` command is resolved from `PATH`.

## Connection behavior

1. Build the pinned companion:

   ```sh
   cd Extensions/VSCode/oh-my-theme-companion
   npm ci
   npm run package:vsix
   ```

2. Verify the generated app resource against `App/OhMyThemeApp/Resources/oh-my-theme-companion-0.1.0.vsix.sha256`.
3. Start the app-owned companion socket before opening the selected VS Code window.
4. Prepare the connection. Confirm the preview names:
   - companion extension ID and pinned version;
   - selected application-bundle executable;
   - per-user Unix-domain socket, launch nonce, and no TCP listener;
   - global `workbench.colorTheme` scope;
   - selected CLI profile and expected registered profile/process/window identity.
5. Decline approval. Confirm no CLI process runs and no extension is installed.
6. Approve installation. Confirm the app invokes the executable inside the selected bundle with `--profile <name> --install-extension <absolute-vsix-path> --force`.
7. Open or reload the intended profile/window. Confirm only a registration matching the selected edition/version, pinned extension version, profile identity, and process/window identity completes connection.

VS Code's stable extension API does not expose a profile display name or native window handle. The companion reports an opaque profile-scoped `globalStorageUri` and uses `vscode.env.sessionId` as the window-session identity. The selected CLI profile name is retained separately in the Connection Plan. Profile-scoped Target Instances keep matching the same opaque profile after a window relaunch; window-scoped Target Instances also pin the selected window-session identity.

## Recovery and ownership checks

- Interrupt before CLI installation: relaunch and confirm reconciliation classifies the plan as before-change.
- Interrupt after installation but before receipt persistence: relaunch the app and VS Code. A matching fresh registration must be observed before reconciliation classifies the intended after-state.
- Prevent the expected registration from reconnecting: reconciliation must report a conflict rather than accepting another profile/window.
- If Oh My Theme installed the pinned companion over an absent baseline, it places a private ownership record beside that installed extension. The record binds a random token to a digest of the installed extension files. Restore and Disconnect uninstall only when the extension ID, version, token, and installed content still match.
- If the companion was already installed at the pinned version before connection, Restore and Disconnect leave it installed.
- Replace or remove the extension outside Oh My Theme before Restore and Disconnect. Confirm the missing or changed ownership token causes a conflict and no extension is uninstalled.
- A different pre-existing companion version is not overwritten because this beta cannot restore its exact package bytes.

Continue with [`vscode-theme-switch.md`](vscode-theme-switch.md) for Apply and guarded Undo, and with [`vscode-companion-live-switch.md`](vscode-companion-live-switch.md) for Stable/Insiders, profile, concurrent-window, override, and reconnect checks.

The production menu currently offers the Default profile and allows one VS Code edition to join My Mac at a time. Named profiles, custom `--user-data-dir` sessions, remote extension hosts, and single-window selection are outside this live support boundary. Qualify Stable and Insiders in separate fresh-account runs, and verify that the unselected edition and named profiles remain unchanged.
