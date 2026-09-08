import Foundation
import PlatformClients
import ThemeEngine
import ThemeModel
import XCTest

@testable import OhMyTheme

/// Smoke tests for what the menu-bar window presents and offers.
@MainActor
final class WorkspaceMenuModelTests: XCTestCase {
    func testMenuPresentsTheMyMacWorkspace() {
        let model = WorkspaceMenuModel(runtime: FakeWorkspaceRuntime(workspace: .myMac), quitAction: {})

        XCTAssertEqual(model.workspaceName, "My Mac")
    }

    func testMenuExplainsThatNothingIsConnectedYet() throws {
        let model = WorkspaceMenuModel(runtime: FakeWorkspaceRuntime(workspace: .myMac), quitAction: {})

        let message = try XCTUnwrap(model.emptyStateMessage)
        XCTAssertTrue(message.contains("No Targets are connected yet"))
        XCTAssertTrue(model.connectedTargetInstanceNames.isEmpty)
    }

    func testMenuGroupsConnectedInstancesAtTheApplicationLevel() {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "ghostty.default"),
                    displayName: "Ghostty",
                    adapterID: "ghostty"
                ),
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "vscode.default"),
                    displayName: "Visual Studio Code",
                    adapterID: "vscode"
                ),
            ]
        )

        let model = WorkspaceMenuModel(runtime: FakeWorkspaceRuntime(workspace: workspace), quitAction: {})

        XCTAssertNil(model.emptyStateMessage)
        XCTAssertEqual(model.applicationTargets.map(\.name), ["Ghostty", "Visual Studio Code"])
        XCTAssertTrue(model.applicationTargets.allSatisfy { !$0.showsInstanceDetails })
    }

    func testUnambiguousSetupHidesInstanceDetailButKeepsPermissionDisclosure() {
        let option = WorkspaceMenuModel.ConnectionOption(
            id: TargetInstanceID(rawValue: "macos.system-appearance"),
            name: "System Appearance",
            detail: "/internal/target/path",
            permissionDisclosure: "Allow Automation control of System Events."
        )
        let target = WorkspaceMenuModel.ApplicationTarget(
            id: "macos",
            name: "macOS",
            systemImage: "macbook",
            state: .setupNeeded,
            summary: "Optional appearance setup.",
            instanceDetails: [],
            connectionOptions: [option]
        )

        XCTAssertFalse(target.showsConnectionOptionDetails)
        XCTAssertEqual(option.permissionDisclosure, "Allow Automation control of System Events.")
    }

    func testMenuListsBundledThemeVariantsWithProvenance() throws {
        let packs = try BundledThemeCatalog().load()
        let model = WorkspaceMenuModel(
            runtime: FakeWorkspaceRuntime(workspace: .myMac, themePacks: packs)
        )

        XCTAssertEqual(
            model.bundledThemeVariants.map(\.name),
            ["Catppuccin Mocha", "Oh My Theme Aurora"]
        )
        XCTAssertEqual(model.bundledThemeVariants.map(\.sourceType), ["upstream", "generated"])
        XCTAssertTrue(model.bundledThemeVariants.allSatisfy { !$0.sourceRevision.isEmpty && !$0.attribution.isEmpty })
    }

    func testMenuRequestsApplyPlanThroughRuntime() async throws {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.plan"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ]
        )
        let pack = try XCTUnwrap(try BundledThemeCatalog().load().first)
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: [pack])
        let model = WorkspaceMenuModel(
            runtime: runtime,
            quitAction: {}
        )

        let plan = try await model.prepare(themeVariantID: pack.variants[0].qualifiedID)

        XCTAssertEqual(plan.targetPlans.count, 1)
        XCTAssertEqual(plan.variantID, pack.variants[0].qualifiedID)
        XCTAssertEqual(model.applyPlan?.id, plan.id)
        XCTAssertEqual(runtime.prepareCalls, 1)
    }

    func testChangingThemeSelectionInvalidatesAnExistingApplyPlan() async throws {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.plan-reset"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ],
            themeAssignment: .fixed(variantID: "catppuccin/mocha")
        )
        let packs = try BundledThemeCatalog().load()
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspaceMenuModel(
            runtime: runtime,
            quitAction: {}
        )

        _ = try await model.prepareSelectedTheme()
        XCTAssertNotNil(model.applyPlan)

        model.selectThemeVariant("oh-my-theme/aurora")

        XCTAssertNil(model.applyPlan)
        XCTAssertNil(model.report)
    }

    func testDurableApplyAndUndoRemainAvailableAfterAChangedTarget() async throws {
        let packs = try BundledThemeCatalog().load()
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.menu"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ],
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspaceMenuModel(
            runtime: runtime,
            quitAction: {}
        )

        _ = try await model.prepareSelectedTheme()
        _ = try await model.applyPreparedPlan()

        XCTAssertTrue(model.canUndoLastThemeChange)
        XCTAssertEqual(model.report?.title, "Theme applied")
        XCTAssertEqual(model.report?.groups.first?.outcomes.first?.configuration, "Updated")
        XCTAssertEqual(model.report?.groups.first?.outcomes.first?.reach, "Current windows")
        XCTAssertEqual(model.report?.groups.first?.outcomes.first?.rollback, "Undo available")

        _ = try await model.undoLastThemeChange()

        XCTAssertFalse(model.canUndoLastThemeChange)
        XCTAssertEqual(model.report?.title, "Theme change undone")
        XCTAssertEqual(model.report?.groups.first?.outcomes.first?.rollback, "Restored")
    }

    func testConnectionReviewDoesNotMutateBeforeApproval() async throws {
        let runtime = FakeWorkspaceRuntime()
        let model = WorkspaceMenuModel(runtime: runtime)
        let optionID = TargetInstanceID(rawValue: "recording.review")

        try await model.reviewConnection(optionID)

        XCTAssertEqual(runtime.reviewCalls, 1)
        XCTAssertEqual(runtime.connectCalls, 0)
        XCTAssertEqual(model.connectionReview?.targetInstanceID, optionID)
        XCTAssertEqual(model.approvalRequiredFor, optionID)

        try await model.connect(optionID)

        XCTAssertEqual(runtime.connectCalls, 1)
        XCTAssertNil(model.connectionReview)
        XCTAssertNil(model.approvalRequiredFor)
        XCTAssertEqual(model.workspace.connectedTargetInstances.map(\.id), [optionID])
    }

    func testReportUsesPlainLanguageForRemainingActions() {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "ghostty.default"),
                    displayName: "Ghostty",
                    adapterID: "ghostty"
                ),
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "starship.default"),
                    displayName: "Starship",
                    adapterID: "starship"
                ),
            ]
        )
        let model = WorkspaceMenuModel(runtime: FakeWorkspaceRuntime(workspace: workspace), quitAction: {})
        let report = model.present(
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: TargetInstanceID(rawValue: "ghostty.default"),
                    adapterID: "ghostty",
                    capabilityID: "theme",
                    sourceType: .generated,
                    sourceRevision: "1",
                    configurationState: .updated,
                    runningInstanceReach: .reloadRequired,
                    detail: "Saved the Ghostty fragment.",
                    rollbackState: .undoAvailable,
                    userActions: [
                        UserAction(title: "Reload Ghostty", detail: "Reload Ghostty to use the saved theme.")
                    ]
                ),
                TargetCapabilityOutcome(
                    targetInstanceID: TargetInstanceID(rawValue: "starship.default"),
                    adapterID: "starship",
                    capabilityID: "theme",
                    sourceType: .generated,
                    sourceRevision: "1",
                    configurationState: .updated,
                    runningInstanceReach: .nextPrompt,
                    detail: "Saved registered Starship keys.",
                    rollbackState: .undoAvailable,
                    userActions: [
                        UserAction(title: "Start a new prompt", detail: "Start a new prompt to use the saved theme.")
                    ]
                ),
            ],
            kind: .apply
        )

        XCTAssertEqual(report.title, "Theme applied")
        XCTAssertEqual(report.groups.count, 2)
        XCTAssertEqual(report.groups[0].targetName, "Ghostty")
        XCTAssertEqual(report.groups[0].outcomes[0].configuration, "Updated")
        XCTAssertEqual(report.groups[0].outcomes[0].reach, "Reload required")
        XCTAssertEqual(report.groups[0].outcomes[0].userActions, ["Reload Ghostty to use the saved theme."])
        XCTAssertEqual(report.groups[1].targetName, "Starship")
        XCTAssertEqual(report.groups[1].outcomes[0].reach, "Next prompt")
        XCTAssertEqual(report.groups[1].outcomes[0].userActions, ["Start a new prompt to use the saved theme."])
    }

    func testReportNamesPermissionsConflictsFailuresAndNextLaunch() {
        let target = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "macos.system-appearance"),
            displayName: "macOS",
            adapterID: "macos.appearance"
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [target]
        )
        let model = WorkspaceMenuModel(runtime: FakeWorkspaceRuntime(workspace: workspace), quitAction: {})
        let report = model.present(
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: target.id,
                    adapterID: target.adapterID,
                    capabilityID: "appearance",
                    sourceType: .generated,
                    sourceRevision: "1",
                    configurationState: .permissionRequired,
                    runningInstanceReach: .newProcessesOnly,
                    detail: "Allow Automation control in System Settings.",
                    rollbackState: .undoAvailable,
                    userActions: [
                        UserAction(
                            title: "Open System Settings",
                            detail: "Turn on Automation for Oh My Theme in System Settings > Privacy & Security > Automation."
                        )
                    ]
                )
            ],
            kind: .apply
        )

        XCTAssertEqual(report.title, "Theme not applied")
        XCTAssertEqual(report.groups[0].outcomes[0].capability, "Appearance")
        XCTAssertEqual(report.groups[0].outcomes[0].configuration, "Permission required")
        XCTAssertEqual(report.groups[0].outcomes[0].reach, "Next launch")
        XCTAssertEqual(
            report.groups[0].outcomes[0].userActions,
            ["Turn on Automation for Oh My Theme in System Settings > Privacy & Security > Automation."]
        )
    }

    func testNoChangeApplyUsesAnHonestReportTitle() {
        let target = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "ghostty.default"),
            displayName: "Ghostty",
            adapterID: "ghostty"
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [target]
        )
        let model = WorkspaceMenuModel(runtime: FakeWorkspaceRuntime(workspace: workspace), quitAction: {})
        let report = model.present(
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: target.id,
                    adapterID: target.adapterID,
                    capabilityID: "theme",
                    sourceType: .generated,
                    sourceRevision: "1",
                    configurationState: .unchanged,
                    runningInstanceReach: .currentInstances,
                    rollbackState: .notNeeded
                )
            ],
            kind: .apply
        )

        XCTAssertEqual(report.title, "Theme already applied")
    }

    func testPartialApplyUsesAnHonestReportTitle() {
        let target = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "macos.system-appearance"),
            displayName: "macOS",
            adapterID: "macos.appearance"
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [target]
        )
        let model = WorkspaceMenuModel(runtime: FakeWorkspaceRuntime(workspace: workspace), quitAction: {})
        let report = model.present(
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: target.id,
                    adapterID: target.adapterID,
                    capabilityID: "appearance",
                    sourceType: .generated,
                    sourceRevision: "1",
                    configurationState: .updated,
                    runningInstanceReach: .currentInstances,
                    rollbackState: .undoAvailable
                ),
                TargetCapabilityOutcome(
                    targetInstanceID: target.id,
                    adapterID: target.adapterID,
                    capabilityID: "wallpaper",
                    sourceType: .generated,
                    sourceRevision: "1",
                    configurationState: .failed,
                    runningInstanceReach: .unavailable,
                    detail: "Wallpaper failed."
                ),
            ],
            kind: .apply
        )

        XCTAssertEqual(report.title, "Theme applied with remaining work")
    }

    func testMenuRestoresAndPersistsTheSelectedFixedThemeVariant() {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            themeAssignment: .fixed(variantID: "aurora/light")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let model = WorkspaceMenuModel(
            runtime: runtime,
            quitAction: {}
        )

        XCTAssertEqual(model.selectedThemeVariantID, "aurora/light")
        model.selectThemeVariant("aurora/dark")

        XCTAssertEqual(runtime.selectVariantCalls.last, "aurora/dark")
        XCTAssertEqual(model.selectedThemeVariantID, "aurora/dark")
    }

    func testRestoreAndDisconnectPresentsTheOutcomeAndRemovesTheTarget() async throws {
        let instance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "recording.disconnect"),
            displayName: "Recording",
            adapterID: "recording"
        )
        let runtime = FakeWorkspaceRuntime(
            workspace: Workspace(
                id: .myMac,
                displayName: "My Mac",
                connectedTargetInstances: [instance]
            )
        )
        let model = WorkspaceMenuModel(runtime: runtime)

        try await model.restoreAndDisconnect(instance.id)

        XCTAssertEqual(runtime.disconnectCalls, 1)
        XCTAssertEqual(model.report?.kind, .disconnect)
        XCTAssertEqual(model.report?.title, "Target restored and disconnected")
        XCTAssertTrue(model.workspace.connectedTargetInstances.isEmpty)
    }

    func testLaunchAtLoginIsDisabledUntilTheUserOptsIn() {
        let launchAtLogin = RecordingLaunchAtLoginClient(status: .disabled)
        let model = WorkspaceMenuModel(
            runtime: FakeWorkspaceRuntime(),
            launchAtLogin: launchAtLogin,
            quitAction: {}
        )

        XCTAssertFalse(model.isLaunchAtLoginSelected)
        XCTAssertEqual(model.launchAtLoginStatus, .disabled)
        XCTAssertTrue(launchAtLogin.requests.isEmpty)
    }

    func testMenuExplainsWhenLaunchAtLoginRequiresApproval() {
        let launchAtLogin = RecordingLaunchAtLoginClient(status: .requiresApproval)
        let model = WorkspaceMenuModel(
            runtime: FakeWorkspaceRuntime(),
            launchAtLogin: launchAtLogin,
            quitAction: {}
        )

        XCTAssertTrue(model.isLaunchAtLoginSelected)
        XCTAssertTrue(model.canChangeLaunchAtLogin)
        XCTAssertEqual(
            model.launchAtLoginDetail,
            "Allow Oh My Theme in System Settings > General > Login Items & Extensions."
        )
    }

    func testMenuDisablesUnavailableLaunchAtLogin() {
        let launchAtLogin = RecordingLaunchAtLoginClient(status: .unavailable)
        let model = WorkspaceMenuModel(
            runtime: FakeWorkspaceRuntime(),
            launchAtLogin: launchAtLogin,
            quitAction: {}
        )

        XCTAssertFalse(model.isLaunchAtLoginSelected)
        XCTAssertFalse(model.canChangeLaunchAtLogin)
        XCTAssertEqual(
            model.launchAtLoginDetail,
            "Launch at Login is unavailable for this copy of the app."
        )
    }

    func testMenuCanEnableAndDisableLaunchAtLogin() async {
        let launchAtLogin = RecordingLaunchAtLoginClient(status: .disabled)
        let model = WorkspaceMenuModel(
            runtime: FakeWorkspaceRuntime(),
            launchAtLogin: launchAtLogin,
            quitAction: {}
        )

        await model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(launchAtLogin.requests, [true])
        XCTAssertTrue(model.isLaunchAtLoginSelected)
        XCTAssertEqual(model.launchAtLoginStatus, .enabled)

        await model.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(launchAtLogin.requests, [true, false])
        XCTAssertFalse(model.isLaunchAtLoginSelected)
        XCTAssertEqual(model.launchAtLoginStatus, .disabled)
    }

    func testLaunchAtLoginFailureKeepsTheCurrentStateAndExplainsHowToRetry() async {
        let launchAtLogin = RecordingLaunchAtLoginClient(status: .disabled)
        launchAtLogin.failure = RecordingLaunchAtLoginError.denied
        let model = WorkspaceMenuModel(
            runtime: FakeWorkspaceRuntime(),
            launchAtLogin: launchAtLogin,
            quitAction: {}
        )

        await model.setLaunchAtLoginEnabled(true)

        XCTAssertFalse(model.isLaunchAtLoginSelected)
        XCTAssertEqual(
            model.launchAtLoginError,
            "macOS couldn't update Launch at Login. Registration was denied. Try the toggle again."
        )
    }

    func testStartingTheMenuDoesNotChangeThemeAssignmentOrLaunchAtLogin() async {
        let runtime = FakeWorkspaceRuntime(
            workspace: Workspace(
                id: .myMac,
                displayName: "My Mac",
                themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
            )
        )
        let launchAtLogin = RecordingLaunchAtLoginClient(status: .enabled)
        let model = WorkspaceMenuModel(runtime: runtime, launchAtLogin: launchAtLogin)

        await model.start()

        XCTAssertEqual(model.selectedThemeVariantID, "oh-my-theme/aurora")
        XCTAssertTrue(launchAtLogin.requests.isEmpty)
    }

    func testQuitOnlyAsksTheApplicationToTerminate() {
        let connectedInstance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "ghostty.default"),
            displayName: "Ghostty",
            adapterID: "ghostty"
        )
        let runtime = FakeWorkspaceRuntime(
            workspace: Workspace(
                id: .myMac,
                displayName: "My Mac",
                connectedTargetInstances: [connectedInstance]
            )
        )
        let launchAtLogin = RecordingLaunchAtLoginClient(status: .enabled)
        var terminationRequests = 0
        let model = WorkspaceMenuModel(
            runtime: runtime,
            launchAtLogin: launchAtLogin,
            quitAction: { terminationRequests += 1 }
        )

        model.quit()

        XCTAssertEqual(terminationRequests, 1)
        XCTAssertEqual(model.workspace.connectedTargetInstances, [connectedInstance])
        XCTAssertTrue(launchAtLogin.requests.isEmpty)
    }
}

@MainActor
private final class RecordingLaunchAtLoginClient: LaunchAtLoginPlatform {
    private(set) var requests: [Bool] = []
    var status: LaunchAtLoginStatus
    var failure: (any Error)?

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func setEnabled(_ enabled: Bool) async throws {
        requests.append(enabled)
        if let failure {
            throw failure
        }
        status = enabled ? .enabled : .disabled
    }
}

private enum RecordingLaunchAtLoginError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Registration was denied."
    }
}
