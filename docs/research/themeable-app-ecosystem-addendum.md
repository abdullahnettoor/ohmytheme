# Themeable app ecosystem addendum

Research cutoff: 2026-09-02

## Scope and evidence standard

This addendum covers developer-workspace targets missing from the main ecosystem study. Sources are limited to official application documentation or source and official theme-port repositories. The gathered evidence was sufficient for five targets. The other targets remain `unverified`; no feasibility tier is assigned to them.

The [official Catppuccin ports registry](https://catppuccin.com/ports/) lists ports for Warp, git-delta, btop, eza, Helix, Fish, and Nushell. No entry was observed there for Cursor, Docker Desktop, GitHub Desktop, TablePlus, or Arc. Registry absence does not prove that an application is unthemeable.

### Feasibility tiers

| Tier | Meaning |
|---|---|
| `automatic` | A supported command, API, or directly managed file applies without prior companion setup or user activation. |
| `automatic after setup` | A one-time plugin, include, shell hook, consent, or folder authorization is needed. |
| `manual reload` | Files can be managed safely, but a documented reload, restart, or reopen remains. |
| `install-only` | An asset can be installed safely, but selection remains an in-app user action. |
| `unsupported` | No supported mutation route exists. |

`Unverified` is an evidence status, not an added feasibility tier.

## Target matrix

| Target | Theme or config mechanism | Safe ownership | Activation or reload | Profiles and limits | Feasibility tier | First-party evidence |
|---|---|---|---|---|---|---|
| Cursor | Unverified. No Cursor-specific theme mechanism was established from the gathered first-party evidence. VS Code extension compatibility must not be assumed. | Do not install a VS Code theme extension into Cursor or edit Cursor settings until Cursor documents the route or an official port explicitly supports it. | Unverified. | Profile, workspace, remote, and sync behavior are unverified. | `unverified`, no tier assigned | [Official Catppuccin ports registry](https://catppuccin.com/ports/) |
| Warp | Install theme files in `$HOME/.warp/themes` on macOS. | Own only the installed theme files. Do not edit Warp preferences or internal storage. | Restart Warp so it loads the files, then select the theme in Settings, Themes. Selection remains manual. | Profile or workspace scoping was not verified. The registry reports that the port has no active maintainer. | `install-only` | [Official Catppuccin Warp port](https://github.com/catppuccin/warp), [official ports registry](https://catppuccin.com/ports/) |
| git-delta | Include the port's `catppuccin.gitconfig`, then set `delta.features` to `catppuccin-<flavour>`. | Own the installed Catppuccin config file. Add only the required include and `delta.features` value with a Git-config-aware edit and retained rollback. Do not replace the user's Git configuration. | New delta invocations read the Git configuration. No persistent application reload or theme-selection UI is involved. | Git scope behavior was not separately verified. Delta versions older than 0.19 require the Catppuccin bat theme according to the port. | `automatic after setup` because the include is a one-time setup seam | [Official Catppuccin delta port](https://github.com/catppuccin/delta) |
| btop | Install selected theme files in `$XDG_CONFIG_HOME/btop/themes/`, or `~/.config/btop/themes/` when `XDG_CONFIG_HOME` is unset. | Own only the installed theme files. A supported automated edit of `btop.conf` was not verified. | Launch btop, press Esc, open Options, and select the flavor. | Profile behavior and live reload were not verified. | `install-only` | [Official Catppuccin btop port](https://github.com/catppuccin/btop) |
| eza | An official Catppuccin port exists, but its file format, config path, environment variables, activation behavior, and version limits were not reviewed far enough to support an adapter. | Do not create or edit eza configuration until the official port instructions and eza source documentation are checked. | Unverified. | Config-directory overrides and per-shell behavior are unverified. | `unverified`, no tier assigned | [Official Catppuccin eza port](https://github.com/catppuccin/eza), [official ports registry](https://catppuccin.com/ports/) |
| Helix | The default Catppuccin variant is included with Helix. Other variants can be copied to `$HOME/.config/helix/themes/` and selected with `theme = "catppuccin_<palette>"` in `config.toml`. Theme files can inherit another theme. | Own only added theme files. Change only the `theme` key with a TOML-aware edit and rollback. Do not replace `config.toml`. | File-based selection is verified. Runtime `:theme` behavior and external activation of a running editor were not verified, so reopen or restart remains the conservative path. | True color may require `[editor] true-color = true`. Separate profile semantics were not verified. | `manual reload` | [Official Catppuccin Helix port](https://github.com/catppuccin/helix) |
| Fish | Fish 4.4.0 and newer bundle all Catppuccin flavors. Select one with `fish_config theme choose ...`. Older releases can install theme files in `~/.config/fish/themes/` or use Fisher. | Prefer the supported `fish_config` command. Do not edit Fish's universal-variable storage. For older releases, own only installed theme files or use the user's package manager. | Run `fish_config theme choose ...`. Exact persistence and propagation to already-running shells were not verified in this pass. | Fish 4.3 added dynamic light and dark switching. Static themes are available for Fish 4.2 and earlier. The port's upgrade note references `~/.config/fish/conf.d/fish_frozen_theme.fish`. | `automatic` on Fish 4.4 or newer; `automatic after setup` on older releases that first need theme installation | [Official Catppuccin Fish port](https://github.com/catppuccin/fish) |
| Nushell | An official Catppuccin port exists, but its config fragment, source mechanism, config path, activation behavior, and version limits were not reviewed far enough to support an adapter. | Do not edit `config.nu` or another Nushell file until the official port and Nushell configuration documentation establish a safe source seam. | Unverified. | Profile and process-reload behavior are unverified. | `unverified`, no tier assigned | [Official Catppuccin Nushell port](https://github.com/catppuccin/nushell), [official ports registry](https://catppuccin.com/ports/) |
| Docker Desktop | Unverified. No supported custom-palette mechanism or external appearance selector was established from the gathered first-party evidence. | Do not edit Docker Desktop preferences, app-container files, or databases. | Unverified. | Account, organization, and appearance-mode behavior are unverified. | `unverified`, no tier assigned | [Official Catppuccin ports registry](https://catppuccin.com/ports/) |
| GitHub Desktop | Unverified. No supported custom-palette mechanism or external appearance selector was established from the gathered first-party evidence. The archived Catppuccin GitHub website userstyle is not evidence for GitHub Desktop. | Do not edit GitHub Desktop preferences or internal databases. | Unverified. | Repository, account, and system-appearance behavior are unverified. | `unverified`, no tier assigned | [Official Catppuccin ports registry](https://catppuccin.com/ports/) |
| TablePlus | Unverified. No supported theme import, theme file, or external selector was established from the gathered first-party evidence. | Do not edit TablePlus preferences, connection storage, or internal databases. | Unverified. | Connection, workspace, and editor-theme scoping are unverified. | `unverified`, no tier assigned | [Official Catppuccin ports registry](https://catppuccin.com/ports/) |
| Arc | Unverified. No supported external route for changing Arc Space colors or applying a custom palette was established from the gathered first-party evidence. | Do not edit Arc preferences, profile data, browser databases, or synced state. | Unverified. | Space, profile, account-sync, and device-sync behavior are unverified. | `unverified`, no tier assigned | [Official Catppuccin ports registry](https://catppuccin.com/ports/) |

## Unsupported and unverified routes

No target is classified as `unsupported` solely because it lacks an entry in the Catppuccin registry. The gathered evidence does not prove that any unverified target has no supported mutation route.

The following routes remain unverified and must not be implemented as supported adapters:

- Treating Cursor as interchangeable with VS Code.
- Selecting a Warp theme without its documented restart and in-app selection steps.
- Editing `btop.conf` to bypass btop's documented theme picker.
- Claiming live Helix switching through `:theme` without first-party verification.
- Claiming how Fish persists or propagates `fish_config theme choose` across running shells.
- Creating eza or Nushell config fragments before their official instructions are reviewed.
- Editing private preferences, plists, databases, app containers, or synced state for Docker Desktop, GitHub Desktop, TablePlus, or Arc.
- Using GUI simulation as a theme activation mechanism.
