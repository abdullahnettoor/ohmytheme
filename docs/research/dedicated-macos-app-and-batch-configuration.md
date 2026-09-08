# Dedicated macOS app and batch configuration direction

Research cutoff: 2026-09-06

## Question

Should Oh My Theme move configuration out of its menu bar popover into a dedicated macOS app with first-run onboarding, a System Settings-like native interface, and one-action setup and application for all target instances the user selects?

## Evidence standard and labels

This note uses only Apple documentation and Human Interface Guidelines, first-party target documentation and API references, first-party source repositories, and the Oh My Theme repository itself.

- **Sourced fact** means the statement follows from a linked primary source or the checked-in implementation.
- **Recommendation** means a proposed product or architecture choice.
- **Inference** means a conclusion drawn from sourced facts that the source does not state directly.

## Executive recommendation

**Recommendation:** Make a normal macOS window the primary product interface. Keep a menu bar extra as an optional, minimal control for viewing Workspace health, opening the app, and quitting.

Use one first-run flow to discover target instances, let the user opt into all desired instances, present one aggregate setup review, and run a durable batch connection operation. The operation should pause only for macOS consent dialogs, file or folder selection when sandboxing requires it, target-app steps that have no supported automation route, and conflicts that require a human choice.

After setup, one Apply action should target the saved Workspace. Do not ask the user to revisit each app unless its permission was denied or revoked, its configuration changed externally, the selected instance became ambiguous, or the target itself requires a reload or other documented action.

This is primarily a presentation and setup-orchestration change, not a new apply engine. The repository already models one Workspace, connected target instances, immutable plans, per-target outcomes, durable apply operations, recovery, and guarded undo. The missing pieces are a main-window shell, persisted onboarding state, target opt-in state before connection, and a batch connection transaction. [Workspace model](../../Packages/OhMyThemeKit/Sources/ThemeModel/Workspace.swift#L1-L23), [connected target model](../../Packages/OhMyThemeKit/Sources/ThemeModel/ConnectedTargetInstance.swift#L1-L13), [theme preview and outcomes](../../Packages/OhMyThemeKit/Sources/ThemeEngine/ThemeEngine.swift#L26-L33), [durable apply loop](../../Packages/OhMyThemeKit/Sources/ThemeEngine/DurableOperations.swift#L345-L475)

## What exists today

### Sourced facts

- The app declares only a `MenuBarExtra` scene with window style. It has no `WindowGroup` or `Settings` scene. [Current app scene](../../App/OhMyThemeApp/OhMyThemeApp.swift#L3-L26)
- The popover is a fixed 380 by 640 point scrolling view containing target discovery and connection, theme selection and preview, apply results, Launch at Login, undo, and quit. [Current menu layout](../../App/OhMyThemeApp/UI/WorkspaceMenuView.swift#L20-L61), [theme workflow](../../App/OhMyThemeApp/UI/WorkspaceMenuView.swift#L275-L400), [startup and footer](../../App/OhMyThemeApp/UI/WorkspaceMenuView.swift#L466-L528)
- Target setup is currently app-by-app. The presentation model reviews and connects one `TargetInstanceID` at a time, and `ThemeEngine.connect` starts one durable connection operation for one instance. [Presentation connection flow](../../App/OhMyThemeApp/UI/WorkspaceMenuModel.swift#L241-L261), [single-instance runtime API](../../App/OhMyThemeApp/AppComposition/ProductionWorkspaceRuntime.swift#L135-L182), [single-instance engine operation](../../Packages/OhMyThemeKit/Sources/ThemeEngine/DurableOperations.swift#L68-L99)
- Theme application is already workspace-wide. `ThemeEngine.prepare` iterates every connected target instance, keeps each plan and preparation failure separate, and `applyDurable` executes the prepared plans in deterministic order while retaining per-target outcomes. [Workspace preparation](../../Packages/OhMyThemeKit/Sources/ThemeEngine/ThemeEngine.swift#L426-L579), [durable apply loop](../../Packages/OhMyThemeKit/Sources/ThemeEngine/DurableOperations.swift#L345-L475)
- The app currently discovers macOS appearance, wallpaper displays, Ghostty, VS Code, and Starship. It exposes connection candidates for appearance, Ghostty, VS Code, and Starship. Wallpaper discovery is displayed as informational text, but the runtime does not add wallpaper display candidates to its candidate map. [Discovery and candidates](../../App/OhMyThemeApp/AppComposition/ProductionWorkspaceRuntime.swift#L203-L293), [presented target list](../../App/OhMyThemeApp/AppComposition/ProductionWorkspaceRuntime.swift#L296-L343)
- The architecture contract already says that missing apps, denied optional permissions, and unavailable targets do not cancel unrelated targets. It also accepts partial apply results and requires a report grouped by target instance and capability. [MVP support model](../architecture/mvp-plan.md#L49-L80), [apply transaction contract](../architecture/mvp-plan.md#L225-L240)

### Inference

The current friction comes from putting setup, configuration management, execution, and recovery into a transient menu bar surface, then exposing only a single-target connection command. The Workspace and apply engine already represent the desired post-onboarding behavior.

## Recommended product structure

### Primary window

**Recommendation:** Add a normal SwiftUI main window and make it the canonical place for setup, app selection, target details, reports, and recovery. A `WindowGroup` is the standard SwiftUI scene for an app window and automatically participates in macOS window management. An identified scene can also be brought forward with `openWindow`. [Apple `WindowGroup`](https://developer.apple.com/documentation/swiftui/windowgroup), [Apple `OpenWindowAction`](https://developer.apple.com/documentation/swiftui/openwindowaction)

Use a two-column `NavigationSplitView`. Apple defines it as a two- or three-column container in which selection in a leading column controls the detail column. [Apple `NavigationSplitView`](https://developer.apple.com/documentation/swiftui/navigationsplitview)

**Recommended sidebar:**

1. Overview
2. Themes
3. Apps
4. Activity

**Recommended detail responsibilities:**

- **Overview:** desired Theme Assignment, timestamped Workspace Theme Status, one primary Apply action, latest results, recovery needs, and Undo Last Theme Change.
- **Themes:** theme catalog, variant preview, source attribution, and fixed versus future Light/Dark pair assignment.
- **Apps:** discovered targets and instances, opt-in controls, support tier, setup requirements, ownership details, and restore or disconnect actions.
- **Activity:** current operation progress, past apply reports, recovery-required records, and actionable errors.

**Recommendation:** Use native `List`, `Form`, `Section`, `Toggle`, `Picker`, `Button`, `ProgressView`, `Label`, sheets, alerts, and toolbar items. Match System Settings through hierarchy, spacing, sidebar navigation, and standard controls rather than copying its private visual details. Apple’s HIG sections on [sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [settings](https://developer.apple.com/design/human-interface-guidelines/settings), [onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding), and [privacy](https://developer.apple.com/design/human-interface-guidelines/privacy) are the design references.

### App settings

**Recommendation:** Put app-level preferences in a SwiftUI `Settings` scene rather than mixing them into the Workspace screen. Apple’s `Settings` scene enables the standard app Settings command and manages presentation of the settings window. [Apple `Settings`](https://developer.apple.com/documentation/swiftui/settings)

Suggested settings groups:

- General: Launch at Login and menu bar visibility.
- Safety: confirmation policy, retained recovery data, and reset.
- Advanced: theme source policy and experimental adapters.
- About: version, licenses, and update checks.

Launch at Login should remain opt-in. `SMAppService` exposes registration status, registration and unregistration, and a direct route to the Login Items settings panel when approval is required. [Apple `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice), [current implementation](../../Packages/OhMyThemeKit/Sources/PlatformClients/LaunchAtLoginClient.swift#L18-L47)

## Recommended first-run onboarding

**Recommendation:** Use a resumable first-run flow inside the main window, not a chain of popovers or one modal per app.

### Step 1: Explain the contract

State the product promise in concrete terms: Oh My Theme changes only the apps and macOS capabilities the user selects, records recoverable state before it changes anything, and reports targets separately. This matches the repository’s existing definition of a connected target instance and apply report. [Domain definitions](../../CONTEXT.md#L39-L53), [apply report definition](../../CONTEXT.md#L87-L97)

Do not request permissions on this page.

### Step 2: Discover and select

Show discovered target instances with checkboxes or toggles. Preselect nothing except choices that are clearly harmless and reversible. Distinguish:

- Ready to configure automatically
- Needs one-time setup or permission
- Will require a reload or next launch
- Unavailable through supported mechanisms

Instances, not app names, are the durable selection unit. VS Code editions and profiles, wallpaper displays, and future terminal profiles can differ independently. The repository already models this distinction. [Target instance definition](../../CONTEXT.md#L39-L49), [VS Code instance identity](../../Packages/OhMyThemeKit/Sources/Adapters/VSCodeConnectionAdapter.swift#L369-L385), [wallpaper display instances](../../Packages/OhMyThemeKit/Sources/ThemeEngine/MacOSWallpaperAdapter.swift#L22-L37)

### Step 3: Review one setup plan

Prepare every selected connection without mutating external state. Present one grouped review with:

- selected instances;
- exact managed files, settings, extensions, or commands;
- linked dotfile or Nix ownership warnings;
- permissions that macOS will request;
- expected running-instance reach;
- residual manual actions;
- the disconnect and restoration behavior.

The existing `ConnectionPlan` and `AdapterPlan` concepts already carry expected side effects, required permissions, user actions, stale-state tokens, and captured pre-change state. [Adapter plan fields](../../Packages/OhMyThemeKit/Sources/ThemeEngine/ThemeEngine.swift#L127-L180), [connection and plan contract](../architecture/mvp-plan.md#L202-L223)

### Step 4: Configure selected apps

Use one primary button, “Configure selected apps.” It should start one durable setup batch and process target instances in deterministic order.

The operation may display or wait for a macOS-owned consent dialog. It should not hide such prompts, simulate approval, or mark the target connected before verification. Apple requires a usage description when an app sends Apple events, and the Apple Events entitlement only permits the app to ask for authorization. [Apple `NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription), [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events), [Apple Automation controls](https://support.apple.com/guide/mac-help/allow-apps-to-automate-and-control-other-apps-mchl108e1718/mac)

### Step 5: Choose and apply a theme

After at least one target connects, choose an initial theme and run the existing workspace-wide prepare and apply path. Show live progress per target, then one summary grouped by target and capability. [Workspace prepare](../../Packages/OhMyThemeKit/Sources/ThemeEngine/ThemeEngine.swift#L466-L579), [current grouped report presentation](../../App/OhMyThemeApp/UI/WorkspaceMenuModel.swift#L372-L418)

### Step 6: Finish

Offer optional Launch at Login and optional menu bar visibility. Never make either a prerequisite for using the main app.

### Resumption

**Recommendation:** Persist onboarding as derived progress, not a single `didFinishOnboarding` flag. On launch, derive the next useful screen from discovery, selected instances, stored connection baselines, permission state, and interrupted operations. The current engine already reconciles interrupted work at startup before returning the target snapshot. [Runtime startup](../../App/OhMyThemeApp/AppComposition/ProductionWorkspaceRuntime.swift#L124-L132)

## The menu bar’s reduced role

### Sourced facts

Apple describes `MenuBarExtra` as access to commonly used functionality when an app is not active. Apple also states that a menu-bar-only app is terminated if the user removes its extra. [Apple `MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)

### Recommendation

Keep the menu bar extra optional and small in the first release:

- concise Workspace health;
- Open Oh My Theme;
- Quit.

Theme commands, setup, Undo Last Theme Change, and detailed results remain in the main window.

Do not put target discovery, connection review, permission education, file-path inspection, app selection, detailed reports, or restore and disconnect workflows in the menu bar extra.

### Inference

A main `WindowGroup` gives the product a recoverable Dock, Spotlight, and application-menu entry point even if the menu bar item is hidden. That removes the menu-bar-only lifecycle hazard from the primary interface while retaining the menu bar’s strength as a quick command surface. The SwiftUI `WindowGroup` and `MenuBarExtra` APIs support both scenes in one app. [Apple `WindowGroup`](https://developer.apple.com/documentation/swiftui/windowgroup), [Apple `MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)

## Automation and one-action feasibility

“One action” should mean one Oh My Theme command after the user has selected and reviewed targets. It cannot mean one universal system transaction or zero platform consent.

| Current target or capability | What can be batched | Necessary intervention or boundary | Evidence |
|---|---|---|---|
| macOS Light/Dark appearance | Connection and later apply can run inside the batch. | macOS may require the user to approve control of System Events. Denial or revocation must become a per-capability result. | [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events), [Apple Automation controls](https://support.apple.com/guide/mac-help/allow-apps-to-automate-and-control-other-apps-mchl108e1718/mac), [current adapter](../../Packages/OhMyThemeKit/Sources/ThemeEngine/MacOSAppearanceAdapter.swift#L86-L145) |
| macOS wallpaper | Each selected display can be prepared and changed in the same batch. | The public API sets one screen at a time, throws on failure, and must run on the main thread. The current UI still needs a display opt-in path. | [Apple `setDesktopImageURL`](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)), [current wallpaper adapter](../../Packages/OhMyThemeKit/Sources/ThemeEngine/MacOSWallpaperAdapter.swift#L137-L220), [current candidate gap](../../App/OhMyThemeApp/AppComposition/ProductionWorkspaceRuntime.swift#L249-L305) |
| Ghostty | Oh My Theme can add its reviewed include and managed fragment during batch setup and update the managed fragment on later applies. | Ghostty documents explicit runtime reload. Ghostty 1.3 adds a `perform action` AppleScript command, but macOS protects app-to-app automation with an Automation prompt. Without that consent, report the documented reload shortcut as the remaining action. | [Ghostty configuration and reload](https://ghostty.org/docs/config), [Ghostty AppleScript](https://ghostty.org/docs/features/applescript), [current Ghostty plan](../../Packages/OhMyThemeKit/Sources/ThemeEngine/GhosttyConfigurationAdapter.swift#L490-L516) |
| Visual Studio Code | The batch can install the pinned companion through VS Code’s documented CLI, then the companion can update and verify `workbench.colorTheme` through the extension API. | The selected VS Code edition and profile must be explicit. A running companion registration is needed for current-window acknowledgement, and more specific workspace settings may override the requested global value. | [VS Code CLI extension installation](https://code.visualstudio.com/docs/configure/command-line#_working-with-extensions), [VS Code `WorkspaceConfiguration.update`](https://code.visualstudio.com/api/references/vscode-api#WorkspaceConfiguration), [current connection plan](../../Packages/OhMyThemeKit/Sources/Adapters/VSCodeConnectionAdapter.swift#L733-L830), [companion proof](./vscode-companion-proof.md#L5-L23) |
| Starship | The batch can register the selected config and later update the owned palette and `palette` key. | No running GUI needs approval. Changes appear at the next prompt, and hard-coded module colors can remain unchanged. Linked dotfile sources and Nix ownership require review or refusal. | [Starship configuration](https://starship.rs/config/), [current connection behavior](../../Packages/OhMyThemeKit/Sources/ThemeEngine/StarshipConfigurationAdapter.swift#L266-L362), [format-preservation proof](./starship-format-preservation-proof.md#L5-L46) |

### Inference

All currently exposed connection candidates can participate in one setup batch. The batch will not eliminate native consent prompts or target-specific activation limits. It can eliminate repeated navigation, repeated Oh My Theme confirmation screens, and repeated apply commands.

## Permissions, security, and consent boundaries

### Sourced facts

- A macOS app that sends Apple events to control another app needs `NSAppleEventsUsageDescription`; with Hardened Runtime, the Apple Events entitlement allows it to prompt for permission. The user can allow or deny control and later change that choice in System Settings. [Apple usage-description key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription), [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events), [Apple Automation settings](https://support.apple.com/guide/mac-help/allow-apps-to-automate-and-control-other-apps-mchl108e1718/mac)
- A sandboxed Mac app can gain access to user-selected files or folders through standard open and save panels. It can retain access across launches with security-scoped bookmarks. A selected folder extends access to its descendants, subject to normal permissions and other platform protections. [Apple sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), [Apple `NSOpenPanel`](https://developer.apple.com/documentation/appkit/nsopenpanel)
- App Sandbox is required for Mac App Store distribution. The repository currently specifies direct distribution with App Sandbox disabled. [Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox), [current technical stack](../architecture/technical-stack.md#L7-L18)
- The current architecture forbids privileged helpers, `sudo`, private preference writes, app-database edits, process killing as an undocumented reload mechanism, and GUI input simulation. [MVP boundaries](../architecture/mvp-plan.md#L33-L47), [single-writer rules](../architecture/mvp-plan.md#L242-L265)

### Recommendations

1. Ask for product consent once per selected setup batch, after showing exact changes. Do not require a separate Oh My Theme confirmation for each uncomplicated target.
2. Trigger macOS permission prompts just in time while the relevant target row is visible in setup progress. A denied prompt should fail only that capability.
3. Never use Accessibility permission to click target-app UI. Keep unsupported targets unavailable or manual rather than broadening access to simulate input.
4. Keep direct distribution and no sandbox for the first redesigned release unless distribution strategy changes. If a sandboxed build is introduced, add narrow folder pickers and security-scoped bookmarks per configuration root instead of requesting Full Disk Access.
5. Treat extension installation, linked dotfile edits, and taking ownership of an existing key as meaningful side effects in the aggregate review even when macOS does not display a system permission prompt.
6. Keep Launch at Login and menu bar visibility independent, reversible preferences. If login-item registration requires approval, link directly to the system panel through `SMAppService`. [Apple `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice)
7. Keep logs structural. Record operation identifiers, adapter and phase, outcome codes, and timings, but not baseline file bytes, paths unless needed for a user-visible report, or secrets. Apple’s unified logging API supports structured runtime logging, and the repository already prohibits baseline bytes in logs. [Apple Logging](https://developer.apple.com/documentation/os/logging), [persistence rules](../architecture/technical-stack.md#L36-L62)

## Batch setup and apply architecture

### Sourced facts

The existing engine already enforces one mutation operation at a time, persists all apply plans before the first external mutation, executes target plans in deterministic order, revalidates writable targets at the write boundary, continues after target-specific failures, and returns separate outcomes. [Runtime and concurrency](../architecture/technical-stack.md#L20-L34), [durable apply implementation](../../Packages/OhMyThemeKit/Sources/ThemeEngine/DurableOperations.swift#L345-L475), [write-boundary handling](../../Packages/OhMyThemeKit/Sources/ThemeEngine/DurableOperations.swift#L478-L585)

The current connection API has the same durable mechanics but handles one instance per operation. [Current connection implementation](../../Packages/OhMyThemeKit/Sources/ThemeEngine/DurableOperations.swift#L68-L340)

### Recommendation: add a setup transaction beside apply

Conceptual API:

```text
prepareSetup(instances, workspace) -> SetupPlan
connect(setupPlanID, workspace) -> SetupReport
```

`SetupPlan` should contain:

- the exact selected target instance IDs;
- one immutable `ConnectionPlan` or preparation failure per instance;
- aggregate side effects and permissions;
- per-instance approval state;
- a digest of the discovery and selection snapshot;
- whether the plan can run without additional user interaction.

`connect` should:

1. Verify that the selected instances, adapter versions, and Workspace still match the preview.
2. Persist the setup operation and every connection plan before mutation.
3. Process plans in `WorkspaceTargetOrder`.
4. Revalidate each plan immediately before mutation.
5. Continue independent instances after denial, conflict, unavailability, or failure.
6. Persist each connection receipt and baseline before moving to the next instance.
7. Return one `SetupReport` grouped by target instance.

Do not implement batch setup as a UI loop around the current single-target `connect`. That would create several unrelated operation IDs, make progress and recovery harder to explain, and leave no durable record of the user’s aggregate action.

### Recommendation: preserve preview safety without forcing two routine clicks

For already connected targets, offer one Apply action. Internally it can still perform prepare then apply.

Auto-continue from prepare to apply only when all of these are true:

- the Workspace and theme assignment remain unchanged;
- every selected connected instance produced a valid plan;
- no plan introduces new setup, permission, or ownership requirements;
- no conflict or unavailable result exists;
- the operation has not started mutating state.

If any condition fails, stop before mutation and open the review screen. This keeps the existing immutable-plan safety rule while making the normal path one action.

## Idempotency, errors, partial success, and rollback

### Sourced facts

- Adapter plans contain intended-change digests, captured pre-change state, stale-state tokens, expected side effects, permissions, and versioned payloads. [Adapter plan](../../Packages/OhMyThemeKit/Sources/ThemeEngine/ThemeEngine.swift#L127-L180)
- The engine treats changed preconditions as conflicts before mutation and records recovery-required states when an adapter cannot prove whether a mutation completed. [Write-boundary and recovery handling](../../Packages/OhMyThemeKit/Sources/ThemeEngine/DurableOperations.swift#L515-L585), [apply error recovery](../../Packages/OhMyThemeKit/Sources/ThemeEngine/DurableOperations.swift#L610-L680)
- Undo operates on the last apply transaction’s per-target records. Guarded rollback refuses to overwrite a state that no longer matches the receipt. [Undo contract](../architecture/mvp-plan.md#L287-L303), [undo implementation](../../Packages/OhMyThemeKit/Sources/ThemeEngine/DurableOperations.swift#L1088-L1156)
- There is no atomic operation shared by macOS and third-party apps. The repository accepts partial application rather than automatically reverting unrelated successes. [Apply transaction contract](../architecture/mvp-plan.md#L225-L240)

### Recommendations

- Reuse the same invariants for setup batches. Preparing twice against unchanged state should produce equivalent intended effects. Connecting an already connected instance should report unchanged rather than duplicate an include, reinstall an identical companion, or replace its baseline.
- Show progress and final status per target with these user-facing states: Waiting, Configuring, Needs Permission, Needs Action, Connected, Unchanged, Conflict, Failed, and Recovery Required.
- A target-specific failure must not stop unrelated targets. Do stop the whole batch before mutation for a global persistence failure, corrupt plan envelope, invalid theme schema, or changed Workspace selection.
- If one adapter mutates and then fails activation, let that adapter attempt its own guarded rollback. Do not automatically roll back targets that succeeded independently.
- After partial setup, offer “Retry remaining” and “Restore connected changes from this setup.” The latter should create a new durable operation and use stored baselines. It must not pretend that the original cross-app operation was atomic.
- Keep “Undo Last Theme Change” separate from “Restore and Disconnect.” The first returns changed targets to their pre-apply values. The second returns one connected target to its original connection baseline and relinquishes ownership. This distinction already exists in the domain model. [Domain recovery definitions](../../CONTEXT.md#L79-L97)
- Never force rollback through an external edit. If current state is neither the captured before-state nor the intended after-state, report a conflict and show the relevant file, scope, or setting for review.

## Recommended phased delivery

### Phase 1: main-window shell

- Add `WindowGroup` as the primary scene.
- Move the existing target, theme, report, undo, and Launch at Login presentation into the proposed information architecture without changing engine behavior.
- Keep `MenuBarExtra`, but reduce it to Workspace health, Open Oh My Theme, and Quit.
- Add a `Settings` scene.

This phase should not change adapters or persistence semantics.

### Phase 2: first-run selection and aggregate review

- Add persisted target opt-in state separate from connected state.
- Add resumable onboarding.
- Add `SetupPlan` that prepares all selected connection plans without mutation.
- Show one aggregate review and one “Configure selected apps” action.

Continue invoking the existing single-target durable connection operation internally only as a temporary UI milestone. Do not call that final batch semantics.

### Phase 3: durable batch connection

- Add one journaled setup operation containing all connection plans and receipts.
- Add deterministic progress, per-target retry, interruption recovery, and a setup report.
- Expose wallpaper display selection and connection, since the adapter exists but the current candidate UI omits it. [Wallpaper adapter](../../Packages/OhMyThemeKit/Sources/ThemeEngine/MacOSWallpaperAdapter.swift#L137-L220), [current runtime target assembly](../../App/OhMyThemeApp/AppComposition/ProductionWorkspaceRuntime.swift#L296-L343)

### Phase 4: routine one-action apply

- Let Apply prepare and auto-continue when no new review condition exists.
- Keep the explicit preview path for first apply, ownership changes, new permissions, conflicts, and advanced inspection.
- Keep menu bar theme actions deferred from the first redesigned release.

### Phase 5: broader adapter work

Add only targets with documented activation paths and the same ownership and recovery guarantees. Existing research identifies automatic or automatic-after-setup paths for kitty, iTerm2, tmux, and several command-line tools, while several GUI apps still lack a supported external selector. [Target ecosystem research](./themeable-app-ecosystem.md#L21-L44), [activation escalation research](./theme-activation-escalation.md#L21-L51)

## Decisions from design review

The design review accepted these first-release boundaries:

- The main window is the canonical interface. Its Dock icon appears while the window is open and disappears when the running app returns to accessory mode.
- The menu bar item is visible by default but optional. Its initial contents are limited to Workspace health, Open Oh My Theme, and Quit.
- Launch at Login is available only while the menu bar item is visible because the first release has no automatic background theme behavior.
- Onboarding is resumable and may be deferred. It asks the user to choose a theme, explicitly select Target Instances, review one Setup Plan, run one Setup Transaction, and then invoke a separate Apply action.
- Discovery selects nothing automatically. Select All Recommended uses a stable-adapter allowlist plus runtime safety checks and never includes ambiguous, conflicting, experimental, or unavailable instances.
- The Apps interface groups multiple instances under each application. One macOS group keeps System Appearance and each wallpaper display independently selectable.
- Setup and Apply run as durable, sequential, partial-success transactions. Cancel Remaining finishes the current target boundary and skips untouched targets.
- Known conflicts, changed ownership, new permission requirements, and ambiguous targets stop Apply before mutation. Previously acknowledged unavailability and documented reload or restart requirements do not repeatedly interrupt routine Apply.
- The desired Theme Assignment persists separately from timestamped per-target applied state. Visual Theme Preview does not mutate targets; pressing Apply creates a fresh Apply Plan.
- The first release uses one internal Workspace presented as My Mac, one reusable main window, and Overview, Themes, and Apps sections. Persistent Activity history is deferred.
- Existing users keep their Workspace and Connection Baselines. Newly supported targets appear as opt-in configuration opportunities and are never connected automatically.
- The redesigned release includes stable macOS Appearance, macOS Wallpaper, Ghostty, VS Code, and Starship support. Later adapters do not block it.

Deferred work includes multiple user-visible Workspaces, per-target theme overrides, live external preview, automatic Light/Dark pair switching, richer menu bar theme commands, persistent Activity history, and optional Ghostty AppleScript activation. App Sandbox remains outside the direct-distribution release.

## Decision summary

**Recommendation:** Proceed with the dedicated main app. The menu bar should become a shortcut, not the configuration console.

The backend direction is already aligned with this UX. Keep the Workspace as the selected set of connected target instances and keep adapters responsible for discovery, preparation, mutation, verification, rollback, and recovery. Add one durable setup transaction above the existing connection plans, then let routine Apply prepare and continue from one user action when no new consent, setup, or conflict requires review.

This direction reduces repeated product interactions without weakening macOS consent, target-owned security boundaries, configuration ownership, or the repository’s honest partial-success model.