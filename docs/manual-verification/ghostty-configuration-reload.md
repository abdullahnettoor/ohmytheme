# Ghostty configuration and reload proof

This record covers [issue #4](https://github.com/abdullahnettoor/ohmytheme/issues/4) and the live qualification required by [issue #23](https://github.com/abdullahnettoor/ohmytheme/issues/23). It separates the dated disposable configuration proof from the pending app-level reload check.

## Disposable proof

Run:

```bash
./Scripts/prove-ghostty.sh
```

The script requires a locally installed Ghostty. It creates a temporary HOME and XDG configuration tree, then removes it when the script exits. It does not read, modify, or install the user's Ghostty configuration.

This proof supports Ghostty 1.3.x. It uses the 1.3.0 `config.ghostty` transition as the source-reviewed floor and has an executable proof run on 1.3.1 stable. The script rejects other versions until their discovery behavior is reviewed and added to this record.

The proof checks that the installed Ghostty:

- prefers the modern `config.ghostty` name over the legacy `config` name in an XDG configuration directory;
- loads a reviewed `config-file = ?oh-my-theme/config.ghostty` include after the parent file;
- preserves the parent's unrelated settings while the included fragment overrides its color;
- accepts the complete parent and fragment through `ghostty +validate-config --config-file=...`;
- rejects an invalid staged configuration through that same command; and
- does not change the reviewed parent while resolving or validating the include.

The version history and full candidate-path rules are recorded in [the Ghostty research record](../research/ghostty-configuration-reload-proof.md). A production adapter must inspect every candidate appropriate to the installed Ghostty version before proposing the one user-owned parent file that will receive an include.

## Activation reach

Ghostty documents `cmd+shift+,` as its `reload_config` action. Oh My Theme does not send that action. Connection, Apply, Undo, Restore, and Disconnect must report `Reload required` and tell the user to press `cmd+shift+,` in Ghostty.

| Configuration | Reported reach | Required user action |
| --- | --- | --- |
| Managed include, fragment, or theme bytes changed | `Reload required` | Focus Ghostty and press `cmd+shift+,` |
| Managed bytes already selected | `Reload required` | Press `cmd+shift+,` if running windows have not loaded those bytes |

The reach claim covers the saved configuration only. A live pass requires the generated color settings to repaint existing windows after the documented reload. It does not claim that arbitrary Ghostty settings reload or that Oh My Theme automated the keyboard action.

## Live app qualification

Use a fresh local test account with a synthetic Ghostty 1.3.x configuration. Do not record its path or contents.

1. Open two Ghostty windows and keep both visible.
2. In Oh My Theme, select `Review connection` for Ghostty. Confirm the review names one managed include, one managed fragment, `Ghostty: configuration reload required`, and `Press cmd+shift+,`.
3. Select `Approve and connect`. Confirm the connection report shows `Connection`, `Updated` or `Already set`, and `Reload required`.
4. Press `cmd+shift+,` in one Ghostty window. Confirm both existing windows remain usable.
5. Select `Oh My Theme Aurora`, then `Preview workspace change`, then `Apply to ready Targets`.
6. Confirm the Ghostty report shows `Theme`, `Updated`, `Reload required`, and `Undo available`. Its detail must say `Ghostty theme updated; reload required with cmd+shift+,`.
7. Before reloading, confirm the existing windows still show their prior colors.
8. Focus Ghostty and press `cmd+shift+,`. Confirm both existing windows repaint to Aurora without quitting Ghostty or opening a new terminal.
9. Apply Catppuccin Mocha. Confirm the same report fields, then press `cmd+shift+,` and confirm both windows repaint again.
10. Select `Undo Last Theme Change`. Confirm Ghostty says `Restored` and `Reload required`. Press `cmd+shift+,` and confirm the prior colors return.
11. Complete the Ghostty Restore and Disconnect and conflict cases in [`workspace-theme-apply.md`](workspace-theme-apply.md).

If colors appear only in new terminals after `cmd+shift+,`, or the report claims `Current windows` before the user reloads, mark the live check failed and narrow or remove Ghostty support.

## Record

| Date | Ghostty | Result |
| --- | --- | --- |
| 2026-09-02 | 1.3.0 | Source-reviewed floor. The version-tagged Ghostty source establishes the `config.ghostty` transition, include handling, validator, and AppleScript availability. |
| 2026-09-02 | 1.3.1 stable | Pass. The disposable proof confirmed modern-name discovery, managed-fragment precedence, valid staged configuration, invalid configuration rejection, and preservation of the parent file. No user configuration or live Ghostty window was changed. |
| Pending | Pending | Live app connection, Apply, `cmd+shift+,` reload, Undo, Restore and Disconnect, and external-edit conflict. |
