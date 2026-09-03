# Starship next-prompt verification

Use this check when changing the Starship adapter or its activation-reach reporting. Automated tests verify exact file mutations and reports, but they cannot prove how a locally installed Starship process reloads configuration.

## Preconditions

- Install a supported Starship release and record its version with `starship --version`.
- Use a disposable directory. Do not point this check at your normal Starship configuration.

## Procedure

1. Create a temporary `starship.toml` containing a top-level palette selection and a small named palette.
2. Set `STARSHIP_CONFIG` to the temporary file for the terminal used by this check.
3. Run `starship prompt` and save the rendered output.
4. Change one selected palette color in the temporary file without restarting the shell.
5. Observe the already-rendered prompt. It must remain unchanged.
6. Run `starship prompt` again in the same shell.
7. Confirm the new invocation uses the changed palette value.
8. Restore or delete the temporary file and unset `STARSHIP_CONFIG`.

## Live app qualification

Run this part in a fresh local test account with a synthetic Starship config. Do not record the file path, palette values, or unrelated prompt settings.

1. Connect Starship through `Review connection` and `Approve and connect`.
2. Confirm the connection report shows `Connection`, `Already set`, and `Next launch`. Connection must not edit the file.
3. Leave one rendered prompt visible.
4. In Oh My Theme, select Aurora, choose `Preview workspace change`, then `Apply to ready Targets`.
5. Confirm the Starship outcome shows `Theme`, `Updated`, `Next prompt`, and `Undo available`. Its detail must state that the next prompt uses the `oh-my-theme` palette and the existing prompt is not redrawn.
6. Confirm the visible prompt does not change.
7. Press Return once in the same shell. Confirm the new prompt uses Aurora without a shell restart.
8. Apply Catppuccin Mocha. Confirm the same report fields and verify the next prompt changes while older prompts remain unchanged.
9. Select `Undo Last Theme Change`. Confirm Starship says `Restored` and `Next prompt`, then verify the next prompt returns to the prior theme.
10. Compare the synthetic config against the private pre-run copy. Only the registered palette keys and selected palette may differ.
11. Complete the Starship Restore and Disconnect and external-edit cases in [`workspace-theme-apply.md`](workspace-theme-apply.md).

## Expected result

- Saving the file does not redraw an existing prompt.
- The next Starship invocation in the current shell reads the updated configuration.
- No shell restart, process termination, private preference write, or GUI automation is required.
- Oh My Theme may report this behavior as `nextPrompt`; it must not report that an existing prompt was redrawn.

## Record

- Date: 2026-09-03
- macOS version: 26.5.2
- Starship version: 1.24.0 (Homebrew)
- Result: Pass
- Notes: Two `starship prompt` invocations ran in the same shell with one palette edit between them. The first and second invocations emitted different expected color bytes. The already-emitted first prompt bytes did not change. Raw configuration values are omitted from this record.

### Live app record

- Date: Pending
- Oh My Theme build: Pending
- macOS version: Pending
- Starship version: Pending
- Result: Pending
