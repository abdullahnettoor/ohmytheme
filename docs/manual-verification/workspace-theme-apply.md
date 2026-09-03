# My Mac Workspace theme apply

Use this checklist to verify issue #21 through the menu-bar app.

## Start clean

1. Build and run the `OhMyTheme` scheme on macOS 14 or later.
2. Open the paint-palette item in the menu bar.
3. Confirm My Mac lists macOS, Ghostty, Visual Studio Code, and Starship at the application level.
4. Confirm normal rows do not expose internal Target Instance identifiers. Ambiguous or unavailable rows may show installation, profile, or configuration-path detail.

## Connect Targets

Each setup uses two steps. `Review connection` is read-only. `Approve and connect` executes the reviewed plan after write-boundary validation.

- **macOS:** Review the Automation permission disclosure, then connect System Appearance. Denying Automation must leave the other Targets usable.
- **Ghostty:** Confirm setup names the managed fragment and include. A linked configuration source requires explicit approval. Nix-managed or ambiguous configurations remain unavailable.
- **Visual Studio Code:** Use Microsoft VS Code Stable or Insiders 1.90 or later. Review the pinned companion, selected application executable, Default profile, and local Unix socket behavior. Approve installation, then keep or reload the intended VS Code window so the companion can register.
- **Starship:** Confirm setup limits ownership to the registered palette keys and reports next-prompt activation.

Wallpaper remains unchanged in the bundled demo because neither bundled Theme Variant contains a wallpaper asset.

## Preview and apply

1. Choose `Catppuccin Mocha` or `Oh My Theme Aurora`.
2. Select `Preview workspace change`.
3. Confirm the Workspace preview names the source, revision, expected changes, permissions, setup needs, conflicts, unavailable Targets, and expected reach.
4. Select `Apply to ready Targets`.
5. Confirm one Target-specific failure does not cancel independent ready Targets.
6. Confirm the report groups Capability Outcomes under their Target names and states configuration separately from running-instance reach.
7. Check the expected live behavior:
   - macOS Appearance changes only when the selected variant differs from the current Light/Dark state and Automation is allowed.
   - Ghostty updates current windows when its documented reload succeeds, otherwise the report says Reload Required.
   - VS Code updates the connected profile through the companion. A workspace override remains unchanged and is reported.
   - Starship uses the new theme at the next prompt.

Catppuccin's VS Code theme must already be installed. The pinned companion bundles `Oh My Theme Aurora`.

## Undo and repeated switching

1. After any Target reports `Updated`, confirm `Undo Last Theme Change` is enabled.
2. Change an owned setting externally, then choose Undo. Confirm the affected Capability Outcome reports a conflict and preserves the external edit.
3. Without an external conflict, choose Undo and confirm every changed Target restores its immediately previous state.
4. Switch Aurora to Catppuccin, then Catppuccin to Aurora, and Undo once.
5. Confirm Ghostty settings outside the managed fragment and Starship keys outside the registered palette ownership boundary remain unchanged.

## Recovery

1. Begin Apply and stop Oh My Theme after one Target changes.
2. Relaunch the app.
3. Confirm recovery completes before Preview, Apply, connection, or Undo becomes available.
4. Confirm the next report or operation preserves safe partial results and does not repeat an uncertain mutation blindly.
