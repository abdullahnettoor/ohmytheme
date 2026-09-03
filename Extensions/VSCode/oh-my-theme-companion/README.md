# Oh My Theme Companion

A local VS Code companion for the [Oh My Theme](https://github.com/abdullahnettoor/ohmytheme)
macOS app. When the app applies a Theme Variant to a Connected Target
Instance, it asks this extension to change `workbench.colorTheme`
through VS Code's supported configuration API, then reads back the
configured and effective settings and reports any workspace, folder, or
remote overrides. Updates compare the current profile setting with the
value prepared by the app, so Undo and ordinary switches stop on external
changes instead of overwriting them.

The companion communicates with the app through a per-user
Unix-domain socket. The wire protocol is documented in
[`docs/architecture/vscode-companion-protocol.md`](../../../docs/architecture/vscode-companion-protocol.md).

## Development

```
npm install
npm run compile
npm run test:unit
npm run test:host   # downloads a VS Code test host and runs extension tests
npm run package:vsix # writes the pinned app resource
```

The extension does not activate against a live app on startup unless a
valid `rendezvous.json` is present in the app's per-user directory.
