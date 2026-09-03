# Technical stack

## Scope

This document records the implementation stack for the Oh My Theme macOS beta. It implements the product behavior and safety rules in [`mvp-plan.md`](./mvp-plan.md); it does not replace them.

## Platform

- Swift 6 language mode.
- SwiftUI application lifecycle and interface.
- `MenuBarExtra` with window style as the primary scene.
- Focused AppKit bridges where SwiftUI does not expose the required macOS behavior.
- Minimum deployment target: macOS 14 Sonoma.
- Direct distribution outside the Mac App Store.
- App Sandbox disabled.
- No privileged helper, launch daemon, XPC engine, or custom installer in the beta.

The SwiftUI layer is presentation code. It does not own theme application, target discovery, file changes, Apple Events, process execution, journaling, or recovery.

## Runtime and concurrency

The beta runs as one macOS application process. The VS Code companion extension and target applications remain external processes.

`ThemeEngine` is a Swift `actor` and the only interface used by presentation code for mutating theme state. It permits one Apply, Undo, Restore, Disconnect, or recovery operation at a time.

- UI state and view updates run on `MainActor`.
- Read-only discovery and preparation may run concurrently when their dependencies are independent.
- Target mutations run sequentially in deterministic order for the beta.
- Users may cancel discovery and preparation.
- Once the first external mutation starts, the operation runs to a terminal or recovery-required state rather than offering unsafe cancellation.
- Every durable plan is written before its corresponding external mutation.
- Interrupted work is reconciled when the app next launches.

Adapter plans remain independent so bounded concurrent application can be introduced later without changing the adapter interface.

## Persistence

Use SQLite through GRDB for durable application state:

- Workspace and theme assignment
- Target Instances and connection state
- Connection Baseline metadata
- Apply Transactions and per-target operation states
- Serialized Connection Plans, Adapter Plans, and receipts
- Schema, adapter, compiler, and payload versions

GRDB migrations are the only mechanism for database schema changes. Tests must cover migration from every retained beta schema to the current schema.

Target-specific payloads are stored in versioned envelopes:

```text
adapterID
adapterVersion
payloadVersion
payload
```

The owning adapter encodes and decodes the payload. The engine treats it as opaque data but validates the envelope before dispatch.

Store exact restoration bytes and generated artifacts in a content-addressed file store under Application Support. SQLite records their SHA-256 digests and metadata. Directories use user-only access, and sensitive files use user-only permissions. Never put baseline bytes in logs or diagnostic exports.

Use `UserDefaults` only for noncritical presentation preferences. Use Keychain only for secrets that cannot be protected adequately through per-user filesystem permissions.

## Theme packs and compilation

Theme packs are versioned JSON data. Define the accepted structure in `Schemas/theme-pack.schema.json` and mirror it with hand-written, strongly typed `Codable` and `Sendable` Swift models.

- Colors use normalized lowercase device-independent sRGB strings: `#rrggbb`, or `#rrggbbaa` where a role permits alpha.
- Validation rejects unsupported schema versions, missing roles, duplicate identifiers, malformed colors, forbidden alpha, unsafe asset paths, digest mismatches, and inconsistent metadata.
- Wallpaper and pinned upstream artifacts sit beside their manifest and carry content digests.
- Theme packs contain no executable Swift, scripts, templates with arbitrary evaluation, or adapter logic.

A shared `ThemeCompiler` module validates and normalizes packs. A `ThemeTool` Swift executable gives maintainers and CI the same compiler. Generated catalog metadata is committed, then regenerated and compared in CI.

A target adapter compiles a Generated Theme during `prepareApply`. The resulting exact bytes become part of the immutable Adapter Plan. `apply` consumes those bytes and never recompiles after review.

## Module layout

Use a thin checked-in Xcode application target backed by one local Swift package:

```text
OhMyTheme.xcodeproj
App/
  OhMyThemeApp/
    UI/
    AppComposition/
    Resources/
Packages/
  OhMyThemeKit/
    Package.swift
    Sources/
      ThemeModel/
      ThemeCompiler/
      AdapterKit/
      PlatformClients/
      Persistence/
      Adapters/
      ThemeEngine/
      ThemeTool/
    Tests/
Themes/
  Packs/
  UpstreamPorts/
Schemas/
Extensions/
  VSCode/
Fixtures/
  Configurations/
  ThemePacks/
  Recovery/
```

The initial repository may create these paths lazily as implementation reaches them.

### Module responsibilities

- `OhMyThemeApp`: SwiftUI scenes, presentation state, and dependency composition.
- `ThemeModel`: target-independent values with no SwiftUI, AppKit, or GRDB imports.
- `ThemeCompiler`: theme-pack validation, normalization, and generated artifact compilation support.
- `AdapterKit`: the adapter interface, type erasure, plan envelopes, receipts, and capability outcomes.
- `PlatformClients`: shared side-effect modules for managed files, process execution, Apple Events, app discovery, wallpaper, appearance, and Launch at Login.
- `Persistence`: GRDB records, migrations, transaction journal, baseline metadata, and content-store references.
- `Adapters`: reviewed, compiled target adapters grouped by target.
- `ThemeEngine`: orchestration, serialization, recovery, and report aggregation behind the product interface.
- `ThemeTool`: maintainer and CI commands for theme validation and catalog generation.

Do not add generic CRUD repositories around GRDB, a dependency-injection framework, runtime adapter plugins, or one Swift package per module.

## Adapter and side-effect seams

`TargetAdapter` is the seam for target-specific behavior. Each adapter keeps typed plans and receipts internally; a type-erased registry lets the engine discover adapters and persist their versioned payloads.

Adapters receive focused side-effect modules instead of directly using filesystem, process, Apple Event, or database facilities:

- `ManagedFiles` resolves and inspects symlinks, detects Nix ownership, computes identity and digests, performs guarded atomic writes, captures restoration data, and applies guarded rollback.
- `ProcessRunner` invokes absolute executable URLs with argument arrays, bounded output, timeouts, and structured results. It never invokes a shell.
- `AppleEventClient` checks Automation permission, sends approved target-specific events, and maps permission and target errors separately.
- `ApplicationDiscovery` locates application bundles, versions, and running instances.
- Focused macOS clients own wallpaper, appearance, and Launch at Login operations.

Adapters own target-specific policy and translation. Shared modules enforce safety mechanics.

## VS Code companion

The macOS app and companion extension communicate through a local Unix-domain socket.

- The app owns the socket server.
- The extension runs locally as a UI extension and connects outward.
- Each extension instance registers its VS Code edition, version, profile identity, process or window identity, protocol version, capabilities, and relevant current settings.
- Messages use a versioned, length-prefixed JSON protocol with request identifiers.
- The extension applies themes through VS Code's supported `WorkspaceConfiguration.update` interface, verifies the resulting configuration, and returns a structured acknowledgement.
- The app stores the acknowledgement in the adapter receipt.

Keep the socket in a per-user directory with `0700` permissions and rendezvous files at `0600`. Reject another user's peer when peer credentials are available. Use a per-launch nonce and reject duplicate request identifiers. Do not expose a TCP listener or put secrets in custom URIs.

The threat model excludes hostile software already running as the same macOS user. Such software can already access the developer configuration files managed by the app.

Bundle a pinned `.vsix` for the beta. Install it only after approval by invoking the documented VS Code executable inside the selected application bundle. Do not assume the `code` command is on `PATH`. Custom VS Code URIs may assist setup but are not the apply transport.

## Platform libraries

Prefer Apple frameworks and keep GRDB as the only initial third-party Swift runtime dependency.

- Foundation `Process`, wrapped by `ProcessRunner`, for child processes.
- Foundation `FileManager`, `URL`, CryptoKit, and narrow Darwin file-descriptor wrappers inside `ManagedFiles`.
- Direct Apple Event descriptors for stable operations where practical.
- Static bundled `NSAppleScript` only where direct descriptors add disproportionate complexity. Never interpolate user-controlled values into script source.
- Network.framework for the Unix-domain socket, except where the
  companion server's peer-credential and socket-mode requirements
  force a raw POSIX path (see [ADR 0010](../adr/0010-posix-companion-socket.md)).
- AppKit and `NSWorkspace` for app discovery and wallpaper.
- ServiceManagement for opt-in Launch at Login.
- OSLog for privacy-aware structured logs.
- CryptoKit for SHA-256 and connection nonces.
- Security and Keychain only when a real secret requires them.

Do not add a shell-command library. Reconsider Apple's `swift-subprocess` only if the Foundation process wrapper becomes costly to maintain.

## Testing

Use Swift Testing for package tests. Use XCTest or XCUITest only for app-hosted and UI behavior that requires Apple test infrastructure. Do not set a coverage percentage for the beta.

Every writable adapter must pass a shared safety contract proving that:

1. Preparation performs no writes.
2. A serialized plan survives process restart.
3. Applying a valid plan is idempotent or safely classifiable.
4. Changed preconditions conflict before mutation.
5. Recovery distinguishes before-state, intended after-state, and conflicting state.
6. Rollback restores only while its receipt still matches current state.
7. External edits are not overwritten.
8. Sensitive source bytes do not enter logs or reports.

Use temporary directories, in-memory and temporary-file SQLite databases, fake clocks, deterministic identifiers, recording side-effect modules, and realistic target fixtures. Keep manual compatibility checks for privacy prompts, real applications, multiple windows or sessions, displays, and target versions.

The VS Code extension uses TypeScript protocol tests and the VS Code-supported extension-host test harness. Test reconnection, registration, configuration updates, acknowledgements, stale requests, and profile handling.

## Build and continuous integration

Use Xcode, Swift Package Manager, npm, and GitHub Actions.

- Check in the Xcode project, shared scheme, `.xcconfig` files, `Package.resolved`, and `package-lock.json`.
- Pin the macOS runner and Xcode version instead of following `latest`.
- Keep repository scripts as the stable local and CI entry points: bootstrap checks, format or lint, test, app build, extension build, and generated-output verification.
- Scripts report missing tools and do not install software without approval.
- Do not add CocoaPods, Carthage, Fastlane, Tuist, XcodeGen, Bazel, Nix-based builds, or a JavaScript monorepo manager for the beta.

CI will add jobs as their corresponding code exists:

1. Swift modules and database migrations
2. Unsigned macOS app build and app-hosted tests
3. Theme validation, attribution, digest, and generated-output checks
4. VS Code type-check, lint, protocol tests, extension-host tests, and `.vsix` build
5. Shared adapter safety-contract tests and secret checks

Do not add empty workflows that cannot yet validate code.

## Signing, releases, and updates

Initial development uses Xcode local signing. Keep App Sandbox disabled and do not configure notarization credentials or an updater yet.

Before an external beta:

1. Obtain a Developer ID Application certificate.
2. Enable Hardened Runtime with only required entitlements.
3. Archive, sign, notarize, and staple the app.
4. Publish a `.dmg` and checksums through GitHub Releases.
5. Start with a manual update check that opens the release page.

Consider Sparkle 2 only after the bundle identity, signing identity, release location, and update policy are stable.
