# Ghostty configuration and reload proof

This record covers [issue #4](https://github.com/abdullahnettoor/ohmytheme/issues/4). It distinguishes the disposable configuration proof from the live activation behavior that a production adapter must report.

## Disposable proof

Run:

```bash
./Scripts/prove-ghostty.sh
```

The script requires a locally installed Ghostty. It creates a temporary HOME and XDG configuration tree, then removes it when the script exits. It does not read, modify, or install the user's Ghostty configuration.

The proof checks that the installed Ghostty:

- prefers the modern `config.ghostty` name over the legacy `config` name in an XDG configuration directory;
- loads a reviewed `config-file = ?oh-my-theme/config.ghostty` include after the parent file;
- preserves the parent's unrelated settings while the included fragment overrides its color;
- accepts the complete parent and fragment through `ghostty +validate-config --config-file=...`;
- rejects an invalid staged configuration through that same command; and
- does not change the reviewed parent while resolving or validating the include.

The version history and full candidate-path rules are recorded in [the Ghostty research record](../research/ghostty-configuration-reload-proof.md). A production adapter must inspect every candidate appropriate to the installed Ghostty version before proposing the one user-owned parent file that will receive an include.

## Activation reach

Ghostty documents `cmd+shift+,` as an explicit `reload_config` action. The current proof therefore records the production adapter's conservative result as:

| Configuration | Running instances | User action |
| --- | --- | --- |
| Updated after the user approves one parent include | Reload required | Press `cmd+shift+,` in Ghostty |

Ghostty's documented action is app scoped, but some settings are non-reloadable or affect only new terminals. The generated fragment must consequently contain only documented reloadable color settings before the production adapter can report a stronger result. The proof does not claim that every existing window repaints after any arbitrary configuration change.

Ghostty 1.3.0 added a documented AppleScript action interface, but this proof does not use it. Automating a reload would require macOS Automation consent and a live application, so it belongs in the production adapter's explicit setup and verification flow.

## Record

| Date | Ghostty | Result |
| --- | --- | --- |
| 2026-09-02 | 1.3.1 stable | Pass. The disposable proof confirmed modern-name discovery, managed-fragment precedence, valid staged configuration, invalid configuration rejection, and preservation of the parent file. No user configuration or live Ghostty window was changed. |
