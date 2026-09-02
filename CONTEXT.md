# Oh My Theme

Oh My Theme synchronizes the visual theme of a macOS developer workspace. It translates one selected theme into supported settings for macOS and opted-in applications.

## Language

**Theme pack**:
A distributable, data-only theme with metadata, attribution, and one or more variants.
_Avoid_: Theme bundle, plugin

**Theme variant**:
A concrete light or dark expression of a theme pack, including semantic colors and optional wallpaper.
_Avoid_: Palette, mode

**Semantic role**:
A target-independent meaning assigned to a color, such as canvas background, primary text, selection, or ANSI red.
_Avoid_: Color slot, app color

**Upstream port**:
A target-specific expression of a theme maintained and distributed by the theme project or its recognized port maintainers.
_Avoid_: Generated theme, built-in theme

**Generated theme**:
A target-specific expression compiled by Oh My Theme from semantic roles when no selected upstream port applies.
_Avoid_: Upstream port, official port

**Theme source policy**:
A Workspace preference that chooses whether target instances prefer upstream ports, require upstream ports, or use generated themes.
_Avoid_: Theme assignment, fallback

**Theme catalog**:
The set of bundled and user-installed theme packs available for selection.
_Avoid_: Theme registry, marketplace

**Target catalog**:
The researched list of applications and macOS capabilities Oh My Theme may support. A catalog entry is not an adapter and does not imply that Oh My Theme can apply a theme to it.
_Avoid_: Supported apps, adapter registry

**Target**:
A kind of macOS setting or application that Oh My Theme knows how to prepare or apply.
_Avoid_: Integration, destination

**Target instance**:
A specific configuration context for a target, such as a VS Code profile, Obsidian vault, Terminal profile, or Neovim configuration.
_Avoid_: Target, application

**Connected target instance**:
A target instance whose one-time setup and ownership scope the user has reviewed and accepted, allowing later theme changes without repeated setup confirmation.
_Avoid_: Installed app, enabled adapter

**Adapter**:
The target-specific translator and applicator for one kind of target. It owns discovery, compatibility checks, managed configuration, activation, verification, and rollback.
_Avoid_: Plugin, connector

**Experimental adapter**:
An opt-in adapter that uses documented target mechanisms and the same ownership and recovery guarantees as a supported adapter, but has narrower compatibility evidence.
_Avoid_: Private hack, unsafe adapter

**Support tier**:
The strongest supported outcome Oh My Theme can reach for a target instance: applied, applied after one-time setup, reload required, next launch, or unavailable. Installing an asset without being able to activate it does not count as support.
_Avoid_: Compatibility level, install-only

**User action**:
A one-time setup, permission grant, reload, restart, or other explicit step that remains after Oh My Theme has done everything supported for a target instance. Repeated manual theme selection is not an acceptable user action for a supported adapter.
_Avoid_: Failure, workaround

**Activation reach**:
Whether an apply transaction updated current running instances, only future processes, or persisted configuration that still needs a reload.
_Avoid_: Support tier, global success

**Configuration owner**:
The tool or person currently responsible for producing a target instance's configuration. A managed artifact has one configuration owner at a time.
_Avoid_: File owner, adapter

**Managed artifact**:
A configuration file, setting, or system value that Oh My Theme created or explicitly took responsibility for changing.
_Avoid_: User config

**Connection baseline**:
The durably captured state of a target instance immediately before Oh My Theme first connects it. It is the reference for disconnecting the target and restoring the state that existed before Oh My Theme managed it.
_Avoid_: Backup, apply receipt

**Last apply transaction**:
The most recent completed apply transaction that changed at least one target instance. Its per-instance receipts are the reference for Undo Last Theme Change.
_Avoid_: Connection baseline, apply attempt

**Apply transaction**:
One attempt to apply a theme variant to a selected set of target instances, with a separate outcome and rollback receipt for each instance.
_Avoid_: Sync, deployment

**Capability outcome**:
The result for one independently applied capability within a target, such as macOS wallpaper, macOS appearance, or Ghostty reload.
_Avoid_: Step result, sub-target

**Apply report**:
The result of an apply transaction, grouped by target instance and capability. It records success, required permission, manual action, conflict, unsupported capability, failure, and rollback state without collapsing partial results into one global status.
_Avoid_: Global success

**Workspace**:
The user's selected set of target instances that should follow the same theme assignment.
_Avoid_: Profile, environment

**Theme assignment**:
The theme choice followed by a Workspace, either one fixed theme variant or a Light/Dark pair selected by system appearance.
_Avoid_: Active theme, schedule
