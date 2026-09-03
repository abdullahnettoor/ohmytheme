# Bundled theme catalog

## Record

| Item | Result | Evidence |
| --- | --- | --- |
| Bundled packs validate | Pass, 2026-09-03 | `./Scripts/test-themes.sh` validated both bundled packs. |
| Generated catalog is deterministic | Pass, 2026-09-03 | `./Scripts/test-themes.sh` regenerated and matched `Themes/catalog.json`; the golden package test also passed in `./Scripts/test.sh`. |
| Menu displays both variants and provenance | Pending human check | Follow the steps below |

## Human check

1. Run `./Scripts/build-app.sh`.
2. Open `.build/DerivedData/Build/Products/Debug/OhMyTheme.app`.
3. Open the menu-bar item.
4. Confirm the panel lists **Catppuccin Mocha** as `dark · upstream`, including its source revision and Catppuccin attribution.
5. Confirm it lists **Oh My Theme Aurora** as `dark · generated`, including its source revision and generated attribution.

Both variants can be selected for Workspace preview and Apply. Catppuccin Mocha has no `wallpaper` field, and Oh My Theme Aurora has no `wallpaper` field. The bundled variants therefore contain no wallpaper and must leave every display unchanged.
