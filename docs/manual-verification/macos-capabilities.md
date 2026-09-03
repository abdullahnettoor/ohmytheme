# macOS capability proofs

These steps cover [issue #5](https://github.com/abdullahnettoor/ohmytheme/issues/5),
[issue #6](https://github.com/abdullahnettoor/ohmytheme/issues/6), and
[issue #17](https://github.com/abdullahnettoor/ohmytheme/issues/17). The
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

## Static wallpaper adapter switch and restore (issue #17)

1. Note the wallpaper URL and placement on each connected display.
2. Discover displays through `MacOSWallpaperAdapter.discover()` and confirm every
   connected display is present with its current image and placement.
3. Connect exactly one display and confirm nothing changes on the desktop; the
   returned `ConnectionReceipt` should be `.unchanged` with reach
   `.currentInstances`.
4. Prepare and apply a Theme Variant whose `wallpaper.contentDigest` matches the
   on-disk asset. The selected display should switch to the bundled asset and
   preserve the display's prior scaling, clipping, and fill color; the other
   display should not change.
5. Change the selected display's wallpaper manually in System Settings, then
   invoke Undo. Undo must refuse (the adapter surfaces
   `MacOSWallpaperAdapterError.restorationConflict`) rather than overwrite the
   user's change.
6. Restore the display's original wallpaper, then invoke Undo again. The
   selected display should return to its recorded baseline image and placement.
7. Repeat with two displays connected and only one included in the Workspace to
   confirm the excluded display is never touched (the Keep My Current Wallpaper
   path).
8. Repeat with the machine's available Spaces to record any cases where a per
   Space wallpaper cannot be guaranteed; those cases are documented as adapter
   limits, not overridden.

The adapter reaches macOS only through the `WallpaperPlatform` protocol backed
by `SystemWallpaperPlatform` (which calls `NSWorkspace`). It never writes
preferences directly, never invokes GUI automation, and never touches accent
color.

### Documented limits

- The Activation Reach for the wallpaper capability is `.currentInstances`: the
  change lands on the display's active Space. `NSWorkspace` does not expose a
  supported way to enumerate every Space, so `oh-my-theme` does not promise to
  update inactive Spaces on the same display.
- The adapter reports the actual per-display configuration state. It does not
  attempt dynamic wallpaper or scheduled collections; those are out of scope for
  the vertical demo.
- `disconnect` requires the display to already sit on its recorded baseline
  (typically reached by running Undo). Disconnecting a display whose wallpaper
  no longer matches the baseline fails with `restorationConflict` instead of
  silently overwriting an unowned change.

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
