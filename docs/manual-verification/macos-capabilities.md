# macOS capability proofs

These steps cover [issue #5](https://github.com/abdullahnettoor/ohmytheme/issues/5),
[issue #6](https://github.com/abdullahnettoor/ohmytheme/issues/6),
[issue #17](https://github.com/abdullahnettoor/ohmytheme/issues/17), and
[issue #18](https://github.com/abdullahnettoor/ohmytheme/issues/18). The
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

## Bundled demo display and Space check

Both bundled Theme Variants, Catppuccin Mocha and Oh My Theme Aurora, contain no wallpaper. The issue #23 live run must therefore prove discovery and non-mutation, not a bundled wallpaper switch.

1. Before launching Oh My Theme, count the connected displays. On each display, visit every available desktop Space and full-screen Space. Record only neutral labels such as `display A, Space 1`; do not record wallpaper URLs.
2. Open Oh My Theme and confirm the macOS row reports the same display count and says wallpaper stays unchanged.
3. Connect System Appearance, Ghostty, VS Code, and Starship as available.
4. Preview and apply Aurora, then Catppuccin Mocha, then Aurora again.
5. Revisit every observed Space on every display. Confirm no wallpaper or placement changed.
6. Disconnect and reconnect a display if the machine permits it, reopen the menu, and confirm the discovered count updates without a wallpaper mutation.
7. Record the limitation exactly: the public interface can enumerate connected displays, but it cannot enumerate every Space. A static wallpaper apply can claim the selected connected displays and the active Space behavior observed from macOS. It cannot claim every Space, dynamic wallpaper, or scheduled collections.

| Date | Displays | Spaces observed | Result |
| --- | --- | --- | --- |
| Pending | Pending | Pending | Pending |

## Static wallpaper adapter switch and restore (issue #17)

1. Note the wallpaper URL and placement on each connected display.
2. Discover displays through `MacOSWallpaperAdapter.discover()` and confirm every
   connected display is present with its current image and placement.
3. Connect exactly one display and confirm nothing changes on the desktop; the
   returned `ConnectionReceipt` should be `.unchanged` with reach
   `.currentInstances`.
4. For an adapter-only wallpaper qualification, prepare a local test Theme Variant whose `wallpaper.contentDigest` matches its on-disk test asset. Neither bundled Theme Variant contains a wallpaper. The selected display should switch to the test asset and preserve the display's prior scaling, clipping, and fill color; the other display should not change.
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

## System appearance adapter and clean-permission checklist (issue #18)

1. Reset the app's Automation decision with
   `tccutil reset AppleEvents <app-bundle-id>`, replacing `<app-bundle-id>` with
   the locally signed app's bundle identifier.
2. Launch Oh My Theme and confirm discovery reports the System Appearance Target and shows `Automation access to System Events is required to read and change the system Light/Dark appearance.` Discovery must not present a prompt or contact System Events.
3. Select `Review connection`. Preparing the review performs the first appearance read, so macOS should present the Automation prompt now.
4. Grant access. Confirm the completed review says it will record the current Light/Dark value. Select `Approve and connect`, then confirm connection records that value as the Connection Baseline, changes no setting, and reports that Automation access is available.
5. Apply a Theme Variant with the opposite `appearance`. Confirm the system
   switches to Light or Dark, the Capability Outcome is `updated`, and no accent
   color changes.
6. Apply a Theme Variant matching the current appearance. Confirm the Capability
   Outcome is `unchanged` and no setter is sent.
7. Reset the permission again and select `Review connection`. Deny the prompt. Confirm review preparation stops, the row remains unconnected, and the visible operation error identifies the denied permission. No Connection Report is created because no reviewed plan reached `Approve and connect`.
8. Grant and connect, then revoke System Events access in System Settings before
   preview/apply. Confirm the appearance Capability Outcome is
   `permissionRequired` with revocation guidance. In the same Workspace, confirm
   wallpaper and developer-application Target Instances continue independently.
9. With System Events unavailable, confirm the appearance Capability Outcome is
   `unavailable`. For another AppleScript execution error, confirm it is
   `failed`; neither result should be presented as permission denial or
   `unchanged`.
10. After a successful switch, invoke Undo and confirm the exact pre-apply
    Light/Dark value returns. Repeat after manually changing appearance away from
    the intended value and confirm guarded Undo refuses with
    `restorationConflict`.
11. Simulate receipt loss after the setter succeeds, restart, and confirm
    reconciliation classifies the intended appearance and reconstructs a receipt
    that can still Undo.
12. Attempt disconnect before Undo and confirm it refuses. After Undo restores
    the Connection Baseline, confirm disconnect is a no-op and removes no other
    system setting.

### Clean-permission partial Workspace report

Use the exact app route below after System Appearance, Ghostty, VS Code, and Starship are connected.

1. Run `/usr/bin/tccutil reset AppleEvents com.ohmytheme.OhMyTheme`.
2. Select Aurora and choose `Preview workspace change`.
3. Deny the macOS prompt to control System Events.
4. Confirm the preview keeps independent Target plans and identifies the Appearance permission need.
5. Choose `Apply to ready Targets`.
6. Confirm the title is `Theme applied with remaining work` when at least one other Target updates.
7. Confirm System Appearance shows `Appearance`, `Permission required`, no reach line, and `No rollback needed`.
8. Confirm independent ready Targets keep their successful outcomes and are not rolled back because Automation was denied.
9. Grant Automation in System Settings before later full-Workspace checks and prepare a new preview.

A denial reported as `Already set`, `Failed`, or `Current windows` is a qualification failure.

### Documented limits

- The Target Instance is the single machine-wide System Appearance setting,
  identified as `macos.appearance:system`.
- Discovery is intentionally read-free so the product can explain Automation
  before macOS asks. Connection performs the first System Events read and may
  therefore present the consent prompt.
- macOS reports both an initial denial and later revocation with Apple event
  error `-1743`. Oh My Theme distinguishes them by lifecycle context: denial
  while connecting and revocation for an already connected appearance Target
  Instance.
- Light/Dark state is binary and exposes no supported revision token. If another
  actor independently reaches the exact intended value between preview and
  apply, the operation is treated as an idempotent `unchanged` result.
- The only mutation route is System Events' `dark mode of appearance
  preferences`. Accent color and undocumented preference keys are outside this
  adapter's ownership scope.
