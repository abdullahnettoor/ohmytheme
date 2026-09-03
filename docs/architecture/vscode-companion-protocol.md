# VS Code companion wire protocol

This document defines the wire protocol spoken between the Oh My Theme
macOS app and its pinned VS Code companion extension. It is the shared
reference for the Swift server implementation in `PlatformClients` and
the TypeScript client implementation under `Extensions/VSCode/`.

The protocol implements the security and product requirements captured in
[ADR 0009](../adr/0009-vscode-unix-socket-bridge.md), the [technical
stack](technical-stack.md#vs-code-companion), and the [VS Code companion
live-switch proof](../research/vscode-companion-proof.md).

## Transport

- The macOS app owns a per-user Unix-domain socket.
- The socket path is `${socketDirectory}/companion.sock` where
  `socketDirectory` sits under `~/Library/Application Support/OhMyTheme/`
  as `companion/<launch-id>/`. The launch identifier changes for every
  app launch, so socket paths from a prior launch cannot be reused.
- The parent socket directory is created with mode `0700` and the socket
  itself is chmoded to `0600`. Both are removed when the app exits or
  before rebinding after a launch.
- The server verifies the peer's effective user id (`LOCAL_PEEREUID`)
  before accepting a connection and rejects any peer whose euid does
  not match the app's.
- The server publishes a **rendezvous file** at
  `~/Library/Application Support/OhMyTheme/companion/rendezvous.json`
  with mode `0600`. It records the current `socketPath`, `launchId`,
  `launchNonce`, `protocolVersion`, and the supported protocol range.
  The rendezvous file is written atomically and removed on shutdown.
  The extension reads it to discover the current socket.

## Framing

Each frame is a UTF-8 JSON object preceded by a big-endian 32-bit
unsigned length prefix that counts the JSON body only:

```
+---------------+----------------------------+
| 4-byte length | JSON body (length bytes)   |
+---------------+----------------------------+
```

The maximum accepted body size is **65,536 bytes**. Frames larger than
the maximum, non-UTF-8 bytes, invalid JSON, and JSON that is not an
object are treated as protocol errors: the receiver sends a
`protocol_error` message and closes the connection.

## Messages

Every message is a JSON object with these envelope fields:

- `protocolVersion` — integer, the protocol version this peer supports.
  The initial protocol version is `1`.
- `type` — string, one of the message types listed below.
- `id` — string, a UUID that identifies this message. Request-response
  messages carry the client's `id`; acknowledgements copy the request
  `id` verbatim.

Additional fields depend on `type`.

### `register` (extension → app)

Sent immediately after the extension connects. The extension MUST send
`register` before any other message and MUST NOT send a second
`register` on the same connection.

```json
{
  "protocolVersion": 1,
  "type": "register",
  "id": "…",
  "launchNonce": "…",
  "extensionVersion": "0.1.0",
  "vscode": {
    "edition": "code-oss" | "vscode" | "insiders" | "cursor" | "other",
    "version": "1.94.0",
    "profileName": "Default",
    "profileId": "…",
    "machineId": "…",
    "sessionId": "…",
    "processId": 12345,
    "windowId": "…"
  },
  "capabilities": ["colorTheme"],
  "currentSettings": {
    "workbench.colorTheme": "…",
    "workbench.preferredDarkColorTheme": "…",
    "workbench.preferredLightColorTheme": "…"
  }
}
```

The `launchNonce` MUST equal the value the app published in the
rendezvous file for the current launch. The server rejects a register
message whose nonce does not match with `register_rejected` and closes
the connection.

### `register_ack` (app → extension)

```json
{
  "protocolVersion": 1,
  "type": "register_ack",
  "id": "…",
  "sessionId": "…"
}
```

`id` copies the register message's `id`. `sessionId` is a short opaque
identifier the app assigns to this connection.

### `register_rejected` (app → extension)

```json
{
  "protocolVersion": 1,
  "type": "register_rejected",
  "id": "…",
  "reason": "unsupported_protocol"
                | "invalid_nonce"
                | "duplicate_registration"
                | "missing_capability"
                | "unauthenticated_peer"
}
```

The server closes the connection after sending `register_rejected`.

### `apply_theme` (app → extension)

```json
{
  "protocolVersion": 1,
  "type": "apply_theme",
  "id": "…",
  "sessionId": "…",
  "themeName": "Catppuccin Mocha",
  "target": "global"
}
```

The extension MUST apply the theme through
`WorkspaceConfiguration.update` in the requested target and then verify
the effective setting before acknowledging. Only the `global` target is
supported in this proof.

### `apply_theme_ack` (extension → app)

```json
{
  "protocolVersion": 1,
  "type": "apply_theme_ack",
  "id": "…",
  "status": "applied" | "overridden" | "unsupported_theme" | "failed",
  "effectiveSetting": "Catppuccin Mocha",
  "requestedSetting": "Catppuccin Mocha",
  "overrides": [
    { "scope": "workspace", "value": "Some Other Theme" },
    { "scope": "workspaceFolder", "folder": "…", "value": "…" }
  ],
  "failure": {
    "code": "verification_mismatch" | "update_threw" | "…",
    "message": "…"
  }
}
```

`id` copies the request `id`. `overrides` is present when the global
setting was applied but a workspace, workspace-folder, or remote scope
overrides it. `failure` is present only when `status` is `failed`.

### `protocol_error` (either side)

```json
{
  "protocolVersion": 1,
  "type": "protocol_error",
  "id": "…",
  "requestId": "…",
  "code": "malformed_frame"
        | "unsupported_type"
        | "unsupported_protocol_version"
        | "duplicate_request_id"
        | "unexpected_message"
        | "missing_required_field"
        | "not_registered",
  "message": "…"
}
```

`id` is a fresh UUID for this error. `requestId`, when present, echoes
the identifier of the offending message so the sender can correlate.

## Duplicate and stale requests

- The server records every accepted request `id` per connection and
  rejects a second use with `protocol_error` code `duplicate_request_id`
  without processing it.
- A response whose `id` does not match any outstanding request on the
  connection is dropped and reported as `protocol_error` code
  `unexpected_message`.
- Because the socket path and launch nonce change on every launch, a
  reconnect from a previous launch cannot masquerade as the current
  session: the nonce check rejects it before any theme change is
  applied.

## Version negotiation

- The extension announces its highest supported protocol version in
  the register message. The server rejects any version outside the
  server's supported range with `register_rejected` code
  `unsupported_protocol`.
- After a successful register, the connection speaks the version the
  server acknowledged. Both sides MUST reject any subsequent message
  whose `protocolVersion` differs from the negotiated version.

## Connection lifecycle

1. Extension activates and reads `rendezvous.json`.
2. Extension opens the Unix-domain socket.
3. Server accepts, verifies peer euid, waits for `register` with a
   bounded timeout (five seconds). A connection that does not register
   in time is closed.
4. Server replies `register_ack` or `register_rejected`.
5. Server may send zero or more `apply_theme` requests. The extension
   replies with `apply_theme_ack` for each and never initiates an
   `apply_theme` itself.
6. Either side may close the connection cleanly. A closed connection
   discards its request-id history; the next connection starts fresh.

## Out of scope for this proof

- Reading and writing settings other than `workbench.colorTheme`.
- Applying themes at workspace, folder, or remote scope.
- Distributing the extension outside a locally installed `.vsix`.
- Reconnect state coordination across launches (the launch nonce
  intentionally prevents cross-launch reuse).
