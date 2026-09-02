# Bundled Theme Catalog

## Record

| Item | Result | Evidence |
| --- | --- | --- |
| Bundled packs validate | Pass | `./Scripts/test-themes.sh` |
| Generated catalog is deterministic | Pass | `./Scripts/test-themes.sh` and the golden package test |
| Menu displays both variants and provenance | Pending human check | Follow the steps below |

## Human check

1. Run `./Scripts/build-app.sh`.
2. Open `.build/DerivedData/Build/Products/Debug/OhMyTheme.app`.
3. Open the menu-bar item.
4. Confirm the panel lists **Catppuccin Mocha** as `dark · upstream`, including its source revision and Catppuccin attribution.
5. Confirm it lists **Oh My Theme Aurora** as `dark · generated`, including its source revision and generated attribution.

The app does not yet apply either Theme Variant; browsing this catalog is read-only.
