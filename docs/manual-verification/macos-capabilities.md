# macOS capability proofs

These steps cover [issue #5](https://github.com/abdullahnettoor/ohmytheme/issues/5)
and [issue #6](https://github.com/abdullahnettoor/ohmytheme/issues/6). The
automated proof uses injectable seams; these checks exercise the public macOS
interfaces on the developer's actual machine.

## Static wallpaper

1. Connect at least two displays if available and note the current image and
   placement on each display.
2. Start the locally signed app and enumerate the connected displays through
   `SystemWallpaperPlatform`.
3. Select exactly one display and apply a local static image.
4. Confirm the selected display changes and the unselected display does not.
5. Restore the captured receipt and confirm the selected display returns to its
   prior image and placement.
6. Repeat with another display arrangement and with separate Spaces if the
   machine exposes them.

The proof uses `NSWorkspace.desktopImageURL(for:)`,
`desktopImageOptions(for:)`, and `setDesktopImageURL(_:for:options:)` only.
The receipt preserves the image URL and the documented scaling, clipping, and
fill-color options. macOS may omit or ignore a placement option, especially
fill color on newer releases; that result must be reported rather than
presented as exact restoration.

This does not establish dynamic wallpaper, collection scheduling, or an
every-Space guarantee. The product promise remains static wallpaper on the
explicitly selected connected displays.

## System Light/Dark appearance

1. Open System Settings and record the current Light/Dark setting.
2. Run `MacOSAppearanceClient.read()` once. On a clean permission state,
   confirm macOS presents the Automation consent prompt.
3. Grant access, apply the opposite appearance, and confirm the verified
   result matches the requested state.
4. Restore the recorded snapshot and confirm the original state returns.
5. Revoke Automation access in System Settings and repeat the read/apply
   operation. Confirm the result is classified as permission-required.
6. If System Events is unavailable or the target reports an execution error,
   confirm that it is classified separately from permission failure and from
   an unchanged appearance.
7. Confirm the wallpaper capability still runs when appearance permission is
   unavailable.

The proof uses the documented System Events `appearance preferences` object's
writable `dark mode` property. It does not mutate accent color: AppKit exposes
`NSColor.controlAccentColor` as read-only for this purpose. Appearance
automation is optional and machine-wide; failure narrows the capability
outcome and does not block unrelated target capabilities.
