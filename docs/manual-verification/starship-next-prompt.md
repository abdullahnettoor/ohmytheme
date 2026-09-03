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
- Notes: Two `starship prompt` invocations ran in the same shell with one palette edit between them. The first emitted red `38;2;255;0;0` bytes; the second emitted blue `38;2;0;0;255` bytes. The already-emitted first prompt bytes did not change.
