# VS Code companion live-switch proof

Research cutoff: 2026-09-02. This record addresses [issue #8](https://github.com/abdullahnettoor/ohmytheme/issues/8) using the accepted Unix-domain socket ADR and Microsoft's official extension and configuration APIs.

## Finding

The supported activation boundary is a pinned companion extension. The native
app should not edit `settings.json` or treat a `vscode://settings/...` URI as
an acknowledgement channel. The extension owns the target-side mutation:

```ts
await vscode.workspace
  .getConfiguration()
  .update("workbench.colorTheme", themeName, vscode.ConfigurationTarget.Global);
```

The extension then reads the effective setting and reports whether a workspace,
profile, remote window, or another scope overrides the requested value.

Evidence: [VS Code color themes](https://code.visualstudio.com/docs/configure/themes),
[user and workspace settings](https://code.visualstudio.com/docs/configure/settings),
the [`WorkspaceConfiguration` API](https://code.visualstudio.com/api/references/vscode-api#WorkspaceConfiguration),
and the [color-theme extension guide](https://code.visualstudio.com/api/extension-guides/color-theme).

## Protocol and security proof

The ADR's proposed protocol is appropriate for a local proof:

- the app owns a per-user Unix-domain socket;
- frames are versioned, length-prefixed JSON;
- registration includes edition, version, profile identity, process/window identity,
  protocol version, capabilities, and relevant current settings;
- each launch has a nonce;
- request identifiers are unique and duplicate or stale requests are rejected;
- the socket directory is `0700` and rendezvous files are `0600`;
- acknowledgements match the request identifier and include the verified effective
  setting and override information.

The proof must cover malformed frames, unsupported versions, reconnects, stale
requests, duplicate identifiers, acknowledgement mismatches, and a real
extension-host test. A URI launch can assist installation or discovery, but it
cannot prove that a setting was applied.

## Activation reach and product boundary

The strongest justified status is **automatic after setup** for the connected
extension instance and scope it reports. It is not a promise to change every
VS Code profile, workspace, remote window, Insiders build, or custom
`--user-data-dir`. Workspace and more-specific settings can override the global
value, and the acknowledgement must surface that condition.

This issue remains research-only in the current pass: no socket server,
extension package, or unauthenticated fallback was added.
