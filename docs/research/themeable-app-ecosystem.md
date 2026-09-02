# Themeable macOS developer app ecosystem

Research cutoff: 2026-09-02

## Scope and evidence standard

This is a representative 20-target matrix for a macOS theme switcher. It is not an exhaustive catalog. Sources are limited to official application documentation or source repositories and official theme-port repositories. Catppuccin is used most often because its official ports index covers the selected targets consistently; the adapter conclusions also apply to equivalent Tokyo Night, Nord, and Base16 assets when those projects use the same documented application mechanism.

A row marked `limited verification` was not fully checked before the research cutoff. Its conservative tier should not be promoted until the linked first-party instructions have been reviewed.

### Feasibility tiers

| Tier | Meaning |
|---|---|
| `automatic` | A supported target command, API, or directly managed file applies the theme without prior companion setup or a user activation step. |
| `automatic after setup` | A one-time plugin, extension, include, shell hook, Automation consent, or folder authorization is required. Later switches can use a supported path. |
| `manual reload` | Theme files can be managed safely, but a documented reload, restart, cache rebuild, or reopen remains part of activation. |
| `install-only` | The asset can be installed or imported safely, but selection remains a documented in-app user action. |
| `unsupported` | No supported mutation route exists for the requested setting. |

## Top-20 matrix

| # | Target | Theme or config mechanism | Safe ownership method | Activation or reload path | Plugin needs | Profile and version limits | Tier | First-party evidence |
|---:|---|---|---|---|---|---|---|---|
| 1 | Ghostty | Named built-in theme, or a theme file in the Ghostty `themes` directory selected by `theme = Catppuccin <flavor>`. Ghostty config can be split with `config-file`. | Own one generated theme and one generated config fragment. Ask once for an include from the user's main config instead of rewriting it. | Reload config with `Cmd+Shift+,`. On macOS, Ghostty's AppleScript support can provide the post-setup automation path. | None. | AppleScript automation requires Ghostty 1.3 or later. Theme and other config can be profile-like through separate config files, but Ghostty does not use imported GUI profiles. | `automatic after setup` | [Ghostty configuration](https://ghostty.org/docs/config), [themes](https://ghostty.org/docs/features/theme), [theme reference](https://ghostty.org/docs/config/reference#theme), [AppleScript](https://ghostty.org/docs/features/applescript), [official Catppuccin port](https://github.com/catppuccin/ghostty) |
| 2 | iTerm2 | Import `.itermcolors` as a color preset and select it for a profile. iTerm2 also documents JSON dynamic profiles. | Prefer an owned dynamic profile when creating a new managed profile. Do not replace existing profile preferences. For an existing profile, install the preset and leave assignment to the user. | Import and select through Settings, Profiles, Colors, Color Presets. No supported unattended preset assignment was verified in this pass. | None for import. A separate iTerm2 script/API integration would need its own review and user setup. | Selection is per profile. Dynamic profiles supplement rather than replace user profiles, but their identifiers and precedence must remain stable. | `install-only` | [iTerm2 color settings](https://iterm2.com/documentation-preferences-profiles-colors.html), [dynamic profiles](https://iterm2.com/documentation-dynamic-profiles.html), [official Catppuccin port](https://github.com/catppuccin/iterm) |
| 3 | Terminal.app | Import a `.terminal` profile, then select it or make it the default. | Own the exported profile asset. Never write Terminal's preferences database or overwrite the user's existing profiles. | Settings, Profiles, action menu, Import; then select the profile and optionally set it as default. | None. | Selection is per Terminal profile. Import does not safely imply replacing the current or default profile. | `install-only` | [Apple Terminal profile guide](https://support.apple.com/guide/terminal/use-profiles-trml107/mac), [official Catppuccin port](https://github.com/catppuccin/Terminal.app) |
| 4 | Alacritty | Import an owned TOML palette from `alacritty.toml` through `general.import`. | Own only the imported theme file. Add one include entry with a TOML-aware edit and retain a rollback record. | Alacritty exposes `live_config_reload`; imported-file watcher behavior was not firmly verified here, so restart or an explicit config reload should remain the conservative activation path. | None. | Current port uses TOML. YAML assets are kept on a separate port tag for older Alacritty configurations. | `manual reload` | [Alacritty configuration reference](https://alacritty.org/config-alacritty.html), [official Alacritty source](https://github.com/alacritty/alacritty), [official Catppuccin port](https://github.com/catppuccin/alacritty) |
| 5 | kitty | Catppuccin is bundled in current kitty releases and can be selected with the `themes` kitten. | Let kitty's supported theme kitten manage its generated theme selection. Do not synthesize writes to unrelated kitty settings. | Run `kitty +kitten themes --reload-in=all <theme>` to select the theme and reload all kitty windows. | None. | The port reports bundling in kitty newer than 0.26.0. Older versions can use installed theme files but need separate handling. | `automatic` | [kitty themes kitten](https://sw.kovidgoyal.net/kitty/kittens/themes/), [official Catppuccin port](https://github.com/catppuccin/kitty) |
| 6 | WezTerm | Catppuccin is bundled as a named `color_scheme` in `wezterm.lua`. Lua can choose a scheme from `wezterm.gui.get_appearance()`. | Prefer a small owned Lua module required once by the user's config. Do not replace `wezterm.lua`. If no include is accepted, offer a minimal, reviewable edit. | WezTerm documents config reload behavior, but reliable watching of a separately generated required module was not verified in this pass. Keep manual Reload Configuration or restart as the supported fallback. | None. | Scheme names depend on the WezTerm release containing the bundled palette. Appearance-dependent logic runs in the GUI context. | `manual reload` | [WezTerm color schemes](https://wezterm.org/config/appearance.html), [`color_scheme`](https://wezterm.org/config/lua/config/color_scheme.html), [configuration files](https://wezterm.org/config/files.html), [official Catppuccin port](https://github.com/catppuccin/wezterm) |
| 7 | Visual Studio Code | Install a color-theme extension and set `workbench.colorTheme`. A companion extension can update settings through `WorkspaceConfiguration.update`. | Own the companion extension and its state. Mutate only `workbench.colorTheme` at a declared user, profile, remote, or workspace scope. Preserve the prior value for rollback. | Apply through the extension API or select with Preferences: Color Theme. No editor restart is normally required. | Catppuccin theme extension. Unattended switching requires a trusted companion extension. | VS Code profiles, workspace settings, remote windows, and Settings Sync can each choose a different effective value. Immutable Nix extension directories are a known installation limit in the port. | `automatic after setup` | [VS Code themes](https://code.visualstudio.com/docs/configure/themes), [settings](https://code.visualstudio.com/docs/configure/settings), [color-theme extensions](https://code.visualstudio.com/api/extension-guides/color-theme), [`WorkspaceConfiguration`](https://code.visualstudio.com/api/references/vscode-api#WorkspaceConfiguration), [official Catppuccin port](https://github.com/catppuccin/vscode) |
| 8 | Zed | Install the Catppuccin extension, then select a theme. Custom theme JSON can also be placed in Zed's themes directory. | Prefer the official extension. If generating a custom accent variant, own only its JSON file under `~/.config/zed/themes/`. Do not replace the main settings file. | Install through `zed: extensions`; select through `theme selector: toggle`. The port says custom accent files require a Zed restart. No supported external selector was verified. | Catppuccin extension, unless using a local custom theme file. | Extension themes and generated accent variants have different installation paths. Selection can differ between light and dark modes in Zed settings. | `install-only` | [Zed themes](https://zed.dev/docs/themes), [Zed extensions](https://zed.dev/docs/extensions), [official Catppuccin port](https://github.com/catppuccin/zed) |
| 9 | Neovim | Install the Lua colorscheme plugin, call `require("catppuccin").setup()` before `:colorscheme catppuccin`, and source that configuration from the user's Neovim config. | Own a generated Lua fragment and request one `require` or `dofile` seam. Do not replace `init.lua` or the user's plugin specification. | Run `:source` on the owned fragment or restart Neovim, then invoke `:colorscheme`. External switching for every running instance would require a separately configured Neovim server and was not counted. | Catppuccin Neovim plugin and the user's plugin manager, or a native package installation. | Current plugin requires Neovim 0.8 or later. The old Vim branch was dropped. Vim 9.2.0219 and Neovim 0.12 bundle a separately maintained Catppuccin-named scheme, which the port warns is not maintained by Catppuccin. | `manual reload` | [Neovim syntax and `:colorscheme`](https://neovim.io/doc/user/syntax.html), [Neovim packages](https://neovim.io/doc/user/repeat.html#packages), [official Catppuccin port](https://github.com/catppuccin/nvim) |
| 10 | JetBrains IDEs | Install the theme plugin from JetBrains Marketplace or from a plugin ZIP. UI theme and editor color scheme are separate selectors. | Use the IDE's plugin manager. Do not modify JetBrains settings XML or preference storage directly. | Select the UI theme and editor scheme in Settings. The port says restart is optional, but no supported external selection API was verified. | Catppuccin plugin. | Applies across supported JetBrains IDE products, subject to plugin compatibility declared for each IDE build. UI chrome and editor syntax can be selected independently. | `install-only` | [JetBrains plugin management](https://www.jetbrains.com/help/idea/managing-plugins.html), [UI themes](https://www.jetbrains.com/help/idea/user-interface-themes.html), [color schemes](https://www.jetbrains.com/help/idea/configuring-colors-and-fonts.html), [official Catppuccin port](https://github.com/catppuccin/jetbrains) |
| 11 | Sublime Text | Install the Catppuccin package with Package Control or in the Packages directory, select its color scheme, and use Sublime's Adaptive UI theme. | Let Package Control own the package. For local development, own only a package folder, not `Preferences.sublime-settings`. | Select the color scheme in the UI. Sublime reloads changed theme resources during package development, but initial selection remains a user action. | Catppuccin package; Package Control is the normal installer but manual package installation is possible. | The color scheme controls syntax colors. Adaptive UI is a separate Sublime theme choice needed for surrounding chrome to follow the scheme. | `install-only` | [Sublime color schemes](https://www.sublimetext.com/docs/color_schemes.html), [packages](https://www.sublimetext.com/docs/packages.html), [official Catppuccin port](https://github.com/catppuccin/sublime-text) |
| 12 | Xcode | Install `.xccolortheme` files in `~/Library/Developer/Xcode/UserData/FontAndColorThemes`, then select one in Xcode's Themes settings. | Own only files with an Oh My Theme namespace in `FontAndColorThemes`. Never replace the whole `UserData` directory or Xcode preferences. | Select the installed theme in Xcode settings. A supported external selector or reliable live reload was not verified. | None. | These files theme the source editor, not all Xcode UI chrome. Font availability can affect the rendered result. | `install-only` | [Xcode source-editor customization](https://developer.apple.com/documentation/xcode/customizing-the-source-editor), [official Catppuccin port](https://github.com/catppuccin/xcode) |
| 13 | tmux | Source the Catppuccin plugin from `tmux.conf`, manually or through TPM. Configure flavor and modules with documented tmux options. | Install the plugin in an owned directory and request one `run-shell` or `source-file` line. Keep generated options in a separate file when possible. | Run `tmux source-file ~/.tmux.conf`, or source the owned fragment directly, after updating it. This command can be issued by the switcher after one-time setup. | Catppuccin tmux plugin; TPM is optional. | Main plugin requires tmux 3.2 or later. The port documents a static fallback for older tmux. tmux 3.6 adds dark/light theme hooks. Existing servers must be re-sourced. | `automatic after setup` | [tmux getting started and configuration](https://github.com/tmux/tmux/wiki/Getting-Started), [official tmux source](https://github.com/tmux/tmux), [official Catppuccin port](https://github.com/catppuccin/tmux) |
| 14 | bat | Put `.tmTheme` files under `$(bat --config-dir)/themes`, rebuild bat's syntax/theme cache, and select through the bat config or `BAT_THEME`. | Own only the added theme files. Prefer an owned environment fragment for `BAT_THEME`; otherwise update only the theme key in bat's config with rollback. | Run `bat cache --build`. New bat processes then use the selected theme; there is no long-running UI to reload. | None. | Config and cache locations should be discovered with bat commands rather than assumed. A true-color terminal is needed for intended rendering. | `automatic` | [official bat source and README](https://github.com/sharkdp/bat), [official Catppuccin port](https://github.com/catppuccin/bat) |
| 15 | fzf | Set Catppuccin color options in `FZF_DEFAULT_OPTS` from the shell startup configuration. Official port snippets cover common shells. | Own one shell-specific fragment. Ask once for a `source` line from `.zshrc`, `.bashrc`, Fish, or the relevant shell startup file. | New fzf processes inherit the environment. Existing shells must source the fragment again or start a new shell; a one-time shell hook can make later sessions automatic. | None. | Syntax differs by shell. Environment inheritance means changing the file cannot update already-running parent shells. | `automatic after setup` | [official fzf source and README](https://github.com/junegunn/fzf), [official Catppuccin port](https://github.com/catppuccin/fzf) |
| 16 | Starship | Add named Catppuccin palette tables to `starship.toml` and set `palette = "catppuccin_<flavor>"`. | Use a TOML-aware edit that owns only the named palette tables and the `palette` key. Preserve comments, unrelated prompt configuration, mode, and a prior-value rollback. No verified include seam exists. | Save the config and render a new prompt. Starship reads the palette through its normal configuration path; no persistent app process needs restarting. | None beyond Starship itself. | The palette changes modules that use palette names. Modules with hard-coded colors remain unchanged. A malformed shared TOML file can affect the entire prompt, so edits must be transactional. | `automatic` | [Starship configuration](https://starship.rs/config/), [Starship palettes](https://starship.rs/advanced-config/#style-strings), [official Catppuccin port](https://github.com/catppuccin/starship) |
| 17 | lazygit | Set `gui.theme` in YAML, or merge a separate theme config through `--use-config-file` or `LG_CONFIG_FILE`. Discover the macOS config directory with `lazygit --print-config-dir`. | Prefer a separate owned theme YAML merged with the user's config. Do not replace the user's main `config.yml`. | Close and reopen lazygit with the merged config-file list. Reliable live reload of an active lazygit process was not verified. | None. | macOS normally uses `~/Library/Application Support/lazygit/config.yml`, but command-based discovery is safer. Merge order matters when multiple config files define `gui.theme`. | `manual reload` | [lazygit configuration](https://github.com/jesseduffield/lazygit/blob/master/docs/Config.md), [official lazygit source](https://github.com/jesseduffield/lazygit), [official Catppuccin port](https://github.com/catppuccin/lazygit) |
| 18 | Obsidian | Community themes are installed and selected per vault from Appearance settings. A theme package lives inside that vault's `.obsidian/themes` area. | Own only the Catppuccin theme directory within each user-authorized vault. Never replace `.obsidian`, `appearance.json`, or another theme's files. | User selects the installed theme in Settings, Appearance. Exact file-change reload behavior was not verified before cutoff. | Community theme package, not an executable community plugin. | Vault-scoped. Every vault needs separate installation or authorization. Restricted Mode concerns plugins, but theme installation still exposes third-party CSS to the vault UI. `limited verification` | `install-only` | [Obsidian themes help](https://help.obsidian.md/themes), [official Catppuccin ports index](https://catppuccin.com/ports/), [official Catppuccin Obsidian port, not fully reviewed](https://github.com/catppuccin/obsidian) |
| 19 | Raycast | The official Catppuccin port exists, but its exact preset file format, supported import route, and selection behavior were not fully reviewed before cutoff. Do not infer a preferences-file format from Raycast's storage. | Install only the official exported theme/preset artifact through Raycast's documented UI once verified. Do not edit Raycast defaults, databases, or container files. | Treat activation as an in-app import and selection step until an official command, deeplink, or API is confirmed. `limited verification` | No plugin requirement was verified. | Account sync, Raycast version compatibility, and whether a custom theme affects all appearance modes remain unverified. | `install-only` | [Raycast manual](https://manual.raycast.com/), [official Catppuccin ports index](https://catppuccin.com/ports/), [official Catppuccin Raycast port, not fully reviewed](https://github.com/catppuccin/raycast) |
| 20 | macOS appearance and wallpaper | Wallpaper has a public `NSWorkspace.setDesktopImageURL` API. System Dark Mode is writable through the System Events scripting dictionary after Automation consent. AppKit exposes the current control accent color, but no public system accent setter was found. | Use security-scoped user selection for wallpaper files in a sandboxed app. Use Apple Events only after explicit consent. Store no writes to undocumented global preference keys. | Wallpaper can apply immediately per screen. Dark Mode can switch after Automation authorization. Accent-color mutation has no supported activation path. The aggregate target is `unsupported` because a complete system appearance adapter cannot set accent color through public API. | None. Automation permission is required for System Events control. | Wallpaper is per screen or Space depending on system behavior and API options. Dark Mode and wallpaper are supported sub-capabilities. Accent mutation is not. | `unsupported` | [`NSWorkspace.setDesktopImageURL`](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)), [`NSColor.controlAccentColor`](https://developer.apple.com/documentation/appkit/nscolor/controlaccentcolor), [sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), [System Events source dictionary](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.15.sdk/System/Library/CoreServices/System%20Events.app/Contents/Resources/SystemEvents.sdef) |

## Adapter families

### Managed text configuration

Targets: Ghostty, Alacritty, WezTerm, tmux, bat, fzf, Starship, and lazygit.

This family should share:

1. Config-location discovery through the target's command or documented platform path.
2. An owned generated fragment whenever the format supports imports, includes, or multiple config files.
3. Format-aware mutation only for targets without an include seam.
4. Atomic writes, retained previous values, file-mode preservation, and validation before activation.
5. A target-specific activation command. There is no safe generic assumption that saving a file reloads an app.

The strongest seams are Ghostty's split config, Alacritty's import, tmux's sourced file, shell-sourced fzf options, and lazygit's merged config-file list. Starship needs extra care because the reviewed configuration does not establish a separate include mechanism.

### Extension and plugin systems

Targets: Visual Studio Code, Zed, Neovim, JetBrains IDEs, Sublime Text, and Obsidian.

Installation and activation are separate operations. The shared adapter can discover installation state and direct users to the official extension or package channel, but selection must remain target-specific. VS Code is the best automation candidate because its supported extension API can update the theme setting. The other reviewed targets should remain install-only or manual-reload until an official selector API is established.

### Imported profiles and theme assets

Targets: iTerm2, Terminal.app, Xcode, and provisionally Raycast.

The adapter owns a portable artifact and imports or installs it through a documented route. It must not claim ownership of the user's current profile. Importing an asset does not mean that selecting it, making it the default, or applying it to every profile is supported automation.

### Apple APIs and Apple Events

Target: macOS wallpaper and Dark Mode.

Wallpaper belongs behind an AppKit adapter with sandbox-aware file authorization. Dark Mode belongs behind a System Events adapter with explicit Automation consent and clear error reporting. Neither adapter justifies undocumented preference writes for accent color.

## Supported methods and private preference hacks

### Supported methods

The following are acceptable implementation surfaces:

- Public application APIs, documented commands, documented config keys, and documented import flows.
- Official extension, plugin, package, and theme directories.
- User-approved includes or source lines that point to files owned by Oh My Theme.
- Format-aware edits to narrowly declared keys when the target has no include mechanism.
- Apple public frameworks, security-scoped file access, and declared Apple Events after consent.
- Target-provided reload commands such as kitty's themes kitten, tmux `source-file`, and bat `cache --build`.

### Private or unsupported hacks

Keep these out of production adapters:

- `defaults write` against undocumented keys such as `AppleAccentColor`, `AppleHighlightColor`, or `AppleInterfaceStyle`.
- Direct edits to another application's preferences plist, SQLite database, app container, or CloudKit state.
- Killing `cfprefsd`, Dock, Finder, SystemUIServer, or an application merely to force an undocumented preference to appear.
- GUI keyboard or mouse simulation presented as an API.
- Replacing a user's complete config, profile collection, vault settings, or IDE settings directory.
- Assuming that a file watcher observes imported or required fragments when only the root config is documented as watched.

The absence of a public macOS accent setter is a product boundary, not a reason to hide a private preference mutation behind an “advanced” toggle.

## Ownership and rollback contract

A shared adapter contract should enforce these rules:

1. Own generated files, not whole user configuration files.
2. Prefer one-time includes, imports, or source directives.
3. For structured files without includes, update only registered keys with a syntax-aware parser.
4. Write atomically and preserve owner, mode, comments, line endings, and unrelated values where the format permits.
5. Record the previous effective setting and remove only Oh My Theme-owned material during uninstall.
6. Validate generated syntax before invoking a reload command.
7. Treat each app profile, VS Code scope, Obsidian vault, terminal profile, display, and remote environment as a distinct target instance.
8. Report “installed but not selected” separately from “active.”

## Licensing and attribution

The upstream Catppuccin palette repository declares the palette under the [MIT License](https://github.com/catppuccin/catppuccin/blob/main/LICENSE). The reviewed Ghostty, iTerm2, Terminal.app, Alacritty, kitty, Zed, Neovim, JetBrains, Sublime Text, Xcode, tmux, bat, fzf, Starship, and lazygit port repositories also displayed MIT licensing during this pass. Their repository links in the matrix are the authoritative source for each asset and its notices.

Exact port-level license files for WezTerm, Visual Studio Code, Obsidian, and Raycast were not independently verified before cutoff. Do not infer that a port inherits the palette repository's license. Verify the license at the pinned revision before vendoring any of those assets.

Implementation policy:

- Prefer invoking the target's official installer or referencing the upstream port rather than vendoring assets.
- If assets are bundled, pin the upstream revision and retain its copyright and license notice in the distribution and generated-artifact metadata.
- Preserve upstream theme names. Clearly label Oh My Theme-generated modifications, especially contrast, accent, transparency, or syntax changes.
- Record both the palette project and the application-specific port in attribution. A palette citation alone does not credit conversion and maintenance work in the port.
- Review trademarks separately. An open-source color file license does not grant permission to imply endorsement by Apple, an application vendor, or the theme project.

## Recommended implementation order

1. kitty and bat, because they expose direct supported commands and have low ownership risk.
2. Ghostty, tmux, fzf, and VS Code, because one-time setup creates a durable supported automation seam.
3. Starship and lazygit, with transactional parsers and strong rollback tests.
4. Alacritty and WezTerm, after imported-fragment reload behavior is tested against pinned app versions.
5. Import-only adapters for iTerm2, Terminal.app, Zed, JetBrains IDEs, Sublime Text, Xcode, and Obsidian.
6. macOS wallpaper and Dark Mode as separate capabilities. Leave system accent unsupported.
7. Raycast only after its official import format, activation flow, version support, and port license are verified.
