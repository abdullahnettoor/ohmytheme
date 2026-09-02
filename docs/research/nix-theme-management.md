# Nix-based theme management on macOS

Research date: 2026-09-02

## Question

Should Oh My Theme invoke Nix, generate Nix configuration for existing users, or borrow Nix's design while keeping its own macOS adapters?

## Recommendation

For the MVP, do not invoke Nix and do not install or manage Nix, Home Manager, nix-darwin, or Stylix. Keep the native adapter plan in [`docs/architecture/mvp-plan.md`](../architecture/mvp-plan.md): Oh My Theme owns small generated artifacts, makes a minimal one-time connection from user configuration, activates each target through its documented interface, and records a target-specific rollback receipt.

Borrow these ideas from Nix and Home Manager:

- content-addressed generated artifacts;
- immutable prepared plans;
- explicit ownership of each managed path;
- a check phase before the first write;
- ordered, idempotent activation steps;
- generations retained long enough for recovery;
- refusal to overwrite an unexpected file.

Add a declarative export after the MVP. Export a data-only theme description and an optional Home Manager or Stylix module into a location chosen by the user. Do not edit an existing flake, add imports, update `flake.lock`, or run `home-manager switch` automatically. The user's Nix configuration remains the source of truth, and the user decides when to review, import, and activate the export.

A later opt-in "Nix-owned mode" is possible, but it needs a strict handoff. The user must declare that Nix owns the selected targets, register the exact flake output and activation command, and stop Oh My Theme's direct adapters from writing those targets. This mode should invoke the user's existing configuration, not a separate app-managed Home Manager configuration.

The reason is ownership, not lack of capability. Home Manager and Stylix can generate many theme files. They are a poor fit for a low-latency theme switcher when another Home Manager configuration or the target application already owns those files.

## What each layer does

### Nix

Nix builds values into uniquely named paths in the Nix store and exposes selected results through profiles. A profile points to a generation, and changing the profile's current-generation symlink is atomic on Unix. Previous generations can be selected again. These guarantees cover the store and profile pointer. They do not make arbitrary macOS preferences or application processes transactional. [Nix profiles](https://nix.dev/manual/nix/latest/package-management/profiles)

On a normal multi-user macOS installation, a privileged owner controls the store and database. Unprivileged clients send store operations to the Nix daemon, which runs builds under dedicated build users. Daemon socket permissions and the `allowed-users` and `trusted-users` settings decide who can connect and which privileged choices they may make. [Nix multi-user mode](https://nix.dev/manual/nix/latest/installation/multi-user), [nix-darwin Nix settings reference](https://nix-darwin.github.io/nix-darwin/manual/index.html#opt-nix.settings.allowed-users)

Nix alone does not know that a generated file is a Ghostty theme, that VS Code has several active profiles, or that a running process must reload. Those behaviors come from Home Manager modules, nix-darwin activation scripts, Stylix target modules, or another caller.

### Home Manager

Home Manager evaluates one user configuration into a generation and then runs that generation's activation script. Its activation model has a check side and a write side separated by `writeBoundary`. The documentation in source requires checks before the boundary to avoid side effects, requires effectful steps after it, asks activation steps to be idempotent, and defines a dry-run convention for activation commands. [Home Manager activation option source](https://github.com/nix-community/home-manager/blob/master/modules/home-environment.nix)

For managed files, Home Manager normally builds file content in the Nix store and links the requested path in the home directory to the generation. Before writing, `checkLinkTargets` rejects an existing unmanaged target unless configuration explicitly allows replacement or backup behavior. During a generation change, Home Manager first removes links owned by the old generation that are absent from the new one, then creates links from the new generation. It skips deletion when a path no longer points into a Home Manager generation. [Home Manager file activation source](https://github.com/nix-community/home-manager/blob/master/modules/files.nix)

`home.file.<name>.force` is deliberately sharp. Its option description says Home Manager will silently delete the target whether it is a file or link. `onChange` runs after the new link is in place. Recursive directory management creates a real directory whose leaves are links, while non-recursive directory management links the whole directory. [Home Manager file option source](https://github.com/nix-community/home-manager/blob/master/modules/lib/file-type.nix)

The standalone `home-manager switch` command builds a generation, sets the user's `home-manager` profile to it, and runs its activation script. `home-manager switch --rollback` rolls that same profile back and activates the selected old generation. The profile name is shared by standalone Home Manager runs for that user. A second, app-managed configuration would therefore replace the user's current Home Manager generation rather than add an isolated theme-only generation. [Home Manager command source](https://github.com/nix-community/home-manager/blob/master/home-manager/home-manager)

### nix-darwin

nix-darwin evaluates a system configuration, stores it as a Nix generation, and runs system activation. Its current `darwin-rebuild` source requires root for `switch`, `activate`, `rollback`, and `check`. `switch` places the built system in the configured system profile and runs its `activate` program. `--rollback` moves the profile to an earlier generation and runs that generation's activation program. [nix-darwin `darwin-rebuild` source](https://github.com/nix-darwin/nix-darwin/blob/master/pkgs/nix-tools/darwin-rebuild.sh)

The project setup itself is administrative. The official README creates `/etc/nix-darwin`, installs through `sudo nix run ... darwin-rebuild -- switch`, and uses `sudo darwin-rebuild switch` for later activation. nix-darwin also manages the Nix installation and daemon by default unless `nix.enable` is disabled. [nix-darwin README](https://github.com/nix-darwin/nix-darwin), [nix-darwin `nix.enable`](https://nix-darwin.github.io/nix-darwin/manual/index.html#opt-nix.enable)

nix-darwin can link declared files into `/etc`, install fonts, manage launchd jobs, and write documented or custom preference values through activation. Its own manual also records cases that do not automatically undo. For example, setting `system.defaults.NSGlobalDomain.AppleInterfaceStyle` to `null` does not restore Light mode; the user must delete the preference manually. This is direct evidence that selecting an old Nix generation does not imply a perfect inverse for every imperative macOS side effect. [nix-darwin options](https://nix-darwin.github.io/nix-darwin/manual/index.html#opt-system.defaults.NSGlobalDomain.AppleInterfaceStyle)

### Stylix

Stylix is a Nix module framework layered on NixOS, Home Manager, nix-darwin, and Nix-on-Droid. It accepts a Tinted Theming scheme or a wallpaper-derived scheme, fonts, and a polarity, then feeds target-specific modules. Most targets auto-enable when the corresponding program is installed unless `stylix.autoEnable` is disabled. [Stylix configuration](https://nix-community.github.io/stylix/configuration.html)

On macOS, Stylix's own installation guide is explicit: adding its nix-darwin module "won't have an effect on the looks of MacOS" and mainly arranges Home Manager integration. Application theming still depends on Home Manager target modules. Standalone Home Manager is also supported. Stylix requires compatible Nixpkgs, Home Manager, and Stylix inputs and warns users to update rolling inputs together. [Stylix installation](https://nix-community.github.io/stylix/installation.html)

Stylix's repository contains target modules for Ghostty, VS Code, Zed, tmux, Neovim, btop, and many other programs. That breadth is useful reference material, but the presence of a target module does not establish immediate activation in an already-running macOS application. This research did not verify the live-reload behavior, conflict policy, or macOS version behavior of every target module. [Stylix modules](https://github.com/nix-community/stylix/tree/master/modules)

Stylix also uses a 16-color Base16-style model. Oh My Theme's planned semantic model has separate UI, terminal, ANSI, and syntax roles. Exporting an Oh My Theme variant to Stylix therefore needs a documented mapping and may lose distinctions. Stylix's `config.lib.stylix.colors` remains useful as a compact interchange form, but it should not replace Oh My Theme's richer canonical model. [Stylix color-scheme configuration](https://nix-community.github.io/stylix/configuration.html#color-scheme)

## Comparison

| Concern | Invoke Nix from the app | Generate configuration for existing Nix users | Borrow the design, keep native adapters |
| --- | --- | --- | --- |
| Product dependency | Requires an installed and working Nix daemon, compatible flake inputs, and usually Home Manager or nix-darwin. | No runtime dependency for other users. Nix users opt in to the export. | No Nix dependency. Matches the planned notarized menu-bar app. |
| Source-of-truth ownership | Ambiguous unless Nix owns the whole selected target. A separate Home Manager flake would replace the user's `home-manager` profile generation. | Clear if the app writes only a new export and the user owns the import site and lock file. | Clear per adapter. Oh My Theme owns managed fragments and receipts; user files stay user-owned. |
| File ownership | Home Manager commonly replaces target paths with links into a generation. `force` can delete existing targets. | The generated module can show exactly which paths it will claim before the user imports it. | The app can prefer a target-supported include and own only the included artifact. |
| Activation | Nix realizes store objects and changes profiles. Home Manager or nix-darwin then runs activation scripts. Live application behavior remains target-specific. | Activation happens when the user runs their normal rebuild. It is declarative but not a one-click switch from Oh My Theme. | The app calls each target's documented API, extension, AppleScript command, or reload action and reports current-process reach. |
| Rollback | Profile rollback is strong for generated links and packages. Imperative hooks and application state may not reverse exactly. | The user can revert the source change or select an older generation. The same limitation applies to side effects. | Receipts capture the exact prior target state. Rollback can be scoped to one apply transaction and refuse stale writes. |
| Immutable files | Store content is outside ordinary user mutation. Home paths often point to it. Applications that rewrite their own config may fail or replace the link. | Users can inspect this behavior before import and choose modules or paths that do not conflict. | Generated fragments remain ordinary user-writable files. The app protects them with hashes and atomic replacement rather than filesystem immutability. |
| Permissions | User Home Manager activation runs as the user, but store operations go through the daemon. nix-darwin activation requires root. A GUI would need a separate, carefully designed authorization path for root work. | Export needs only access to a user-selected destination. The later rebuild uses the user's existing permissions and command. | Direct distribution can stay within the logged-in user's permissions. macOS Automation remains an explicit per-capability grant. |
| Network behavior | A cold flake evaluation may fetch inputs and substitutes. Builds may download or compile missing paths. Lock-file and registry behavior must be constrained. | Export is local. The user's normal Nix workflow decides when network access and input updates occur. | Theme switching can remain local after app and theme-pack installation. |
| Latency | Includes process launch, evaluation, realization, possible downloads or builds, profile update, and activation. Warm-cache latency still includes evaluation and activation. | No latency on the theme picker because export and activation are separate user actions. | Fits an interactive apply flow. Each adapter can stage work, then perform only the required writes and activation calls. |
| Failure reporting | Nix reports build and activation output, but Oh My Theme would still need to translate shell output into per-target capability outcomes. | The user's rebuild owns diagnostics. Oh My Theme can validate only the generated syntax and schema before export. | Adapters already produce typed plans, receipts, and capability outcomes. |
| Rollout risk | Highest. It combines Nix installation variance, user flake variance, privileges, and target activation gaps. | Moderate and contained. Bad output affects only users who review and import it. | Lowest for the MVP because it keeps the dependency and ownership model narrow. |

## Ownership and conflict rules

### Why an app-managed Home Manager flake is unsafe for an existing Home Manager user

Home Manager does not add a theme sub-profile under the user's current configuration. Its command sets the user's `home-manager` profile to the newly built generation. The generation includes the complete evaluated home configuration known to that invocation. Activation then cleans old-generation links that are absent from the new generation. [Home Manager command source](https://github.com/nix-community/home-manager/blob/master/home-manager/home-manager), [Home Manager generation linking](https://github.com/nix-community/home-manager/blob/master/modules/files.nix)

An app-managed flake containing only theme files would therefore omit the user's shell, packages, services, and other managed files. Switching to it could remove links from the previous Home Manager generation. Switching back would require another whole-home activation. This is not isolation and should not ship.

The safe choices are:

1. generate a module that the user's existing Home Manager configuration imports;
2. ask the user to expose a dedicated output or command from that same configuration;
3. do not involve Home Manager for that target.

Oh My Theme must never have two active writers for one artifact. If a target path is already a symlink into `/nix/store` or a Home Manager generation, the direct adapter should report `managed by Nix` and stop. It should offer declarative export, not replace the link.

### Immutable store files are both protection and friction

Store-backed content is stable because ordinary applications do not own it. Home Manager's generated target is commonly a symlink to that content. This works for programs that only read configuration. It is troublesome for programs that save settings back to the same path.

A program may respond in one of several ways: fail because the referent is not writable, unlink and replace the symlink, or save state elsewhere. The generic Nix and Home Manager sources cannot establish which behavior a particular macOS app uses. Every target needs a runtime proof before Oh My Theme labels a Nix-managed configuration compatible.

This differs from the native adapter design. Oh My Theme can own an ordinary generated fragment, write it atomically, and let a target-supported include connect it to a user file. The fragment is mutable, but hashes, stale-state checks, and receipts protect it from accidental overwrite.

### Generated configuration needs a narrow ownership contract

A later export should contain:

- the Oh My Theme pack ID, variant ID, source revision, and content digest;
- the exporter schema and compiler versions;
- generated target settings or a Stylix-compatible color mapping;
- explicit target enable flags rather than relying on Stylix auto-enable;
- a list of paths and settings the module will manage;
- comments identifying generated sections and the regeneration command;
- no secrets, host identity, username, home path, or unpinned remote asset URL.

The app should write a new file only. If the destination exists and its digest differs from the last export, stop and show a conflict. Do not patch `flake.nix`, `home.nix`, `configuration.nix`, or `flake.lock`.

## Activation and rollback boundaries

### What generations do guarantee

Nix profiles retain named generations and atomically move a profile pointer to a selected generation. Home Manager and nix-darwin build on that mechanism. [Nix profiles](https://nix.dev/manual/nix/latest/package-management/profiles)

For a file represented by a Home Manager link, selecting and activating an older generation normally restores the older link target. Home Manager also avoids deleting a path that no longer looks like one of its managed generation links. [Home Manager file activation source](https://github.com/nix-community/home-manager/blob/master/modules/files.nix)

### What generations do not guarantee

Activation scripts can call arbitrary commands after the write boundary. They are required to be idempotent, but the framework does not require a generated inverse for every command. [Home Manager activation option source](https://github.com/nix-community/home-manager/blob/master/modules/home-environment.nix)

nix-darwin similarly runs an activation program after selecting a generation. Some options persist when removed and need manual cleanup, as documented for `AppleInterfaceStyle`. [nix-darwin `darwin-rebuild`](https://github.com/nix-darwin/nix-darwin/blob/master/pkgs/nix-tools/darwin-rebuild.sh), [nix-darwin appearance option](https://nix-darwin.github.io/nix-darwin/manual/index.html#opt-system.defaults.NSGlobalDomain.AppleInterfaceStyle)

A file rollback also says nothing about a running process. An application may retain the new theme in memory, require a reload, apply it only to new windows, or persist a separate active-theme setting. Stylix target support should not be presented as proof of current-process rollback.

If Nix owns a target, Oh My Theme should delegate rollback to the same Nix configuration and label the result `generation activated`. It should separately verify visible target state where a supported query exists. It must not run its native receipt rollback over Nix-owned files.

## Permissions and security

### User-scoped Nix and Home Manager

An unprivileged Nix client can ask the privileged daemon to realize store paths when daemon policy allows that user. Only root and configured trusted users can make some high-trust choices, including arbitrary binary-cache choices. [Nix multi-user mode](https://nix.dev/manual/nix/latest/installation/multi-user)

Home Manager's activation script checks that `USER`, `HOME`, and, when configured, the UID match the evaluated configuration. It writes home files as that user and gives activation a controlled tool path rather than depending on an arbitrary shell `PATH`. [Home Manager activation source](https://github.com/nix-community/home-manager/blob/master/modules/home-environment.nix)

A macOS GUI process should locate an explicitly configured Nix executable rather than assume an interactive shell path. It should pass a fixed environment, capture stdout and stderr separately, impose a timeout, support cancellation before activation, and never interpolate a theme name into a shell command. These are application requirements inferred from the command-based boundary; the Nix projects do not provide a macOS GUI API.

### System-scoped nix-darwin

Current nix-darwin requires root for system activation and rollback. Calling `sudo` from a menu-bar process is not an acceptable authorization design. There may be no terminal for a password prompt, and broad passwordless sudo would exceed the feature's needs. [nix-darwin `darwin-rebuild` source](https://github.com/nix-darwin/nix-darwin/blob/master/pkgs/nix-tools/darwin-rebuild.sh)

If a future release truly needs nix-darwin activation, use a separately reviewed privileged-helper design or require the user to run the command themselves. Do not add that machinery for theme switching. Stylix itself says its nix-darwin module does not theme macOS, so the privilege cost buys little for this app. [Stylix nix-darwin installation](https://nix-community.github.io/stylix/installation.html#nix-darwin)

### Flake mutation and network control

An app must not update a user's lock file as a side effect of choosing a theme. nix-darwin's command exposes `--no-update-lock-file`, `--no-write-lock-file`, `--offline`, and input override controls, which shows that evaluation can otherwise involve lock and network policy. [nix-darwin `darwin-rebuild` source](https://github.com/nix-darwin/nix-darwin/blob/master/pkgs/nix-tools/darwin-rebuild.sh)

For any later invocation mode:

- require a locked local flake selected by the user;
- pass `--no-write-lock-file` and do not override inputs;
- default to offline activation after a successful prebuild;
- show required downloads during preparation, not after the user confirms apply;
- reject flake-provided configuration prompts that have not been approved during setup;
- record the exact flake reference, output, lock digest, and realized generation in the receipt.

The exact safe flag set varies across supported Nix versions and remains an implementation proof, not a settled interface.

## Latency

No primary source supplies representative macOS timing for Home Manager plus Stylix theme switches, and this research did not benchmark them. Numeric latency claims would be invented.

The command path is still clear. A switch may perform flake lookup, evaluation, store realization, substitute downloads or local builds, profile mutation, Home Manager linking, and target-specific activation hooks. A warm store removes downloads and most builds, but not evaluation and activation. [Home Manager switch implementation](https://github.com/nix-community/home-manager/blob/master/home-manager/home-manager)

That path is acceptable for workstation provisioning. It is a poor default for a menu-bar interaction whose core claim is that one choice changes the current workspace and promptly reports what did not change.

Before any opt-in invocation mode ships, measure at least:

- warm evaluation with no configuration change;
- warm switch between two already-realized variants;
- cold switch with missing substitutes;
- offline failure;
- a target collision before `writeBoundary`;
- activation failure after the profile pointer changes;
- cancellation during build and during activation;
- several running instances of each promised target.

Preparation and realization can run before confirmation. Activation cannot. The UI must never call a long Nix switch on its main actor.

## Licenses

| Project | Repository license | Consequence for Oh My Theme |
| --- | --- | --- |
| Nix | GNU Lesser General Public License 2.1 in the repository `COPYING` file. [Nix license](https://github.com/NixOS/nix/blob/master/COPYING) | Running the user's Nix executable as a separate process does not copy Nix code into the app. Bundling, linking, or adapting Nix source would require a separate LGPL compliance review. |
| Home Manager | MIT. [Home Manager license](https://github.com/nix-community/home-manager/blob/master/LICENSE) | Original generated modules can target Home Manager without copying its implementation. Copied source or substantial templates must retain the MIT notice. |
| nix-darwin | MIT. [nix-darwin license](https://github.com/nix-darwin/nix-darwin/blob/master/LICENSE) | The same distinction applies. Invoking a user-installed command is different from shipping modified nix-darwin code. |
| Stylix | MIT. [Stylix license](https://github.com/nix-community/stylix/blob/master/LICENSE) | An exporter can produce compatible configuration. Copying target modules, templates, or palette-generation code requires preserving the MIT notice. |

These project licenses do not license the inputs they process. Theme schemes, wallpapers, fonts, icon sets, editor themes, and packages retain their own copyrights and licenses. Stylix compatibility does not grant redistribution rights to an asset. Oh My Theme must continue recording each theme pack's source revision, attribution, and asset license independently.

This section records repository license texts and engineering consequences. It is not legal advice.

## Decision by option

### Option A: invoke Nix as the primary apply engine

Decision: reject for the MVP.

It gives strong generation mechanics but weakens the actual product promise. It adds an installation dependency, daemon policy, possible network work, evaluation latency, shell-command integration, and target-specific activation gaps. nix-darwin adds root activation while Stylix says it cannot theme macOS itself. A private app-managed Home Manager configuration also conflicts with the user's existing `home-manager` profile.

This option is viable later only as Nix-owned mode. Nix must be the sole writer for every target in that mode.

### Option B: generate Nix configuration for existing users

Decision: pursue after the MVP.

This reaches Nix users without taking over their machine. Exporting a module is deterministic and testable. The user sees the ownership boundary in source control and activates it through an existing workflow. It also avoids pretending that a Nix rebuild is an interactive app API.

Start with a data export and a small Home Manager module. Add Stylix compatibility only after documenting the semantic-role to Base16 mapping and testing the exact target modules on macOS. Explicitly disable unsupported or unverified targets in generated Stylix configuration.

### Option C: borrow the design

Decision: use for the MVP.

The current architecture already has the right shape. Make prepared adapter plans immutable and content-addressed. Split checks from writes. Keep activation ordered and idempotent. Retain bounded generations of managed artifacts and receipts. Refuse stale rollback. Preserve target-specific activation and verification rather than assuming file installation equals support.

Do not copy Nix's filesystem mechanism literally. A macOS theme app often needs writable generated fragments and application-owned settings APIs. The useful lesson is explicit ownership and reproducible output, not that every target file should be a symlink into an immutable store.

## Proposed path

### MVP

1. Keep native macOS, Ghostty, and VS Code adapters.
2. Detect Nix-owned target paths by resolving symlinks and recognizing `/nix/store` and Home Manager generation targets.
3. Report those paths as conflicts with the message `managed by Nix`.
4. Do not install Nix, call Nix commands, write Nix configuration, or offer nix-darwin activation.
5. Apply Nix-inspired generation IDs and content digests to Oh My Theme's own managed artifacts and receipts.

### First post-MVP release

1. Add `Export for Home Manager` to a user-selected new directory.
2. Export the canonical theme data, generated target fragments, a module, a README with the one required import, and source/license metadata.
3. Never alter an existing Nix file or lock file.
4. Validate exports in CI against pinned supported Home Manager and Nixpkgs releases on both `aarch64-darwin` and `x86_64-darwin`.
5. Treat activation as external. The app reports `exported`, not `applied`.

### Later experimental release

1. Add Stylix export after the Base16 mapping and target behavior are tested.
2. Let advanced users register one exact user-owned flake output and activation command.
3. Prebuild both variants and measure warm-switch latency before exposing a switch button.
4. Disable direct adapters for every Nix-owned target.
5. Delegate generation rollback to Home Manager, then verify each running target separately.
6. Keep nix-darwin activation outside the app unless a future macOS capability justifies a reviewed privileged helper.

## Open gaps

The following claims need prototypes or narrower source review before implementation:

- whether each relevant Stylix target on macOS links an immutable file, merges settings through a Home Manager program module, or runs an activation hook;
- whether Stylix's Ghostty target reloads existing Ghostty windows;
- whether Stylix's VS Code target changes the effective theme for the active profile and all current windows;
- how Nix daemon socket access behaves in the exact signed, Hardened Runtime build and in any future App Sandbox build;
- which Nix executable locations and versions should count as supported across official, Determinate, and Lix installations;
- the safe cross-version flake flags for a noninteractive GUI caller;
- measured warm and cold latency on supported Intel and Apple Silicon Macs;
- recovery behavior when Home Manager or nix-darwin activation fails after selecting a new profile generation;
- whether a target application preserves, replaces, or rejects each specific Home Manager-managed symlink.

Until those gaps close, Nix integration should remain an export format, not an apply backend.
