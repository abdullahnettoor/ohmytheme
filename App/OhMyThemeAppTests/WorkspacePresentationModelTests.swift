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
        XCTAssertEqual(report.title, "My Mac is up to date")
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

    func testOverviewReflectsVerifiedWorkspaceThemeStatusAndCounts() {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "ghostty.test"),
                    displayName: "Ghostty",
                    adapterID: "ghostty"
                ),
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "starship.test"),
                    displayName: "Starship",
                    adapterID: "starship"
                ),
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "macos.appearance"),
                    displayName: "macOS Appearance",
                    adapterID: "macos.appearance"
                )
            ]
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let now = Date()
        let outcomes = [
            TargetVerificationOutcome(
                targetInstanceID: TargetInstanceID(rawValue: "ghostty.test"),
                status: .applied,
                verifiedVariantID: "catppuccin/mocha",
                verifiedAt: now
            ),
            TargetVerificationOutcome(
                targetInstanceID: TargetInstanceID(rawValue: "starship.test"),
                status: .pending,
                verifiedAt: now
            ),
            TargetVerificationOutcome(
                targetInstanceID: TargetInstanceID(rawValue: "macos.appearance"),
                status: .needsAttention,
                detail: "System Events permission denied",
                verifiedAt: now
            )
        ]
        runtime.workspaceThemeStatus = WorkspaceThemeStatus(
            timestamp: now,
            desiredThemeAssignment: .fixed(variantID: "catppuccin/mocha"),
            targetOutcomes: outcomes
        )

        let model = WorkspacePresentationModel(runtime: runtime)

        XCTAssertEqual(model.appliedTargetsCount, 1)
        XCTAssertEqual(model.pendingTargetsCount, 1)
        XCTAssertEqual(model.needsAttentionTargetsCount, 1)
        XCTAssertFalse(model.isFullyApplied)
        XCTAssertNotNil(model.workspaceThemeStatus)
    }

    func testOverviewShowsFullyAppliedOnlyWhenAllTargetsApplied() {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "ghostty.test"),
                    displayName: "Ghostty",
                    adapterID: "ghostty"
                )
            ]
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let now = Date()
        let outcomes = [
            TargetVerificationOutcome(
                targetInstanceID: TargetInstanceID(rawValue: "ghostty.test"),
                status: .applied,
                verifiedVariantID: "catppuccin/mocha",
                verifiedAt: now
            )
        ]
        runtime.workspaceThemeStatus = WorkspaceThemeStatus(
            timestamp: now,
            desiredThemeAssignment: .fixed(variantID: "catppuccin/mocha"),
            targetOutcomes: outcomes
        )

        let model = WorkspacePresentationModel(runtime: runtime)

        XCTAssertEqual(model.appliedTargetsCount, 1)
        XCTAssertEqual(model.pendingTargetsCount, 0)
        XCTAssertEqual(model.needsAttentionTargetsCount, 0)
        XCTAssertTrue(model.isFullyApplied)
    }

    func testOverviewPresentsActiveOperationSummaryAndUnresolvedRecovery() {
        let workspace = Workspace.myMac
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        runtime.unresolvedRecovery = "Interrupted transaction needs recovery"

        let model = WorkspacePresentationModel(runtime: runtime)

        XCTAssertEqual(model.unresolvedRecovery, "Interrupted transaction needs recovery")
        XCTAssertNil(model.activeOperationSummary)

        model.setIsApplyingThemeForTesting(true)
        XCTAssertEqual(model.activeOperationSummary, "Applying Theme…")

        model.setIsCancellingRemainingApplyForTesting(true)
        XCTAssertEqual(model.activeOperationSummary, "Cancelling theme application…")

        model.setIsApplyingThemeForTesting(false)
        model.setIsCancellingRemainingApplyForTesting(false)
        model.setIsExecutingSetupForTesting(true)
        XCTAssertEqual(model.activeOperationSummary, "Connecting Targets…")

        model.setIsCancellingRemainingSetupForTesting(true)
        XCTAssertEqual(model.activeOperationSummary, "Cancelling setup…")
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

    func testExecuteSetupPlanPresentsCombinedOutcomesOnRetry() async throws {
        let instance1ID = TargetInstanceID(rawValue: "macos.appearance")
        let instance2ID = TargetInstanceID(rawValue: "ghostty.default")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [],
            targetOptIns: [instance1ID, instance2ID]
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let model = WorkspacePresentationModel(runtime: runtime)

        let priorOperationID = UUID()
        let retryReport = SetupReport(
            operationID: UUID(),
            retrySourceOperationID: priorOperationID,
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: instance2ID,
                    adapterID: "ghostty",
                    capabilityID: "connection",
                    sourceType: .unavailable,
                    sourceRevision: "n/a",
                    configurationState: .updated,
                    runningInstanceReach: .currentInstances,
                    detail: "Connected via retry."
                )
            ],
            combinedOutcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: instance1ID,
                    adapterID: "macos.appearance",
                    capabilityID: "connection",
                    sourceType: .unavailable,
                    sourceRevision: "n/a",
                    configurationState: .updated,
                    runningInstanceReach: .currentInstances,
                    detail: "Connected earlier."
                ),
                TargetCapabilityOutcome(
                    targetInstanceID: instance2ID,
                    adapterID: "ghostty",
                    capabilityID: "connection",
                    sourceType: .unavailable,
                    sourceRevision: "n/a",
                    configurationState: .updated,
                    runningInstanceReach: .currentInstances,
                    detail: "Connected via retry."
                ),
            ]
        )
        runtime.executeSetupPlanResult = WorkspaceSetupResult(
            snapshot: WorkspaceTargetSnapshot(workspace: workspace, targets: []),
            report: retryReport
        )

        await model.prepareSetupPlan(retrySourceOperationID: priorOperationID)
        _ = try await model.executeSetupPlan()

        // Combined outcomes should be presented, showing both target1 and target2
        XCTAssertEqual(model.report?.kind, .setup)
        XCTAssertEqual(model.report?.groups.map(\.id), [instance1ID, instance2ID])
    }

    func testUpdatingInvalidatedRetryPlanPreservesRetrySourceOperationID() async throws {
        let instanceID = TargetInstanceID(rawValue: "ghostty.default")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [],
            targetOptIns: [instanceID]
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace)
        let model = WorkspacePresentationModel(runtime: runtime)

        let retrySourceID = UUID()
        await model.prepareSetupPlan(retrySourceOperationID: retrySourceID)
        XCTAssertEqual(model.setupPlan?.retrySourceOperationID, retrySourceID)

        // Invalidate the retry plan
        try await model.setTargetOptIn(instanceID, isOptedIn: false)
        XCTAssertTrue(model.isSetupPlanInvalidated)

        // Updating/re-preparing the plan preserves the retrySourceOperationID
        await model.prepareSetupPlan(retrySourceOperationID: model.setupPlan?.retrySourceOperationID)
        XCTAssertEqual(runtime.prepareSetupPlanRetrySources.last!, retrySourceID)
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

    // MARK: - Issue #36 One-Action Apply Tests

    func testApplyDesiredThemeExecutesCleanPlanInSingleActionWithoutRoutineConfirmation() async throws {
        let packs = try BundledThemeCatalog().load()
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.instance"),
                    displayName: "Recording",
                    adapterID: "recording"
                )
            ],
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspacePresentationModel(runtime: runtime)

        let report = try await model.applyDesiredTheme()

        XCTAssertNotNil(report)
        XCTAssertEqual(runtime.prepareCalls, 1)
        XCTAssertEqual(runtime.applyCalls.count, 1)
        XCTAssertNil(model.applyPlan, "Clean plan should not pause for confirmation")
        XCTAssertEqual(model.report?.title, "Theme applied")
        XCTAssertTrue(model.canUndoLastThemeChange)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isApplyingTheme)
    }

    func testApplyDesiredThemePreparesFreshPlanAgainstCurrentStateRatherThanBrowsing() async throws {
        let packs = try BundledThemeCatalog().load()
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.instance"),
                    displayName: "Recording",
                    adapterID: "recording"
                )
            ],
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspacePresentationModel(runtime: runtime)

        // Browsing does not prepare plans
        model.selectThemeVariant("oh-my-theme/solarized-dark")
        XCTAssertEqual(runtime.prepareCalls, 0)
        XCTAssertNil(model.applyPlan)

        // Applying prepares fresh against current state
        _ = try await model.applyDesiredTheme()
        XCTAssertEqual(runtime.prepareCalls, 1)
        XCTAssertEqual(runtime.applyCalls.count, 1)
    }

    func testApplyDesiredThemeTargetsEveryConnectedTargetInstanceInEngineOwnedOrder() async throws {
        let packs = try BundledThemeCatalog().load()
        let instances = [
            ConnectedTargetInstance(
                id: TargetInstanceID(rawValue: "starship.prompt"),
                displayName: "Starship",
                adapterID: "starship"
            ),
            ConnectedTargetInstance(
                id: TargetInstanceID(rawValue: "macos.system-appearance"),
                displayName: "macOS",
                adapterID: "macos.appearance"
            ),
            ConnectedTargetInstance(
                id: TargetInstanceID(rawValue: "ghostty.app"),
                displayName: "Ghostty",
                adapterID: "ghostty"
            ),
        ]
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: instances,
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspacePresentationModel(runtime: runtime)

        _ = try await model.applyDesiredTheme()

        let expectedOrder = WorkspaceTargetOrder.ordered(instances).map(\.id)
        XCTAssertEqual(model.report?.groups.map(\.id), expectedOrder)
    }

    func testApplyDesiredThemeDropsAdditionalConcurrentRequests() async throws {
        let packs = try BundledThemeCatalog().load()
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.instance"),
                    displayName: "Recording",
                    adapterID: "recording"
                )
            ],
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspacePresentationModel(runtime: runtime)

        // Simulate busy state
        model.perform {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(model.isBusy)

        // Attempting to apply while busy should be immediately dropped
        let result = try await model.applyDesiredTheme()
        XCTAssertNil(result)
        XCTAssertEqual(runtime.prepareCalls, 0)
        XCTAssertEqual(runtime.applyCalls.count, 0)
    }

    func testApplyDesiredThemeReportsMyMacIsUpToDateAndPreservesUndoWhenUnchanged() async throws {
        let packs = try BundledThemeCatalog().load()
        let targetID = TargetInstanceID(rawValue: "recording.instance")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: targetID,
                    displayName: "Recording",
                    adapterID: "recording"
                )
            ],
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let previousLATOperationID = UUID()
        let runtime = FakeWorkspaceRuntime(
            workspace: workspace,
            themePacks: packs,
            undoAvailabilityResult: .available(sourceOperationID: previousLATOperationID, changedTargetCount: 1)
        )
        // Configure applyResult to return unchanged outcome
        runtime.applyResult = DurableApplyReport(
            operationID: UUID(),
            variantID: "oh-my-theme/aurora",
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: targetID,
                    adapterID: "recording",
                    capabilityID: "theme",
                    sourceType: .upstream,
                    sourceRevision: "1",
                    configurationState: .unchanged,
                    runningInstanceReach: .currentInstances,
                    detail: "Nothing changed"
                )
            ]
        )
        let model = WorkspacePresentationModel(runtime: runtime)

        _ = try await model.applyDesiredTheme()

        XCTAssertEqual(model.report?.title, "My Mac is up to date")
        XCTAssertTrue(model.canUndoLastThemeChange, "Prior LAT is preserved for undo")
        XCTAssertNil(model.applyPlan)
    }

    func testApplyDesiredThemeStopsForReviewWhenPlanHasReviewConditions() async throws {
        let packs = try BundledThemeCatalog().load()
        let targetID = TargetInstanceID(rawValue: "recording.instance")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: targetID,
                    displayName: "Recording",
                    adapterID: "recording"
                )
            ],
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        // Inject a plan with conflicts
        runtime.prepareApplyPlanResult = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [targetID],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "oh-my-theme/aurora",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Fake",
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: ["External edit conflict detected."],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: []
        )
        let model = WorkspacePresentationModel(runtime: runtime)

        let result = try await model.applyDesiredTheme()

        XCTAssertNil(result, "Should not auto-apply when review conditions exist")
        XCTAssertEqual(runtime.applyCalls.count, 0, "Mutation must not occur")
        XCTAssertNotNil(model.applyPlan, "Plan is retained for user review")
        XCTAssertNil(model.report)
    }

    func testPreflightReviewStopsForConflictsOwnershipPermissionsAndAmbiguity() async throws {
        let packs = try BundledThemeCatalog().load()
        let ghosttyID = TargetInstanceID(rawValue: "ghostty.app")
        let macosID = TargetInstanceID(rawValue: "macos.appearance")
        let instances = [
            ConnectedTargetInstance(id: macosID, displayName: "macOS", adapterID: "macos.appearance"),
            ConnectedTargetInstance(id: ghosttyID, displayName: "Ghostty", adapterID: "ghostty")
        ]
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: instances,
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        
        let targetPlans = [
            AdapterPlan(
                targetInstanceID: macosID,
                adapterID: "macos.appearance",
                adapterVersion: "1.0.0",
                capabilityID: "theme",
                payload: AdapterPayloadEnvelope(adapterID: "fake", adapterVersion: "1.0.0", payloadVersion: "1.0.0", payload: Data()),
                intendedChangeDigest: "digest",
                expectedSideEffects: [],
                requiredPermissions: ["Automation control of System Events"],
                sourceType: .upstream,
                sourceRevision: "1",
                activationReach: .currentInstances,
                setupNeeds: [UserAction(title: "Permission needed", detail: "Allow Automation control of System Events.", kind: .permission)],
                conflicts: []
            ),
            AdapterPlan(
                targetInstanceID: ghosttyID,
                adapterID: "ghostty",
                adapterVersion: "1.0.0",
                capabilityID: "theme",
                payload: AdapterPayloadEnvelope(adapterID: "fake", adapterVersion: "1.0.0", payloadVersion: "1.0.0", payload: Data()),
                intendedChangeDigest: "digest",
                expectedSideEffects: ["Update ghostty config"],
                requiredPermissions: [],
                sourceType: .upstream,
                sourceRevision: "1",
                activationReach: .reloadRequired,
                setupNeeds: [],
                conflicts: []
            )
        ]
        
        runtime.prepareApplyPlanResult = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [macosID, ghosttyID],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "oh-my-theme/aurora",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Fake",
            activationReach: .reloadRequired,
            setupNeeds: [UserAction(title: "Permission needed", detail: "Allow Automation control of System Events.", kind: .permission)],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: targetPlans
        )
        
        let model = WorkspacePresentationModel(runtime: runtime)
        
        // 1. Initial Apply stops before mutation
        let result = try await model.applyDesiredTheme()
        XCTAssertNil(result)
        XCTAssertEqual(runtime.applyCalls.count, 0, "No target changes before review resolution")
        XCTAssertNotNil(model.applyPlan)
        
        // 2. Preflight review reasons identify affected targets and explanation
        let reasons = model.applyPlan?.preflightReviewReasons(acknowledgedUnavailableTargets: model.acknowledgedUnavailableTargetInstanceIDs) ?? []
        XCTAssertEqual(reasons.count, 1)
        XCTAssertEqual(reasons.first?.targetInstanceID, macosID)
        XCTAssertEqual(reasons.first?.category, .permission)
        
        let explanation = model.applyPlan?.preflightExplanation(acknowledgedUnavailableTargets: model.acknowledgedUnavailableTargetInstanceIDs)
        XCTAssertNotNil(explanation)
        XCTAssertTrue(explanation!.contains("Automatic Apply paused because"))
        
        // Ready targets list
        XCTAssertEqual(model.applyPlan?.readyTargetInstanceIDs, [ghosttyID])
        
        // 3. Apply to Ready Targets mutates only ready instances and yields honest report
        let appliedReport = try await model.applyPreparedPlan()
        XCTAssertNotNil(appliedReport)
        XCTAssertEqual(runtime.applyCalls.count, 1)
        XCTAssertNil(model.applyPlan)
        XCTAssertEqual(model.report?.title, "Theme applied with remaining work")
        
        // macOS should be permissionRequired, ghostty should be updated
        let macosOutcome = model.report?.groups.first(where: { $0.id == macosID })?.outcomes.first
        XCTAssertEqual(macosOutcome?.configuration, "Permission required")
        let ghosttyOutcome = model.report?.groups.first(where: { $0.id == ghosttyID })?.outcomes.first
        XCTAssertEqual(ghosttyOutcome?.configuration, "Updated")
    }

    func testPreviouslyAcknowledgedUnavailableTargetsDoNotBlockRoutineApply() async throws {
        let packs = try BundledThemeCatalog().load()
        let ghosttyID = TargetInstanceID(rawValue: "ghostty.app")
        let unavailID = TargetInstanceID(rawValue: "unavail.target")
        let instances = [
            ConnectedTargetInstance(id: ghosttyID, displayName: "Ghostty", adapterID: "ghostty"),
            ConnectedTargetInstance(id: unavailID, displayName: "Unavailable Target", adapterID: "unavail")
        ]
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: instances,
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        
        let ghosttyPlan = AdapterPlan(
            targetInstanceID: ghosttyID,
            adapterID: "ghostty",
            adapterVersion: "1.0.0",
            capabilityID: "theme",
            payload: AdapterPayloadEnvelope(adapterID: "fake", adapterVersion: "1.0.0", payloadVersion: "1.0.0", payload: Data()),
            intendedChangeDigest: "digest",
            expectedSideEffects: [],
            requiredPermissions: [],
            sourceType: .upstream,
            sourceRevision: "1",
            activationReach: .reloadRequired,
            setupNeeds: [],
            conflicts: []
        )
        
        runtime.prepareApplyPlanResult = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [ghosttyID, unavailID],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "oh-my-theme/aurora",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Fake",
            activationReach: .reloadRequired,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [unavailID],
            preparationFailures: [],
            userActions: [],
            targetPlans: [ghosttyPlan]
        )
        
        let model = WorkspacePresentationModel(runtime: runtime)
        
        // First apply stops because unavailID is not yet acknowledged
        let firstResult = try await model.applyDesiredTheme()
        XCTAssertNil(firstResult)
        XCTAssertNotNil(model.applyPlan)
        
        // User chooses Apply to ready Targets
        _ = try await model.applyPreparedPlan()
        XCTAssertTrue(model.acknowledgedUnavailableTargetInstanceIDs.contains(unavailID))
        
        // Next routine apply: unavailID is acknowledged, so apply proceeds directly without pausing!
        runtime.prepareApplyPlanResult = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [ghosttyID, unavailID],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "oh-my-theme/aurora",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Fake",
            activationReach: .reloadRequired,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [unavailID],
            preparationFailures: [],
            userActions: [],
            targetPlans: [ghosttyPlan]
        )
        
        let secondResult = try await model.applyDesiredTheme()
        XCTAssertNotNil(secondResult, "Routine Apply should not be blocked by previously acknowledged unavailable target")
        XCTAssertEqual(runtime.applyCalls.count, 2)
    }

    func testDocumentedReachRequirementsDoNotBlockRoutineApply() async throws {
        let packs = try BundledThemeCatalog().load()
        let ghosttyID = TargetInstanceID(rawValue: "ghostty.app")
        let starshipID = TargetInstanceID(rawValue: "starship.prompt")
        let instances = [
            ConnectedTargetInstance(id: ghosttyID, displayName: "Ghostty", adapterID: "ghostty"),
            ConnectedTargetInstance(id: starshipID, displayName: "Starship", adapterID: "starship")
        ]
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: instances,
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        
        runtime.prepareApplyPlanResult = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [ghosttyID, starshipID],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "oh-my-theme/aurora",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Fake",
            activationReach: .reloadRequired,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: [
                AdapterPlan(
                    targetInstanceID: ghosttyID,
                    adapterID: "ghostty",
                    adapterVersion: "1.0.0",
                    capabilityID: "theme",
                    payload: AdapterPayloadEnvelope(adapterID: "fake", adapterVersion: "1.0.0", payloadVersion: "1.0.0", payload: Data()),
                    intendedChangeDigest: "digest",
                    expectedSideEffects: [],
                    requiredPermissions: [],
                    sourceType: .upstream,
                    sourceRevision: "1",
                    activationReach: .reloadRequired,
                    setupNeeds: [],
                    conflicts: []
                ),
                AdapterPlan(
                    targetInstanceID: starshipID,
                    adapterID: "starship",
                    adapterVersion: "1.0.0",
                    capabilityID: "theme",
                    payload: AdapterPayloadEnvelope(adapterID: "fake", adapterVersion: "1.0.0", payloadVersion: "1.0.0", payload: Data()),
                    intendedChangeDigest: "digest",
                    expectedSideEffects: [],
                    requiredPermissions: [],
                    sourceType: .upstream,
                    sourceRevision: "1",
                    activationReach: .nextPrompt,
                    setupNeeds: [],
                    conflicts: []
                )
            ]
        )
        
        let model = WorkspacePresentationModel(runtime: runtime)
        let result = try await model.applyDesiredTheme()
        XCTAssertNotNil(result, "Documented reload/nextPrompt reach must not block routine Apply")
        XCTAssertEqual(runtime.applyCalls.count, 1)
    }

    // MARK: - Issue #38 Apply Cancellation Tests

    func testApplyProgressObservationAndDistinguishingSteps() async throws {
        let packs = try BundledThemeCatalog().load()
        let target1ID = TargetInstanceID(rawValue: "ghostty.app")
        let target2ID = TargetInstanceID(rawValue: "starship.prompt")
        let instances = [
            ConnectedTargetInstance(id: target1ID, displayName: "Ghostty", adapterID: "ghostty"),
            ConnectedTargetInstance(id: target2ID, displayName: "Starship", adapterID: "starship")
        ]
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: instances,
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspacePresentationModel(runtime: runtime)

        let step1 = ApplyProgress.TargetStep(
            targetInstanceID: target1ID,
            displayName: "Ghostty",
            adapterID: "ghostty",
            status: .completed(detail: "Theme applied.")
        )
        let step2 = ApplyProgress.TargetStep(
            targetInstanceID: target2ID,
            displayName: "Starship",
            adapterID: "starship",
            status: .applying,
            currentAction: "Updating starship prompt..."
        )
        let progress = ApplyProgress(
            operationID: UUID(),
            steps: [step1, step2],
            currentTargetID: target2ID
        )

        model.setApplyProgressForTesting(progress)

        XCTAssertEqual(model.applyProgress?.currentTargetID, target2ID)
        XCTAssertEqual(model.applyProgress?.activeStepName, "Starship")
        XCTAssertEqual(model.applyProgress?.completedCount, 1)
        XCTAssertEqual(model.applyProgress?.totalCount, 2)
        XCTAssertFalse(model.applyProgress?.isComplete ?? true)

        let observedStep1 = model.applyProgress?.steps.first(where: { $0.targetInstanceID == target1ID })
        let observedStep2 = model.applyProgress?.steps.first(where: { $0.targetInstanceID == target2ID })
        XCTAssertTrue(observedStep1?.status.isCompleted ?? false)
        XCTAssertFalse(observedStep1?.status.isActive ?? true)
        XCTAssertFalse(observedStep1?.status.isSkipped ?? true)

        XCTAssertFalse(observedStep2?.status.isCompleted ?? true)
        XCTAssertTrue(observedStep2?.status.isActive ?? false)
        XCTAssertFalse(observedStep2?.status.isSkipped ?? true)

        // Now test a skipped step
        let step2Skipped = ApplyProgress.TargetStep(
            targetInstanceID: target2ID,
            displayName: "Starship",
            adapterID: "starship",
            status: .skipped(detail: "Cancelled by user.")
        )
        let skippedProgress = ApplyProgress(
            operationID: progress.operationID,
            steps: [step1, step2Skipped],
            currentTargetID: nil
        )
        model.setApplyProgressForTesting(skippedProgress)

        let observedSkippedStep2 = model.applyProgress?.steps.first(where: { $0.targetInstanceID == target2ID })
        XCTAssertTrue(observedSkippedStep2?.status.isSkipped ?? false)
        XCTAssertFalse(observedSkippedStep2?.status.isActive ?? true)
        XCTAssertFalse(observedSkippedStep2?.status.isCompleted ?? true)
    }

    func testCancelRemainingApplySendsOperationIDToRuntime() async throws {
        let packs = try BundledThemeCatalog().load()
        let targetID = TargetInstanceID(rawValue: "ghostty.app")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(id: targetID, displayName: "Ghostty", adapterID: "ghostty")
            ],
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        let model = WorkspacePresentationModel(runtime: runtime)

        let operationID = UUID()
        let progress = ApplyProgress(
            operationID: operationID,
            steps: [
                ApplyProgress.TargetStep(
                    targetInstanceID: targetID,
                    displayName: "Ghostty",
                    adapterID: "ghostty",
                    status: .applying
                )
            ],
            currentTargetID: targetID
        )

        model.setIsApplyingThemeForTesting(true)
        model.setApplyProgressForTesting(progress)

        await model.cancelRemainingApply()

        XCTAssertEqual(runtime.cancelRemainingApplyOperationIDs, [operationID])
        XCTAssertFalse(model.isCancellingRemainingApply)
    }

    func testApplyCancellationBeforeMutationHandledGracefully() async throws {
        let packs = try BundledThemeCatalog().load()
        let targetID = TargetInstanceID(rawValue: "ghostty.app")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(id: targetID, displayName: "Ghostty", adapterID: "ghostty")
            ],
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        runtime.applyError = DurableOperationError.operationCancelled
        let model = WorkspacePresentationModel(runtime: runtime)

        runtime.prepareApplyPlanResult = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [targetID],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "oh-my-theme/aurora",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Fake",
            activationReach: .reloadRequired,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: [
                AdapterPlan(
                    targetInstanceID: targetID,
                    adapterID: "ghostty",
                    adapterVersion: "1.0.0",
                    capabilityID: "theme",
                    payload: AdapterPayloadEnvelope(adapterID: "ghostty", adapterVersion: "1.0.0", payloadVersion: "1.0.0", payload: Data()),
                    intendedChangeDigest: "digest",
                    expectedSideEffects: [],
                    requiredPermissions: [],
                    sourceType: .upstream,
                    sourceRevision: "1",
                    activationReach: .reloadRequired,
                    setupNeeds: [],
                    conflicts: []
                )
            ]
        )

        try await model.prepareSelectedTheme()
        XCTAssertNotNil(model.applyPlan)

        let report = try await model.applyPreparedPlan()
        XCTAssertNil(report)
        XCTAssertFalse(model.isApplyingTheme)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.applyProgress)
        XCTAssertEqual(model.operationError, "Theme application was cancelled.")
    }

    func testApplyCancellationAfterFirstTargetPresentsCompletedAndSkippedTargets() async throws {
        let packs = try BundledThemeCatalog().load()
        let target1ID = TargetInstanceID(rawValue: "ghostty.app")
        let target2ID = TargetInstanceID(rawValue: "starship.prompt")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(id: target1ID, displayName: "Ghostty", adapterID: "ghostty"),
                ConnectedTargetInstance(id: target2ID, displayName: "Starship", adapterID: "starship")
            ],
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)

        let opID = UUID()
        let cancelledReport = DurableApplyReport(
            operationID: opID,
            variantID: "oh-my-theme/aurora",
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: target1ID,
                    adapterID: "ghostty",
                    capabilityID: "theme",
                    sourceType: .upstream,
                    sourceRevision: "1",
                    configurationState: .updated,
                    runningInstanceReach: .reloadRequired,
                    detail: "Theme applied to Ghostty.",
                    rollbackState: .undoAvailable
                ),
                TargetCapabilityOutcome(
                    targetInstanceID: target2ID,
                    adapterID: "starship",
                    capabilityID: "theme",
                    sourceType: .upstream,
                    sourceRevision: "1",
                    configurationState: .unchanged,
                    runningInstanceReach: .unavailable,
                    detail: "Skipped after Cancel Remaining.",
                    rollbackState: .notNeeded
                )
            ]
        )
        runtime.applyResult = cancelledReport

        let model = WorkspacePresentationModel(runtime: runtime)
        runtime.prepareApplyPlanResult = ApplyPlan(
            id: opID,
            workspaceID: workspace.id,
            targetInstanceIDs: [target1ID, target2ID],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "oh-my-theme/aurora",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Fake",
            activationReach: .reloadRequired,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: []
        )

        try await model.prepareSelectedTheme()
        let report = try await model.applyPreparedPlan()

        XCTAssertNotNil(report)
        XCTAssertEqual(report?.outcomes.count, 2)
        XCTAssertEqual(model.report?.title, "Theme applied with remaining work")

        let ghosttyOutcome = model.report?.groups.first(where: { $0.id == target1ID })?.outcomes.first
        let starshipOutcome = model.report?.groups.first(where: { $0.id == target2ID })?.outcomes.first
        XCTAssertEqual(ghosttyOutcome?.configuration, "Updated")
        XCTAssertEqual(starshipOutcome?.configuration, "Skipped")
    }

    func testApplyDesiredThemeCancellationHandledGracefully() async throws {
        let packs = try BundledThemeCatalog().load()
        let targetID = TargetInstanceID(rawValue: "ghostty.app")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(id: targetID, displayName: "Ghostty", adapterID: "ghostty")
            ],
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
        )
        let ghosttyPlan = AdapterPlan(
            targetInstanceID: targetID,
            adapterID: "ghostty",
            adapterVersion: "1.0.0",
            capabilityID: "theme",
            payload: AdapterPayloadEnvelope(adapterID: "ghostty", adapterVersion: "1.0.0", payloadVersion: "1.0.0", payload: Data()),
            intendedChangeDigest: "digest",
            expectedSideEffects: [],
            requiredPermissions: [],
            sourceType: .upstream,
            sourceRevision: "1",
            activationReach: .reloadRequired,
            setupNeeds: [],
            conflicts: []
        )
        let runtime = FakeWorkspaceRuntime(workspace: workspace, themePacks: packs)
        runtime.applyError = DurableOperationError.operationCancelled
        runtime.prepareApplyPlanResult = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [targetID],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "oh-my-theme/aurora",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Fake",
            activationReach: .reloadRequired,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: [ghosttyPlan]
        )
        let model = WorkspacePresentationModel(runtime: runtime)

        let report = try await model.applyDesiredTheme()
        XCTAssertNil(report)
        XCTAssertFalse(model.isApplyingTheme)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.applyProgress)
        XCTAssertEqual(model.operationError, "Theme application was cancelled.")
    }
}
