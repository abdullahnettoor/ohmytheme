# Oh My Theme

One theme for your entire Mac. Oh My Theme is a macOS menu-bar utility that applies one theme assignment to a connected developer workspace.

The product contract, boundaries, and safety rules live in [`docs/architecture/mvp-plan.md`](docs/architecture/mvp-plan.md); the implementation stack lives in [`docs/architecture/technical-stack.md`](docs/architecture/technical-stack.md). Domain vocabulary is in [`CONTEXT.md`](CONTEXT.md).

## Requirements

- macOS 14 Sonoma or later
- Xcode 26.1 build 17B55 (Swift 6.2.1; CI bundle `Xcode_26.1.1.app`)
- Node.js 22.23.2 and npm 11.16.0 for the VS Code companion

## Layout

```text
OhMyTheme.xcodeproj      Checked-in app project and shared scheme
App/OhMyThemeApp/        SwiftUI menu-bar app: views, presentation state, composition
App/OhMyThemeAppTests/   App-hosted smoke tests
Packages/OhMyThemeKit/   The local modular Swift package the app depends on
Config/                  Shared, app, and test xcconfig files
Scripts/                 Stable local and CI entry points
```

## Commands

```bash
./Scripts/bootstrap.sh      # Report whether this machine can build and test
./Scripts/lint.sh           # Check Swift formatting (--fix rewrites files)
./Scripts/test.sh           # Package tests and app-hosted smoke tests
./Scripts/test-package.sh   # OhMyThemeKit tests only
./Scripts/test-themes.sh    # Validate bundled Theme Packs and catalog output
./Scripts/test-app.sh       # App-hosted smoke tests only
./Scripts/build-app.sh      # Build the locally signed app
./Scripts/prove-ghostty.sh             # Run the disposable Ghostty configuration proof
./Scripts/prove-vscode-companion.sh    # Run companion unit tests; set OMT_REQUIRE_VSCODE_HOST_TESTS=1 for the pinned host
./Scripts/check-vscode-generated.sh    # Rebuild and compare the checked-in VSIX and checksum
```

Scripts report missing tools; they never install software.

Behavior that automated tests cannot prove is recorded in [`docs/manual-verification/`](docs/manual-verification).

`ThemeTool` uses the same compiler as the app:

```bash
cd Packages/OhMyThemeKit
swift run ThemeTool validate ../../Themes/Packs/*.json
swift run ThemeTool catalog ../../Themes/Packs ../../Themes/catalog.json
```
