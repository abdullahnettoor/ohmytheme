# Oh My Theme MVP platform feasibility

Research date: 2026-08-31

## Scope and source standard

This note assesses a native macOS menu-bar app that applies one semantic theme across macOS, Ghostty, and Visual Studio Code. It uses Apple, Ghostty, and Microsoft documentation and first-party schemas. Techniques are classified as:

- **Public API:** documented framework or extension API intended for third-party software.
- **Supported automation or configuration:** a documented command, scripting dictionary, settings file, CLI option, or app-owned configuration format.
- **Unsupported:** a private preference key, private framework, reverse-engineered database, simulated UI, or undocumented process signal.
- **Unresolved:** a point that still needs a small runtime proof or first-party source inspection before it can support a product promise.

## Executive decision

The product is feasible if "one theme" means one semantic palette compiled into supported settings for each target. It is not feasible as a fully uniform, permission-free, App-Store-safe switch for every macOS appearance setting.

The decisive constraints are:

1. A SwiftUI menu-bar-only app is straightforward with [`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra). A menu-bar-only app is terminated when the user removes its extra, so the app must plan how the user restores it.
2. AppKit has a public desktop-image setter, [`NSWorkspace.setDesktopImageURL`](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)), but Apple exposes the accent color through a read-only property, [`NSColor.controlAccentColor`](https://developer.apple.com/documentation/appkit/nscolor/controlaccentcolor). No public accent-color setter was identified.
3. System Light/Dark mode can be changed through the first-party System Events AppleScript dictionary, but that is cross-app automation. It brings Apple Events entitlements, an Automation consent prompt, sandbox constraints, and App Review risk. It is not equivalent to a permission-free AppKit setter.
4. Ghostty is designed for text configuration and supports split config files. Runtime reload is explicit, not automatic. A generated file can be safe, but applying it to existing windows needs the documented reload action.
5. VS Code stores the active theme in settings. Its documented CLI and built-in `vscode://settings/...` URI can open settings but cannot set a value. The clean live-update route is a small VS Code companion extension that receives a URI and calls the supported configuration API.
6. App Sandbox prevents silent access to arbitrary Ghostty and VS Code configuration directories. A Mac App Store build must ask the user to select the relevant folders once, then persist security-scoped bookmarks. A directly distributed notarized build can avoid App Sandbox, but still needs Hardened Runtime for notarization.

The recommended MVP is therefore a notarized native app with adapter-specific capability reporting. It should promise static wallpaper application, Ghostty configuration generation, and VS Code theme application through a companion extension. System Light/Dark switching should be an opt-in Automation feature. Accent-color mutation should not be promised.

## 1. MenuBarExtra and app lifecycle

### Documented behavior

`MenuBarExtra` is a SwiftUI `Scene` that renders a persistent control in the system menu bar. Apple explicitly supports an app whose only scene is a menu bar extra. The API also offers a `window` style for richer, popover-like content with standard SwiftUI controls. See [`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra) and [`MenuBarExtraStyle.window`](https://developer.apple.com/documentation/swiftui/menubarextrastyle/window).

The current API supports an `isInserted` binding. If the user removes the item, SwiftUI sets the binding to `false`. Apple also states that an app that only shows in the menu bar is automatically terminated if the user removes the extra. This is an important lifecycle rule, not an edge case. See the [`MenuBarExtra` overview and initializers](https://developer.apple.com/documentation/swiftui/menubarextra).

Apple recommends `LSUIElement = true` for menu-bar-only utilities that should not appear in the Dock or application switcher. `LSUIElement` makes the app an agent app that runs in the background and does not appear in the Dock. See [`LSUIElement`](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement).

`MenuBarExtra` itself does not require a special entitlement in the documentation reviewed. Its distribution constraints come from what the app does after the user chooses a theme, especially file access and Apple Events.

### Architecture consequences

- Use a SwiftUI `App` with `MenuBarExtra` as the primary scene. Use `.menuBarExtraStyle(.window)` if the product needs theme previews, adapter health, permission status, or rollback controls.
- Do not persist an `isInserted = false` state without a recovery path. A menu-bar-only, `LSUIElement` app can otherwise relaunch with no visible control.
- Provide an explicit Quit command. Hiding the Dock icon removes a standard discovery and termination route.
- Keep theme compilation and adapter work outside view state. The scene can be recreated, removed, or terminated by the system-facing menu-bar lifecycle.
- If a settings window is added, treat it as a separate SwiftUI scene. Do not assume that adding a hidden settings scene changes Apple's documented termination behavior when the only visible menu-bar extra is removed. That specific combination remains unresolved.

### Minimum OS decision

`MenuBarExtra` is a macOS 13-era SwiftUI API. An MVP that uses it directly should target macOS 13 or later rather than maintain an `NSStatusItem` fallback. The API's availability should be rechecked in the final deployment SDK before release on the [`MenuBarExtra` reference](https://developer.apple.com/documentation/swiftui/menubarextra).

## 2. macOS appearance, accent color, and wallpaper

### Capability matrix

| Setting | Supported route | Classification | MVP status |
| --- | --- | --- | --- |
| App's own Light/Dark appearance | SwiftUI `preferredColorScheme` or AppKit appearance | Public API, scoped to this app | Safe, but does not change macOS globally |
| System Light/Dark mode | System Events `appearance preferences` AppleScript dictionary | Supported automation | Conditional on Automation permission and distribution policy |
| System accent color | Read with `NSColor.controlAccentColor` | Public read-only API | Read and display only |
| System accent color mutation | Private defaults keys commonly used by scripts | Unsupported | Do not ship or promise |
| Static desktop image per visible screen | `NSWorkspace.setDesktopImageURL` | Public API | Safe after file access is granted |
| Current desktop image and options | `desktopImageURL(for:)`, `desktopImageOptions(for:)` | Public API | Safe for snapshot and rollback |
| Dynamic wallpaper schedule, collection, or every Space | No verified public API in gathered sources | Unresolved | Do not promise |

### App appearance is not system appearance

SwiftUI's [`preferredColorScheme(_:)`](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)) sets the preferred scheme for the nearest enclosing presentation, such as a popover, sheet, or window. It overrides the user's Dark Mode choice for that presentation only. It is suitable for previewing a theme inside Oh My Theme, not for changing the operating system.

AppKit's [`NSApplication.effectiveAppearance`](https://developer.apple.com/documentation/appkit/nsapplication/effectiveappearance) reports what AppKit uses to draw the app. If the app does not assign its own appearance, it inherits the system appearance. This is also observation or app-local behavior, not a global setter.

### System Light/Dark mode through System Events

The first-party System Events scripting dictionary installed with macOS contains an `Appearance Suite`. Its `appearance preferences object` has a writable Boolean `dark mode` property. This was verified from:

```text
/System/Library/CoreServices/System Events.app/Contents/Resources/SystemEvents.sdef
```

The exact resource layout may vary by macOS release. Apple documents that a scriptable app's dictionary is the source for the commands and objects it understands. See [View an app's scripting dictionary in Script Editor](https://support.apple.com/guide/script-editor/view-an-apps-scripting-dictionary-scpedt1126/mac).

A schema-derived command is:

```applescript
tell application "System Events"
    set dark mode of appearance preferences to true
end tell
```

This is supported application automation, not a public AppKit appearance setter. A native app that sends this Apple event needs:

- `NSAppleEventsUsageDescription`, because Apple requires that key when an app uses APIs that send Apple events. See [`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription).
- The Apple Events Hardened Runtime entitlement if it needs to prompt for permission to send events to another app. See [`com.apple.security.automation.apple-events`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events).
- User approval in macOS Automation privacy controls. The entitlement permits the app to prompt, not to bypass consent.
- Additional sandbox authorization in a Mac App Store build. Apple's sandbox entitlement reference says a sandboxed app cannot send Apple events to another app unless it has a `scripting-targets` entitlement or an Apple-events temporary exception. When the target does not publish scripting access groups, the temporary exception names the target bundle identifier. Apple requires the exception and its justification to be declared during App Review. See [App Sandbox Temporary Exception Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html).

Because this route controls System Events, an MVP should present it as an optional capability and explain the Automation prompt before triggering it. Failure or denial must leave the rest of theme application usable.

### Accent color

Apple's public API exposes [`NSColor.controlAccentColor`](https://developer.apple.com/documentation/appkit/nscolor/controlaccentcolor) as:

```swift
class var controlAccentColor: NSColor { get }
```

The property returns the user's current accent preference and has no setter. No documented Apple command or public framework setter for the modern system accent color was found in the gathered sources. The System Events appearance dictionary inspected during this research exposed Dark Mode but no modern accent-color property.

Scripts that write undocumented global preference keys such as `AppleAccentColor`, `AppleHighlightColor`, or `AppleInterfaceStyle`, then restart Dock or preference services, must be classified as unsupported. The keys and restart sequence are not part of the Apple public API or supported command schemas gathered here. They may change across macOS releases, bypass normal consent and validation, and create App Review risk.

Safe product language is: "Oh My Theme reads your current macOS accent color and uses it as an input." Unsafe product language is: "Oh My Theme changes the macOS accent color."

### Wallpaper

AppKit provides a direct public API:

```swift
func setDesktopImageURL(
    _ url: URL,
    for screen: NSScreen,
    options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
) throws
```

[`NSWorkspace.setDesktopImageURL`](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)) sets the image for a given `NSScreen`, accepts scaling and placement options, throws on failure, and must run on the main thread.

Before changing it, the app can capture:

- The current image URL with [`desktopImageURL(for:)`](https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageurl(for:)).
- The current options with [`desktopImageOptions(for:)`](https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageoptions(for:)).

That gives the adapter enough documented state for per-screen rollback. The app should enumerate current `NSScreen` instances and apply the image separately to each screen the user selected.

The gathered AppKit documentation does not define how this method maps across multiple Spaces, full-screen Spaces, wallpaper collections, aerial wallpapers, automatic rotation, or dynamic HEIC time variants. The MVP should promise a static image on selected current screens, not "every wallpaper everywhere."

### Sandbox, entitlements, and distribution

Apple requires App Sandbox for Mac App Store distribution. See [`App Sandbox`](https://developer.apple.com/documentation/security/app-sandbox) and [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).

A sandboxed app starts with write access to its own container, not arbitrary locations under `~/.config` or another app's `Application Support` directory. Apple supports access to arbitrary user-selected files or folders through `NSOpenPanel` or SwiftUI file importers. For access after relaunch, the app must save a security-scoped bookmark, resolve it later, call `startAccessingSecurityScopedResource()`, and balance that with `stopAccessingSecurityScopedResource()`. See [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) and [`startAccessingSecurityScopedResource()`](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource()).

This means a sandboxed Oh My Theme cannot silently discover and edit Ghostty and VS Code config files on first launch. It needs a setup step in which the user selects each relevant configuration folder. Selecting the folder rather than one current file lets the app create managed fragments and backups inside that folder, subject to normal POSIX and ACL permissions.

Notarization and App Sandbox are separate decisions. Apple's [`Hardened Runtime`](https://developer.apple.com/documentation/security/hardened-runtime) documentation states that Hardened Runtime is required to upload macOS software for notarization. The gathered sources state that App Sandbox is mandatory for the Mac App Store, not for direct notarized distribution. A direct-download MVP can therefore use Hardened Runtime without App Sandbox, which removes the security-scoped bookmark setup for ordinary user-owned config files. It should still avoid elevated privileges and Apple Events unless a feature needs them.

Suggested distribution order:

1. Ship a Developer ID signed, Hardened Runtime enabled, notarized direct download.
2. Keep all config access within the logged-in user's permissions.
3. Evaluate a sandboxed Mac App Store build after the adapter workflow and Automation entitlement have been tested in App Review.

## 3. Ghostty integration

### Config locations and precedence

Ghostty's official configuration guide states that configuration is optional and text based. The modern file name is `config.ghostty`; releases before 1.2.3 also use `config`. Ghostty loads the following locations in order, with later conflicting values winning:

1. `$XDG_CONFIG_HOME/ghostty/config.ghostty`
2. `$XDG_CONFIG_HOME/ghostty/config`
3. If `XDG_CONFIG_HOME` is unset, the base is `$HOME/.config`
4. `$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty`
5. `$HOME/Library/Application Support/com.mitchellh.ghostty/config`

The macOS-specific files load after the XDG files. See [Ghostty configuration, File Location](https://ghostty.org/docs/config#file-location).

The adapter must inspect all candidates before choosing where to insert its managed include. Hard-coding only `~/.config/ghostty/config` can lose to a later macOS-specific file.

### Include behavior

Ghostty supports repeated `config-file` directives. The official rules are:

- Included paths may be absolute.
- Relative paths are relative to the file containing the directive.
- A leading `?` makes an include optional.
- Includes can include more files.
- Cycles are detected and warned about.
- All `config-file` directives in a file are processed after the rest of that file.
- Included files load in directive order and can override the parent file.

See [Ghostty configuration, Splitting into Multiple Files](https://ghostty.org/docs/config#splitting-into-multiple-files) and [`config-file` in the option reference](https://ghostty.org/docs/config/reference#config-file).

A one-time line in the last effective user config is therefore the least invasive integration:

```text
config-file = ?oh-my-theme/config.ghostty
```

Oh My Theme owns only `oh-my-theme/config.ghostty`. It should not repeatedly rewrite the user's main file. If the directive already exists, leave its formatting and location alone.

### Theme files and exact control

Ghostty accepts a built-in theme name, a custom theme name, or an absolute path in the `theme` setting. Named user themes are searched under `$XDG_CONFIG_HOME/ghostty/themes`; built-in macOS themes are inside `Ghostty.app/Contents/Resources/ghostty/themes`. `ghostty +list-themes` lists available themes. See [Ghostty Color Theme](https://ghostty.org/docs/features/theme) and [`theme` in the option reference](https://ghostty.org/docs/config/reference#theme).

A Ghostty theme is a normal Ghostty config file and can set any configuration option, so themes from untrusted sources must be reviewed. Theme files cannot set `theme` or `config-file`. Ghostty loads theme settings first, then lets normal user configuration override them. See the same [`theme` reference](https://ghostty.org/docs/config/reference#theme).

That load order affects the product design. If Oh My Theme writes only:

```text
theme = /path/to/generated-theme
```

then direct `background`, `foreground`, or `palette` values elsewhere in the user's config can still win. If the product promises exact semantic colors, the managed config fragment should write the explicit color keys itself and load last. If the product promises a suggested theme that respects user overrides, use the `theme` setting.

Ghostty supports paired themes:

```text
theme = dark:Oh My Theme Dark,light:Oh My Theme Light
```

It then follows the desktop environment appearance. Both variants must be supplied. Ghostty documents a current macOS bug in which titlebar tabs do not update when switching paired themes. See [`theme`](https://ghostty.org/docs/config/reference#theme).

### Live reload

Ghostty does not document automatic file watching as the config application mechanism. It documents an explicit runtime reload action:

- Default macOS shortcut: `cmd+shift+,`
- Action name: `reload_config`

See [Reloading the Configuration](https://ghostty.org/docs/config#reloading-the-configuration).

Some options cannot reload at runtime, and some affect only newly created terminals. The option reference marks these limits per setting. Color themes are documented with an instruction to reload after changing the theme, so palette changes are intended to work through config reload. See [Ghostty Color Theme](https://ghostty.org/docs/features/theme).

Ghostty 1.3.0 introduced an official AppleScript dictionary. Its `perform action` command accepts the same action strings used by keybindings, which makes `reload_config` a plausible supported automation route for existing terminals. AppleScript control is enabled by default in Ghostty and protected by macOS Automation consent. See [Ghostty AppleScript](https://ghostty.org/docs/features/applescript).

A schema-derived reload would target a terminal, for example:

```applescript
tell application "Ghostty"
    perform action "reload_config" on focused terminal of selected tab of front window
end tell
```

This exact reload script was not runtime-tested during this research. The MVP should initially support these outcomes explicitly:

1. Ghostty is not running. Write the config; the next launch reads it.
2. Ghostty is running and AppleScript 1.3 support is available. Offer automated reload after Automation consent.
3. Ghostty is running without usable AppleScript support. Tell the user to press `cmd+shift+,`.

Do not simulate the keyboard shortcut with Accessibility APIs. That would add a broader permission for a job Ghostty already exposes through its own action system.

### Ghostty limitations that belong in product copy

- User settings loaded after a theme can override theme colors.
- A managed last-loaded config fragment can instead override user choices, so onboarding must state which behavior the user selected.
- Config reload is explicit.
- Some options need new terminals or a full restart. The adapter should own only documented reloadable color options in the MVP.
- Separate Light/Dark themes have the documented macOS titlebar-tabs update bug.
- AppleScript automation requires Ghostty 1.3.0 or later and user approval.

## 4. VS Code integration

### Theme selection and settings locations

VS Code stores the active color theme in the `workbench.colorTheme` setting:

```jsonc
{
  "workbench.colorTheme": "Solarized Dark"
}
```

The setting is global by default but can also be set at workspace scope. Workspace values override the global user value. See [VS Code Themes](https://code.visualstudio.com/docs/configure/themes) and [User and workspace settings](https://code.visualstudio.com/docs/configure/settings).

The standard macOS user settings file is:

```text
$HOME/Library/Application Support/Code/User/settings.json
```

Profiles have separate settings under:

```text
$HOME/Library/Application Support/Code/User/profiles/<profile ID>/settings.json
```

See [Settings file locations](https://code.visualstudio.com/docs/configure/settings#_settings-file-locations) and [Profile settings](https://code.visualstudio.com/docs/configure/settings#_profile-settings).

VS Code can follow macOS Light/Dark changes using `window.autoDetectColorScheme`. The matching themes are selected through `workbench.preferredLightColorTheme` and `workbench.preferredDarkColorTheme`. See [Automatically switch based on OS color scheme](https://code.visualstudio.com/docs/configure/themes#_automatically-switch-based-on-os-color-scheme).

This supports a clean semantic model with separate Oh My Theme Light and Dark VS Code themes. It does not guarantee that every open workspace uses them, because a workspace-level `workbench.colorTheme` remains more specific.

### Reload behavior

VS Code's Settings UI applies changes directly as the user changes them, and color-theme selection previews and applies the theme without a window restart. See [Settings editor](https://code.visualstudio.com/docs/configure/settings#_settings-editor) and [Color Themes](https://code.visualstudio.com/docs/configure/themes#_color-themes).

Inside a VS Code extension, the supported mutation API is:

```ts
vscode.workspace
  .getConfiguration("workbench")
  .update("colorTheme", themeName, vscode.ConfigurationTarget.Global);
```

`WorkspaceConfiguration.update` persists the value and supports global, workspace, and workspace-folder targets. VS Code exposes `workspace.onDidChangeConfiguration` and `window.onDidChangeActiveColorTheme` for confirmation. See [`WorkspaceConfiguration.update`](https://code.visualstudio.com/api/references/vscode-api#WorkspaceConfiguration), [`workspace.onDidChangeConfiguration`](https://code.visualstudio.com/api/references/vscode-api#workspace), and [`window.onDidChangeActiveColorTheme`](https://code.visualstudio.com/api/references/vscode-api#window).

This is the strongest supported live-update path because VS Code itself owns parsing, profile selection, settings precedence, concurrent writes, and UI refresh.

External mutation of `settings.json` is supported in the broad sense that VS Code documents direct editing of the file. However, the gathered sources did not verify the exact behavior when another process replaces the file while VS Code has a dirty `settings.json` editor, several VS Code windows are running, Settings Sync is active, or different profiles are open. Treat instant external-file reload as unresolved, not as an MVP guarantee.

### CLI and URI limits

The documented `code` CLI can open files and folders, select a profile when launching, list extensions, install extensions, and uninstall extensions. The documented options do not include a command to mutate an arbitrary setting or select a color theme. See [VS Code Command Line Interface](https://code.visualstudio.com/docs/configure/command-line).

The built-in URI:

```text
vscode://settings/workbench.colorTheme
```

opens the Settings editor at that setting. It does not assign a value. See [Opening VS Code with URLs](https://code.visualstudio.com/docs/configure/command-line#_opening-vs-code-with-urls) and [Settings URLs](https://code.visualstudio.com/docs/configure/settings#_settings-editor).

A companion extension can register its own URI handler. VS Code restricts the URI authority to that extension's identifier and routes the URI to `UriHandler.handleUri`. See [`window.registerUriHandler`](https://code.visualstudio.com/api/references/vscode-api#window) and [`UriHandler`](https://code.visualstudio.com/api/references/vscode-api#UriHandler).

This gives Oh My Theme a supported bridge:

```text
vscode://ohmytheme.oh-my-theme/apply?theme=<encoded-theme-id>&nonce=<value>
```

The extension validates the request, calls `WorkspaceConfiguration.update`, and returns status through a local acknowledgement mechanism if one is designed. The URI must not contain secrets. A nonce can prevent accidental replay, but a complete handshake design remains implementation work.

The app can install the companion extension with the documented CLI option:

```text
code --install-extension publisher.extension
```

It must not assume `code` is already in `PATH` on macOS. Microsoft's documentation says users install the shell command separately through "Shell Command: Install 'code' command in PATH." The native app should locate VS Code through Launch Services and invoke the executable inside the selected app bundle, or ask the user to install the extension manually. See [Launching from command line](https://code.visualstudio.com/docs/configure/command-line#_launching-from-command-line).

### Theme payload options

There are two supported approaches:

1. **Theme extension.** Contribute stable Light and Dark color themes and select them through `workbench.colorTheme` or the preferred Light/Dark settings. See [Color Theme extension guide](https://code.visualstudio.com/api/extension-guides/color-theme) and [`contributes.themes`](https://code.visualstudio.com/api/references/contribution-points#contributes.themes).
2. **Settings customization.** Write `workbench.colorCustomizations`, `editor.tokenColorCustomizations`, and semantic-token customization settings. VS Code documents these settings, but they merge with theme and workspace values. See [Customize a Color Theme](https://code.visualstudio.com/docs/configure/themes#_customize-a-color-theme) and [Settings precedence](https://code.visualstudio.com/docs/configure/settings#_settings-precedence).

For an MVP, a companion extension with two contributed themes is simpler and safer. Dynamic arbitrary palettes would require generating or updating extension assets, or writing large customization objects while preserving user-owned keys. That can follow later.

### VS Code limitations that belong in product copy

- A global theme is a default. A workspace can override it.
- Profiles have separate settings. A request handled by an active extension applies to that VS Code instance and profile, not automatically to every profile on disk.
- Remote windows have remote and workspace settings in the precedence chain. The UI theme still belongs to the local client, but adapter verification must not infer all settings from one default file.
- The stable CLI has no documented `set-setting` or `set-theme` command.
- `vscode://settings/...` opens a setting. It does not change it.
- Direct external editing needs JSON-with-comments preservation and conflict handling. A companion extension avoids most of that risk.

## 5. Safe config editing and rollback

### Ownership rule

Oh My Theme should own generated files, not whole user configuration files. The preferred shape is:

```text
Oh My Theme semantic model
    -> generated Ghostty fragment
    -> VS Code companion extension setting
    -> macOS wallpaper operation
```

The app may add one clearly marked include line to Ghostty's effective config. It should not reformat the file, sort unrelated settings, remove duplicates it does not own, or replace comments.

For VS Code, prefer the extension configuration API. If a file fallback is offered, mutate only the intended keys with a JSONC-aware editor that preserves comments, trailing commas, ordering, indentation, and final newline.

Never run configuration writes through `sudo`. The app must operate as the logged-in user. Before replacing a file, record the original owner, permissions, extended attributes where relevant, bytes, and a content hash. A replacement strategy that silently changes ownership or mode is a failed apply.

### Write protocol

Each adapter should implement the same staged protocol:

1. **Discover.** Resolve the installed target, running state, effective config path, and current owned values.
2. **Plan.** Produce an immutable change plan and rollback record without writing.
3. **Authorize.** Acquire any security-scoped resource and required Automation consent.
4. **Revalidate.** Compare the current file identity and hash with the snapshot used for planning. Abort if another process changed it.
5. **Stage.** Write the new bytes to a temporary sibling file where possible.
6. **Validate.** Parse the staged file with the adapter's parser or target CLI where a supported validator exists.
7. **Replace.** Use an atomic write or replacement rather than truncating the live file. Foundation exposes [`Data.write(to:options:)`](https://developer.apple.com/documentation/foundation/data/write(to:options:)) and the [`atomic` writing option](https://developer.apple.com/documentation/foundation/data/writingoptions/atomic).
8. **Apply.** Call the target's supported reload mechanism.
9. **Verify.** Read supported target state or wait for an adapter acknowledgement.
10. **Commit.** Mark the rollback record successful only after verification.

The app should serialize operations per adapter and allow only one cross-adapter apply transaction at a time.

### Backups

Store rollback snapshots in Oh My Theme's own Application Support directory, not as an unbounded trail beside user config files. A rollback record should contain:

- Transaction ID and timestamp.
- Adapter and target version.
- Original path and file identity.
- Original bytes or the original values for API-driven settings.
- Original content hash and post-apply hash.
- Original file metadata needed to preserve ownership and mode.
- macOS wallpaper URL and options for each screen.
- Whether target reload and verification succeeded.

Backups should be bounded by count or age. Never delete the last known-good snapshot for a currently applied managed configuration.

### Concurrency

[`NSFileCoordinator`](https://developer.apple.com/documentation/foundation/nsfilecoordinator) coordinates access among processes and objects that participate through file coordinators and file presenters. It does not make arbitrary third-party editors transactional. Ghostty and VS Code cannot be assumed to participate in Oh My Theme's file-coordination session.

Use optimistic concurrency even if `NSFileCoordinator` is present:

- Snapshot file identity, size, modification time, and a cryptographic hash.
- Re-read immediately before replacement.
- Abort and ask the user to retry if the file changed.
- Watch managed files while an apply is in progress, but do not treat a watcher as a lock.
- Do not overwrite a dirty VS Code settings editor. This is one reason to use the extension API.

There is no atomic transaction spanning `NSWorkspace`, Ghostty, and VS Code. The coordinator must use a saga-style transaction. Apply adapters in a deterministic order, record each success, and roll back completed adapters in reverse order if a later adapter fails. Rollback itself can fail, so the UI must report per-adapter state rather than claiming an all-or-nothing guarantee.

### Rollback semantics

Rollback must restore only state owned or captured by the transaction.

- For a generated Ghostty fragment, restore the previous fragment bytes. Remove it only if the transaction created it and no later user change exists.
- For the Ghostty include line, remove only the exact line Oh My Theme inserted and only when its surrounding file still matches the expected post-apply hash.
- For VS Code, a companion extension should restore the prior inspected value using the same `WorkspaceConfiguration.update` target. It must not restore a global value over a later user edit.
- For wallpaper, call `setDesktopImageURL` with the captured URL and options for each still-present screen.
- If current state differs from the expected post-apply state, stop and offer a diff. Never force rollback over an external edit.

## 6. Detecting installed and running apps

Use Launch Services and bundle identifiers, not hard-coded `/Applications` paths.

[`NSWorkspace.urlForApplication(withBundleIdentifier:)`](https://developer.apple.com/documentation/appkit/nsworkspace/urlforapplication(withbundleidentifier:)) returns the URL of the default app matching a bundle identifier and applies heuristics if several copies exist. [`NSRunningApplication.runningApplications(withBundleIdentifier:)`](https://developer.apple.com/documentation/appkit/nsrunningapplication/runningapplications(withbundleidentifier:)) returns matching running applications or an empty array. [`NSWorkspace.runningApplications`](https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications) can be observed instead of polled.

Adapter discovery should:

1. Keep a list of supported product bundle identifiers.
2. Ask Launch Services for installed app URLs.
3. Read the selected bundle's `Info.plist` for version and identifier.
4. Ask `NSRunningApplication` for running instances.
5. Treat multiple installed copies as an ambiguity that the user can resolve.
6. Never equate "config directory exists" with "app is installed."

The Ghostty config path documents the bundle-style identifier `com.mitchellh.ghostty`, but the adapter should still verify the installed app's actual `CFBundleIdentifier` before relying on it. See [Ghostty configuration locations](https://ghostty.org/docs/config#file-location).

VS Code supports Stable, Insiders, profiles, portable data directories, and alternate products built from the open-source code. The official CLI documents `code-insiders` separately and supports `--user-data-dir`, which can create isolated settings and extension directories. See [VS Code CLI](https://code.visualstudio.com/docs/configure/command-line), especially [Advanced CLI options](https://code.visualstudio.com/docs/configure/command-line#_advanced-cli-options). The MVP should support the standard stable app first and label custom user-data directories as unsupported until the user explicitly selects one.

## 7. Adapter architecture

### Semantic core

The core theme must not contain Ghostty keys, VS Code setting names, or macOS API objects. Define semantic roles such as:

```text
appearance: light | dark
background.canvas
background.elevated
foreground.primary
foreground.muted
accent.primary
accent.contrast
selection.background
selection.foreground
terminal.ansi[0...15]
wallpaper.asset
```

A validation layer should check required roles, contrast policy, valid color encodings, and presence of Light/Dark variants before any adapter runs.

### Adapter contract

Each adapter should expose capabilities rather than pretend every target supports the same operations:

```swift
protocol ThemeAdapter {
    var id: AdapterID { get }

    func discover() async -> AdapterDiscovery
    func inspect() async throws -> AdapterState
    func plan(theme: SemanticTheme, from state: AdapterState) throws -> ApplyPlan
    func apply(_ plan: ApplyPlan) async throws -> ApplyReceipt
    func verify(_ receipt: ApplyReceipt) async throws -> VerificationResult
    func rollback(_ receipt: ApplyReceipt) async throws -> RollbackResult
}
```

`AdapterDiscovery` should report independent flags such as:

- Installed.
- Running.
- Writable.
- Needs folder authorization.
- Needs Automation authorization.
- Supports live reload.
- Supports only next-launch application.
- Has user overrides.
- Has unresolved config location.

This makes partial success honest. A denied macOS Automation request should not prevent Ghostty and VS Code from applying.

### Recommended adapters

#### macOS adapter

- Public sub-adapter for static wallpaper through `NSWorkspace`.
- Read-only accent-color observer through `NSColor.controlAccentColor`.
- Optional System Events sub-adapter for Light/Dark mode.
- No private defaults writer.

#### Ghostty adapter

- Detect all official config candidates and precedence.
- Add one optional include to the final effective config.
- Own an explicit-color generated fragment.
- Reload through Ghostty 1.3 AppleScript when available, otherwise give the documented shortcut.
- Verify by parsing the managed fragment and, where available, using Ghostty's documented config inspection CLI such as `ghostty +show-config`. See [Ghostty offline reference documentation](https://ghostty.org/docs/config#offline-reference-documentation).

#### VS Code adapter

- Detect the stable app through Launch Services.
- Install or guide installation of a companion extension.
- Send an extension-scoped URI.
- Let the extension call `WorkspaceConfiguration.update` and verify `window.activeColorTheme` or the persisted setting.
- Report workspace and profile overrides instead of silently editing them.
- Keep direct `settings.json` mutation as an explicit fallback, preferably while VS Code is closed.

### Why adapters need version gates

Ghostty AppleScript starts at 1.3.0. Ghostty config naming changed at 1.2.3. VS Code supports profiles and custom user-data directories. macOS privacy and sandbox behavior differ by deployment version. Each adapter should declare the minimum version for each capability and degrade to "write for next launch" or "manual reload required" when a capability is absent.

## 8. Technically safe MVP promises

### Safe promises

These claims are supported by the gathered first-party material:

- "Oh My Theme is a native macOS menu-bar app."
- "One semantic palette generates matching colors for Ghostty and VS Code."
- "Oh My Theme can set a static wallpaper on selected connected displays."
- "Oh My Theme preserves a rollback snapshot before it changes managed configuration."
- "Ghostty changes use its documented configuration format and reload action."
- "VS Code changes use its supported extension settings API when the companion extension is installed."
- "The app detects supported installed and running apps through macOS application services."
- "Every adapter reports whether it applied, needs permission, needs manual reload, or failed."

### Conditional promises

These need a qualifier in the UI and marketing copy:

- "Switch macOS between Light and Dark." Add "after you grant Automation permission."
- "Update Ghostty immediately." Add "with Ghostty 1.3 or later and Automation permission; otherwise use Ghostty's reload shortcut."
- "Follow macOS appearance in VS Code." Add "unless the current workspace or profile overrides the global theme settings."
- "Works from the Mac App Store." Add "after sandbox folder selection and successful review of required automation entitlements." This is not an MVP assumption.

### Promises to reject

Do not promise these for the MVP:

- Changing the macOS accent color through public APIs.
- Permission-free system Light/Dark switching.
- Applying a wallpaper to every Space, wallpaper collection, and dynamic schedule.
- Instant Ghostty changes without reload.
- Overriding all Ghostty user color settings while also claiming user overrides are preserved.
- Changing every VS Code profile, workspace, remote window, Insiders build, and custom `--user-data-dir` from one stable settings file.
- A truly atomic apply across macOS, Ghostty, and VS Code.
- Silent first-run config access in a sandboxed Mac App Store build.

## 9. Unresolved items and focused proofs

Research was stopped before broad first-party source inspection completed. These items should be resolved with small, targeted proofs before implementation commitments:

1. **Sandboxed wallpaper proof.** Build a minimal sandboxed app and confirm `setDesktopImageURL` behavior for a bundled image and a security-scoped user-selected image on the minimum supported macOS version.
2. **Spaces semantics.** Verify exactly which Spaces and displays change when calling `setDesktopImageURL` once per current `NSScreen`. Until then, keep the promise limited to selected connected displays.
3. **MenuBarExtra recovery.** Test a menu-bar-only `LSUIElement` app with `isInserted`, app relaunch, and a Settings scene after the user removes the item.
4. **System Events distribution.** Confirm the current System Events bundle identifier, required sandbox entitlement combination, consent flow, and App Store review acceptability on the chosen deployment target.
5. **Ghostty reload automation.** Test `perform action "reload_config"` against Ghostty 1.3 with one window, several windows, no focused terminal, and no open windows. Confirm whether one action reloads all surfaces.
6. **Ghostty validation.** Confirm the exact `ghostty +show-config` invocation and exit behavior for a staged alternate config without modifying user state.
7. **VS Code external edits.** If a no-extension fallback remains, test external atomic replacement while settings are clean, settings are dirty, several windows are open, Settings Sync is active, and a profile is selected.
8. **VS Code URI acknowledgement.** Define and threat-model a local acknowledgement channel. A URI launch alone confirms only that macOS dispatched a URL, not that the requested setting applied.
9. **Bundle identifiers.** Pin and test the official Stable and optional Insiders bundle identifiers from installed signed bundles before implementing discovery tables.

None of these unresolved items blocks the recommended direct-download MVP architecture. They do block stronger claims about App Store distribution, every-Space wallpaper behavior, automatic Ghostty reload in all states, and extension-free live VS Code mutation.

## Final recommendation

Build the MVP as a native SwiftUI `MenuBarExtra` app distributed outside the Mac App Store with Developer ID signing, Hardened Runtime, and notarization. Keep the core theme semantic and compile it through capability-aware adapters.

Use public AppKit for static wallpaper. Treat macOS accent color as read-only. Put System Light/Dark automation behind a clear, optional permission step. For Ghostty, own a last-loaded generated config fragment and use the documented reload action. For VS Code, ship a companion extension and update settings through `WorkspaceConfiguration.update` rather than editing a live settings file from another process.

That product is technically credible. A version that promises silent system accent changes, universal wallpaper control, or instant mutation of every editor profile is not.
