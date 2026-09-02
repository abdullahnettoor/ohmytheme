# Ghostty configuration and reload proof

Research cutoff: 2026-09-02. This record addresses [issue #4](https://github.com/abdullahnettoor/ohmytheme/issues/4) using Ghostty-owned documentation, version-tagged Ghostty source, and its documented CLI only.

## Findings

### Discovery, precedence, and a managed fragment

Ghostty's current configuration guide lists XDG `config.ghostty`, then XDG
`config`, followed on macOS by the equivalent Application Support files; later
conflicting values override earlier ones, and macOS files load after XDG
files. [Official configuration guide](https://ghostty.org/docs/config#file-location)

There is a version-boundary discrepancy worth preserving: the live guide calls
`config` the pre-1.2.3 name, but the tagged 1.2.3 source still loads only
`ghostty/config` and the tagged 1.3.0 source explicitly loads legacy
`config` before `config.ghostty`. [v1.2.3 discovery
source](https://github.com/ghostty-org/ghostty/blob/v1.2.3/src/config/Config.zig#L3376-L3422)
[v1.3.0 discovery source](https://github.com/ghostty-org/ghostty/blob/v1.3.0/src/config/Config.zig#L3982-L4025)
An adapter must therefore inspect all four macOS candidates and resolve
precedence in the installed version instead of assuming that one filename is
the effective configuration.

`config-file` is a repeatable, recursive include. Relative paths are resolved
against the including file, `?` makes an absent file optional, cycles become
diagnostics, and includes are processed after the rest of their parent file.
[Official include documentation](https://ghostty.org/docs/config#splitting-into-multiple-files)
[v1.3.0 implementation](https://github.com/ghostty-org/ghostty/blob/v1.3.0/src/config/Config.zig#L4148-L4246)
The supported ownership seam is consequently one reviewed parent line such as
`config-file = ?oh-my-theme/config.ghostty`, with Oh My Theme owning only that
relative fragment. The fragment overrides values in its containing parent, but
a subsequently loaded top-level configuration can still override it.

### Validate before replacing the fragment

Ghostty provides `ghostty +validate-config --config-file=/path/to/config`;
the command resolves the file, loads recursive `config-file` entries,
finalizes the configuration, prints diagnostics, and returns exit status 1
when diagnostics exist (0 otherwise). [v1.3.0 validator
source](https://github.com/ghostty-org/ghostty/blob/v1.3.0/src/cli/validate_config.zig#L8-L82)
Stage the candidate at a real path, validate the final include graph, and
replace the managed fragment only after a zero exit. The reviewed CLI source
offers path-based validation, not a documented stdin/in-memory or transactional
validate-and-install operation; atomic replacement and rollback are adapter
responsibilities.

The installed local stable binary reported **Ghostty 1.3.1**. The disposable
proof in [`Scripts/prove-ghostty.sh`](../../Scripts/prove-ghostty.sh) confirmed
that `config.ghostty` wins over the legacy `config` name in an isolated XDG
directory, a relative managed fragment overrides its parent, valid staged
configuration exits 0, and an unknown option exits nonzero. It does not test
the macOS Application Support fallback or alter a user configuration. [CLI
documented with configuration
reference](https://ghostty.org/docs/config#offline-reference-documentation)

### Reload and activation reach

Ghostty documents explicit reload via `cmd+shift+,` on macOS (or a binding for
`reload_config`) and warns that some settings cannot reload while others affect
only newly created terminals. [Official reload
documentation](https://ghostty.org/docs/config#reloading-the-configuration)
The upstream action model classifies `reload_config` as **app** scoped, and
the app's configuration-update path iterates every surface. [v1.3.0 action
scope](https://github.com/ghostty-org/ghostty/blob/v1.3.0/src/input/Binding.zig#L1274-L1297)
[v1.3.0 surface update](https://github.com/ghostty-org/ghostty/blob/v1.3.0/src/App.zig#L134-L141)

On macOS, AppleScript support begins in 1.3.0 and exposes `perform action` on
a terminal; nevertheless, the action source still makes `reload_config`
app-scoped. [Official AppleScript
documentation](https://ghostty.org/docs/features/applescript)
[v1.3.0 scripting definition](https://github.com/ghostty-org/ghostty/blob/v1.3.0/macos/Ghostty.sdef#L154-L158)
[v1.3.0 reload dispatch](https://github.com/ghostty-org/ghostty/blob/v1.3.0/src/App.zig#L435-L451)
The production adapter may promise "reload Ghostty configuration app-wide when
the setting is reloadable." It must not promise a current-window-only reload.

No live reload AppleScript was run: it could trigger macOS Automation consent
and alter the user's running application. No synthetic parent/fragment pair
was installed either. The current-window result is therefore source-backed
scope analysis, not a runtime observation; a packaged-binary proof remains
necessary before claiming live visual behavior for every existing window.

## Version evidence and proposed test floor

| Version | Evidence / status |
| --- | --- |
| 1.0.0 | Tagged source already contains repeatable `config-file` support and `+validate-config`; source evidence only. [Include](https://github.com/ghostty-org/ghostty/blob/v1.0.0/src/config/Config.zig#L1265-L1292) [validator](https://github.com/ghostty-org/ghostty/blob/v1.0.0/src/cli/validate_config.zig#L8-L70) |
| 1.2.3 | Test legacy `config` discovery when supporting this release; source evidence only. [Discovery](https://github.com/ghostty-org/ghostty/blob/v1.2.3/src/config/Config.zig#L3376-L3422) |
| 1.3.0 | Test the `config.ghostty` transition and AppleScript availability; source/documentation evidence only. [Filename transition](https://github.com/ghostty-org/ghostty/blob/v1.3.0/src/config/file_load.zig#L9-L121) [AppleScript version](https://ghostty.org/docs/features/applescript) |
| 1.3.1 stable | Locally tested for isolated XDG modern-name discovery, managed-fragment precedence, and valid and invalid `+validate-config` results. No Application Support fallback or live-reload test was performed. |

No formal Ghostty support/EOL window was located in the scoped first-party
sources. These are feature and test boundaries, not a claim that Ghostty
supports every listed release today.
