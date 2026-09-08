import Foundation
import ThemeEngine
import ThemeModel
import XCTest

@testable import OhMyTheme

/// Tests for the Workspace state and actions presented by the main window.
@MainActor
final class WorkspacePresentationModelTests: XCTestCase {
    func testWorkspacePresentsTheMyMacWorkspace() {
        let model = WorkspacePresentationModel(runtime: FakeWorkspaceRuntime(workspace: .myMac))

        XCTAssertEqual(model.workspaceName, "My Mac")
    }

    func testWorkspaceExplainsThatNothingIsConnectedYet() throws {
        let model = WorkspacePresentationModel(runtime: FakeWorkspaceRuntime(workspace: .myMac))

        let message = try XCTUnwrap(model.emptyStateMessage)
        XCTAssertTrue(message.contains("No Targets are connected yet"))
        XCTAssertTrue(model.connectedTargetInstanceNames.isEmpty)
    }

    func testWorkspaceGroupsConnectedInstancesAtTheApplicationLevel() {
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

        let model = WorkspacePresentationModel(runtime: FakeWorkspaceRuntime(workspace: workspace))

        XCTAssertNil(model.emptyStateMessage)
        XCTAssertEqual(model.applicationTargets.map(\.name), ["Ghostty", "Visual Studio Code"])
        XCTAssertTrue(model.applicationTargets.allSatisfy { !$0.showsInstanceDetails })
    }

    func testUnambiguousSetupHidesInstanceDetailButKeepsPermissionDisclosure() {
        let option = WorkspacePresentationModel.ConnectionOption(
            id: TargetInstanceID(rawValue: "macos.system-appearance"),
            name: "System Appearance",
            detail: "/internal/target/path",
            permissionDisclosure: "Allow Automation control of System Events."
        )
        let target = WorkspacePresentationModel.ApplicationTarget(
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

    func testWorkspaceListsBundledThemeVariantsWithProvenance() throws {
        let packs = try BundledThemeCatalog().load()
        let model = WorkspacePresentationModel(
            runtime: FakeWorkspaceRuntime(workspace: .myMac, themePacks: packs)
        )

        XCTAssertEqual(
            model.bundledThemeVariants.map(\.name),
            ["Catppuccin Mocha", "Oh My Theme Aurora"]
        )
        XCTAssertEqual(
            model.bundledThemeVariants.map { $0.source.type.rawValue },
            ["upstream", "generated"]
        )
        XCTAssertTrue(
            model.bundledThemeVariants.allSatisfy {
                !$0.source.revision.isEmpty && !$0.source.attribution.isEmpty
            }
        )
        XCTAssertTrue(
            model.bundledThemeVariants.allSatisfy {
                $0.preview.color(for: .canvas).rawValue.hasPrefix("#")
            }
        )
        XCTAssertTrue(model.bundledThemeVariants.allSatisfy { $0.preview.source == $0.source })
    }

    func testWorkspaceRequestsApplyPlanThroughRuntime() async throws {
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
        let model = WorkspacePresentationModel(
            runtime: runtime,
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
        let model = WorkspacePresentationModel(
            runtime: runtime,
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
        let model = WorkspacePresentationModel(
            runtime: runtime,
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
        let model = WorkspacePresentationModel(runtime: runtime)
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
        let model = WorkspacePresentationModel(runtime: FakeWorkspaceRuntime(workspace: workspace))
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
        let model = WorkspacePresentationModel(runtime: FakeWorkspaceRuntime(workspace: workspace))
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
                            detail:
                                "Turn on Automation for Oh My Theme in System Settings > Privacy & Security > Automation."
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
        let model = WorkspacePresentationModel(runtime: FakeWorkspaceRuntime(workspace: workspace))
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

        XCTAssertEqual(report.sectionTitle, "Latest Apply Report")
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
        let model = WorkspacePresentationModel(runtime: FakeWorkspaceRuntime(workspace: workspace))
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

    func testPartialSetupPresentationDistinguishesOutcomes() {
        let targets = (1...7).map { i in
            ConnectedTargetInstance(
                id: TargetInstanceID(rawValue: "target-\(i)"),
                displayName: "Target \(i)",
                adapterID: "adapter-\(i)"
            )
        }
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: targets
        )
        let model = WorkspacePresentationModel(runtime: FakeWorkspaceRuntime(workspace: workspace))

        let outcomes = [
            TargetCapabilityOutcome(
                targetInstanceID: targets[0].id,
                adapterID: targets[0].adapterID,
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .updated,
                runningInstanceReach: .currentInstances
            ),
            TargetCapabilityOutcome(
                targetInstanceID: targets[1].id,
                adapterID: targets[1].adapterID,
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .unchanged,
                runningInstanceReach: .currentInstances
            ),
            TargetCapabilityOutcome(
                targetInstanceID: targets[2].id,
                adapterID: targets[2].adapterID,
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .permissionRequired,
                runningInstanceReach: .unavailable
            ),
            TargetCapabilityOutcome(
                targetInstanceID: targets[3].id,
                adapterID: targets[3].adapterID,
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .conflicted,
                runningInstanceReach: .unavailable
            ),
            TargetCapabilityOutcome(
                targetInstanceID: targets[4].id,
                adapterID: targets[4].adapterID,
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .failed,
                runningInstanceReach: .unavailable
            ),
            TargetCapabilityOutcome(
                targetInstanceID: targets[5].id,
                adapterID: targets[5].adapterID,
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .unavailable,
                runningInstanceReach: .unavailable
            ),
            TargetCapabilityOutcome(
                targetInstanceID: targets[6].id,
                adapterID: targets[6].adapterID,
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .failed,
                runningInstanceReach: .unavailable,
                rollbackState: .recoveryRequired
            ),
        ]

        let report = model.present(outcomes: outcomes, kind: .setup)

        XCTAssertEqual(report.sectionTitle, "Latest Setup Report")
        XCTAssertEqual(report.title, "Setup complete with remaining work")
        XCTAssertEqual(report.groups.count, 7)

        let configurations = report.groups.compactMap { $0.outcomes.first?.configuration }
        XCTAssertEqual(
            configurations,
            [
                "Connected",
                "Already set",
                "Permission required",
                "Conflict",
                "Failed",
                "Unavailable",
                "Recovery required",
            ])
    }

    func testWorkspaceRestoresAndPersistsTheSelectedFixedThemeVariant() {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            themeAssignment: .fixed(variantID: "aurora/light")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let model = WorkspacePresentationModel(
            runtime: runtime,
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
        let model = WorkspacePresentationModel(runtime: runtime)

        try await model.restoreAndDisconnect(instance.id)

        XCTAssertEqual(runtime.disconnectCalls, 1)
        XCTAssertEqual(model.report?.kind, .disconnect)
        XCTAssertEqual(model.report?.title, "Target restored and disconnected")
        XCTAssertTrue(model.workspace.connectedTargetInstances.isEmpty)
    }

    func testStartingPresentationDoesNotChangeThemeAssignment() async {
        let runtime = FakeWorkspaceRuntime(
            workspace: Workspace(
                id: .myMac,
                displayName: "My Mac",
                themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
            )
        )
        let model = WorkspacePresentationModel(runtime: runtime)

        await model.start()

        XCTAssertEqual(model.selectedThemeVariantID, "oh-my-theme/aurora")
    }

    func testSelectingThemeVariantUpdatesPreviewWithoutPreparingApplyPlanOrMutatingTargets() throws {
        let packs = try BundledThemeCatalog().load()
        let target = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "ghostty.test"),
            displayName: "Ghostty",
            adapterID: "ghostty"
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [target],
            themeAssignment: .fixed(variantID: "catppuccin/mocha")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspacePresentationModel(runtime: runtime)

        XCTAssertEqual(model.selectedThemeVariantID, "catppuccin/mocha")
        XCTAssertEqual(model.selectedThemePreview?.variantID, "catppuccin/mocha")
        XCTAssertNil(model.applyPlan)
        XCTAssertEqual(runtime.prepareCalls, 0)

        model.selectThemeVariant("oh-my-theme/aurora")

        XCTAssertEqual(model.selectedThemeVariantID, "oh-my-theme/aurora")
        XCTAssertEqual(model.selectedThemePreview?.variantID, "oh-my-theme/aurora")
        XCTAssertNil(model.applyPlan)
        XCTAssertEqual(runtime.prepareCalls, 0)
        XCTAssertEqual(runtime.workspace.connectedTargetInstances.count, 1)
        XCTAssertEqual(runtime.workspace.connectedTargetInstances.first?.id, target.id)
    }

    func testOverviewDescribesDesiredSelectionWithoutClaimingAppliedState() throws {
        let packs = try BundledThemeCatalog().load()
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "ghostty.test"),
                    displayName: "Ghostty",
                    adapterID: "ghostty"
                )
            ],
            themeAssignment: .fixed(variantID: "catppuccin/mocha")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspacePresentationModel(runtime: runtime)

        XCTAssertEqual(model.desiredThemeTitle, "Catppuccin Mocha")
        XCTAssertEqual(model.desiredThemeStatus, "Desired")
        XCTAssertTrue(model.desiredThemeExplanation.contains("saved separately from Target outcomes"))
    }

    func testExistingStoredAppearancePairIsPreservedButHiddenFromFirstReleaseInterface() throws {
        let packs = try BundledThemeCatalog().load()
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [],
            themeAssignment: .appearancePair(
                lightVariantID: "catppuccin/mocha",
                darkVariantID: "oh-my-theme/aurora"
            )
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspacePresentationModel(runtime: runtime)

        guard case .appearancePair(let light, let dark) = model.workspace.themeAssignment else {
            XCTFail("Expected .appearancePair")
            return
        }
        XCTAssertEqual(light, "catppuccin/mocha")
        XCTAssertEqual(dark, "oh-my-theme/aurora")

        XCTAssertNil(model.selectedThemeVariantID)
        XCTAssertNil(model.selectedThemePreview)
        XCTAssertEqual(model.desiredThemeTitle, "Choose a fixed Theme Variant")
        XCTAssertEqual(model.desiredThemeStatus, "Selection required")
        XCTAssertFalse(model.desiredThemeTitle.contains("Light"))
        XCTAssertFalse(model.desiredThemeTitle.contains("Dark"))

        model.selectThemeVariant("catppuccin/mocha")
        XCTAssertEqual(model.selectedThemeVariantID, "catppuccin/mocha")
        XCTAssertEqual(model.desiredThemeStatus, "Desired")
    }

    func testOptInAndRecommendationCapabilities() async throws {
        let recInstanceID = TargetInstanceID(rawValue: "ghostty.default")
        let nonRecInstanceID = TargetInstanceID(rawValue: "custom.default")

        let recItem = WorkspacePresentationModel.TargetInstanceItem(
            id: recInstanceID,
            displayName: "Ghostty",
            adapterID: "ghostty",
            managementState: .notSelected,
            isOptedIn: false,
            isConnected: false,
            isRecommended: true
        )
        let nonRecItem = WorkspacePresentationModel.TargetInstanceItem(
            id: nonRecInstanceID,
            displayName: "Custom",
            adapterID: "custom",
            managementState: .notSelected,
            isOptedIn: false,
            isConnected: false,
            isRecommended: false,
            exclusionReason: .nonAllowlisted,
            exclusionDetail: "Not allowlisted"
        )

        let appTarget = WorkspacePresentationModel.ApplicationTarget(
            id: "ghostty",
            name: "Ghostty",
            systemImage: "terminal",
            state: .notSelected,
            summary: "Terminal",
            instanceDetails: [],
            connectionOptions: [],
            instances: [recItem, nonRecItem]
        )

        let runtime = FakeWorkspaceRuntime()
        let model = WorkspacePresentationModel(runtime: runtime)
        model.replaceWorkspace(runtime.workspace, targets: [appTarget])

        XCTAssertTrue(model.hasRecommendedTargets)
        XCTAssertTrue(model.canSelectAllRecommended)
        XCTAssertTrue(appTarget.hasRecommendedInstances)
        XCTAssertTrue(appTarget.canSelectRecommended)
        XCTAssertFalse(appTarget.allRecommendedOptedIn)

        runtime.refreshTargetsResult = WorkspaceTargetSnapshot(
            workspace: runtime.workspace,
            targets: [appTarget]
        )
        try await model.refreshTargets()
        XCTAssertEqual(runtime.refreshTargetsCalls, 1)

        try await model.setTargetOptIn(recInstanceID, isOptedIn: true)
        XCTAssertEqual(runtime.setTargetOptInCalls.count, 1)
        XCTAssertEqual(runtime.setTargetOptInCalls.first?.instanceID, recInstanceID)
        XCTAssertEqual(runtime.setTargetOptInCalls.first?.isOptedIn, true)

        try await model.selectAllRecommended()
        XCTAssertEqual(runtime.selectAllRecommendedCalls, 1)

        try await model.selectRecommended(for: "ghostty")
        XCTAssertEqual(runtime.selectRecommendedCalls, ["ghostty"])
    }

    func testExclusionReasonPresentationInTargetInstances() {
        let item = WorkspacePresentationModel.TargetInstanceItem(
            id: TargetInstanceID(rawValue: "vscode.ambiguous"),
            displayName: "VS Code",
            adapterID: "vscode",
            managementState: .notSelected,
            isOptedIn: false,
            isConnected: false,
            isRecommended: false,
            exclusionReason: .ambiguous,
            exclusionDetail: "Multiple installations found"
        )

        XCTAssertFalse(item.isRecommended)
        XCTAssertEqual(item.exclusionReason, .ambiguous)
        XCTAssertEqual(item.exclusionDetail, "Multiple installations found")
    }

    func testSetupPlanReviewFlowAndInvalidation() async throws {
        let instanceID = TargetInstanceID(rawValue: "ghostty.default")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [],
            targetOptIns: [instanceID]
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let model = WorkspacePresentationModel(runtime: runtime)

        XCTAssertTrue(model.canReviewSetupPlan)
        XCTAssertEqual(model.unresolvedOptedInCount, 1)
        XCTAssertNil(model.setupPlan)

        // Prepare setup plan
        try await model.prepareSetupPlan()
        XCTAssertEqual(runtime.prepareSetupPlanCalls, 1)
        XCTAssertNotNil(model.setupPlan)
        XCTAssertFalse(model.isSetupPlanInvalidated)

        // Test confirmSetupPlan when valid
        let confirmedValid = await model.confirmSetupPlan()
        XCTAssertTrue(confirmedValid)
        XCTAssertFalse(model.isSetupPlanInvalidated)

        // Invalidate by opting out
        try await model.setTargetOptIn(instanceID, isOptedIn: false)
        XCTAssertTrue(model.isSetupPlanInvalidated)
        XCTAssertNotNil(model.setupPlanInvalidationReason)

        // Returning to the original selection does not revive an invalidated reviewed plan.
        try await model.setTargetOptIn(instanceID, isOptedIn: true)
        await model.revalidateSetupPlan()
        XCTAssertTrue(model.isSetupPlanInvalidated)

        // Test confirmSetupPlan when invalidated
        let confirmedInvalid = await model.confirmSetupPlan()
        XCTAssertFalse(confirmedInvalid)
        XCTAssertTrue(model.isSetupPlanInvalidated)

        // Preparing a replacement plan is the only way to clear invalidation.
        await model.prepareSetupPlan()
        XCTAssertFalse(model.isSetupPlanInvalidated)

        // Dismiss setup plan
        model.dismissSetupPlan()
        XCTAssertNil(model.setupPlan)
        XCTAssertNil(model.setupPlanInvalidationReason)
    }

    func testExecuteSetupPlanPresentsReportAndRefreshesWorkspace() async throws {
        let instanceID = TargetInstanceID(rawValue: "ghostty.default")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [],
            targetOptIns: [instanceID]
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let model = WorkspacePresentationModel(runtime: runtime)

        await model.prepareSetupPlan()
        XCTAssertNotNil(model.setupPlan)

        let connectedInstance = ConnectedTargetInstance(
            id: instanceID,
            displayName: "Ghostty",
            adapterID: "ghostty"
        )
        let outcome = TargetCapabilityOutcome(
            targetInstanceID: instanceID,
            adapterID: "ghostty",
            capabilityID: "connection",
            sourceType: .generated,
            sourceRevision: "1",
            configurationState: .updated,
            runningInstanceReach: .reloadRequired,
            detail: "Configured Ghostty",
            rollbackState: .notNeeded
        )
        let setupReport = SetupReport(
            operationID: UUID(),
            outcomes: [outcome]
        )
        let updatedWorkspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [connectedInstance],
            targetOptIns: [instanceID]
        )
        runtime.executeSetupPlanResult = WorkspaceSetupResult(
            snapshot: WorkspaceTargetSnapshot(workspace: updatedWorkspace, targets: []),
            report: setupReport
        )

        let returnedReport = try await model.executeSetupPlan()

        XCTAssertEqual(returnedReport?.operationID, setupReport.operationID)
        XCTAssertEqual(runtime.executeSetupPlanCalls.count, 1)
        XCTAssertNil(model.setupPlan)
        XCTAssertNil(model.setupProgress)
        XCTAssertFalse(model.isExecutingSetup)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.report?.kind, .setup)
        XCTAssertEqual(model.report?.title, "Setup complete")
        XCTAssertEqual(model.workspace.connectedTargetInstances.map(\.id), [instanceID])
    }

    func testRetryRemainingSetupPreparesFreshPlanLinkedToLatestSetupReport() async throws {
        let instanceID = TargetInstanceID(rawValue: "ghostty.default")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [],
            targetOptIns: [instanceID]
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let model = WorkspacePresentationModel(runtime: runtime)
        let failedReport = SetupReport(
            operationID: UUID(),
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: instanceID,
                    adapterID: "ghostty",
                    capabilityID: "connection",
                    sourceType: .unavailable,
                    sourceRevision: "n/a",
                    configurationState: .failed,
                    runningInstanceReach: .unavailable,
                    detail: "Connection failed."
                )
            ]
        )
        runtime.executeSetupPlanResult = WorkspaceSetupResult(
            snapshot: WorkspaceTargetSnapshot(workspace: workspace, targets: []),
            report: failedReport
        )

        await model.prepareSetupPlan()
        _ = try await model.executeSetupPlan()
        await model.retryRemainingSetup()

        XCTAssertEqual(runtime.prepareSetupPlanCalls, 2)
        XCTAssertEqual(runtime.prepareSetupPlanRetrySources.last!, failedReport.operationID)
    }

    func testExecuteSetupPlanBlocksConcurrentExecution() async throws {
        let instanceID = TargetInstanceID(rawValue: "ghostty.default")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [],
            targetOptIns: [instanceID]
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let model = WorkspacePresentationModel(runtime: runtime)

        await model.prepareSetupPlan()
        XCTAssertNotNil(model.setupPlan)

        // Simulate busy state
        model.setBusyForTesting(true)
        XCTAssertTrue(model.isBusy)

        let report = try await model.executeSetupPlan()
        XCTAssertNil(report)
        XCTAssertEqual(runtime.executeSetupPlanCalls.count, 0)
    }

    func testClosingWindowLeavesActiveSetupTransactionRunning() async throws {
        let instanceID = TargetInstanceID(rawValue: "ghostty.default")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [],
            targetOptIns: [instanceID]
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let model = WorkspacePresentationModel(runtime: runtime)

        await model.prepareSetupPlan()
        XCTAssertNotNil(model.setupPlan)

        // While setup is executing, window dismiss attempts must not terminate setup
        model.setIsExecutingSetupForTesting(true)
        XCTAssertTrue(model.isExecutingSetup)

        model.dismissSetupPlan()
        XCTAssertNotNil(model.setupPlan)
        XCTAssertTrue(model.isExecutingSetup)

        // Once execution completes, dismissal succeeds
        model.setIsExecutingSetupForTesting(false)
        model.dismissSetupPlan()
        XCTAssertNil(model.setupPlan)
    }

    func testExecuteSetupPlanHandlesCancellationGracefully() async throws {
        let instanceID = TargetInstanceID(rawValue: "ghostty.default")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [],
            targetOptIns: [instanceID]
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        runtime.executeSetupPlanError = DurableOperationError.operationCancelled
        let model = WorkspacePresentationModel(runtime: runtime)

        await model.prepareSetupPlan()
        XCTAssertNotNil(model.setupPlan)

        let report = try await model.executeSetupPlan()
        XCTAssertNil(report)
        XCTAssertFalse(model.isExecutingSetup)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.operationError, "Setup was cancelled.")
    }
}
