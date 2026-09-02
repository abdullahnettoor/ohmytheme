# Starship format-preserving theme proof

Research cutoff: 2026-09-02. This record addresses [issue #7](https://github.com/abdullahnettoor/ohmytheme/issues/7) using Starship's official configuration documentation and the official Catppuccin Starship port.

## Finding

Starship reads a TOML configuration file and supports named `[palettes.<name>]`
tables. A prompt can select a palette with the top-level `palette` key, and
style strings can refer to palette names. The supported mutation boundary is
therefore:

- the registered palette table owned by Oh My Theme; and
- the top-level `palette` key when the selected variant uses that palette.

The adapter must not rewrite the whole file, normalize unrelated TOML, or
assume that every module uses palette references. Modules with hard-coded
colors remain unchanged.

Evidence: [Starship configuration](https://starship.rs/config/),
[Starship palettes](https://starship.rs/advanced-config/#style-strings), and
the [official Catppuccin Starship port](https://github.com/catppuccin/starship).

## Required proof cases

Representative fixtures need comments, unusual spacing, an existing palette,
unrelated settings, and a malformed or ambiguous ownership shape. The proof
should parse first, reject malformed TOML before writing, and compare the
candidate against the original bytes before the replacement boundary.

The rollback receipt should retain the exact original bytes plus a digest of
the managed state. Restore is safe only when the managed state still matches
the post-apply digest; an external edit must produce a conflict rather than
overwrite the user's file.

No supported include seam was established in the reviewed Starship
documentation. A TOML-aware parser and a narrow table/key mutation are safer
than line-oriented replacement, but this remains an implementation proof, not
a reason to add a general-purpose configuration manager.

## Activation reach and product boundary

Saving the configuration reaches the next prompt through Starship's normal
configuration lookup. It does not redraw an already-rendered prompt, and it
does not guarantee that hard-coded module colors change. The strongest
justified status is **automatic for the next prompt**, subject to successful
parse, ownership, and conflict checks.

This issue remains research-only in the current pass: no Starship adapter or
shell execution was added.
