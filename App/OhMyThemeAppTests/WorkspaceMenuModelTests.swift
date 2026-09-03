import Foundation
import Persistence
import PlatformClients
import ThemeEngine
import ThemeModel
import XCTest

@testable import OhMyTheme

/// Smoke tests for what the menu-bar window presents and offers.
@MainActor
final class WorkspaceMenuModelTests: XCTestCase {
    func testMenuPresentsTheMyMacWorkspace() {
        let model = WorkspaceMenuModel(workspace: WorkspaceStore().workspace, quitAction: {})

        XCTAssertEqual(model.workspaceName, "My Mac")
    }

    func testMenuExplainsThatNothingIsConnectedYet() throws {
        let model = WorkspaceMenuModel(workspace: .myMac, quitAction: {})

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

        let model = WorkspaceMenuModel(workspace: workspace, quitAction: {})

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
        let model = WorkspaceMenuModel(
            workspace: WorkspaceStore().workspace,
            themePacks: try BundledThemeCatalog().load()
        )

        XCTAssertEqual(
            model.bundledThemeVariants.map(\.name),
            ["Catppuccin Mocha", "Oh My Theme Aurora"]
        )
        XCTAssertEqual(model.bundledThemeVariants.map(\.sourceType), ["upstream", "generated"])
        XCTAssertTrue(model.bundledThemeVariants.allSatisfy { !$0.sourceRevision.isEmpty && !$0.attribution.isEmpty })
    }

    func testMenuRequestsPreviewThroughThemeEngine() async throws {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.preview"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ]
        )
        let pack = try XCTUnwrap(try BundledThemeCatalog().load().first)
        let engine = ThemeEngine(packs: [pack], adapters: [RecordingThemeAdapter()])
        let model = WorkspaceMenuModel(
            workspace: workspace,
            themePacks: [pack],
            themeEngine: engine,
            quitAction: {}
        )

        let preview = try await model.prepare(themeVariantID: pack.variants[0].qualifiedID)

        XCTAssertEqual(preview.targetPlans.count, 1)
        XCTAssertEqual(preview.variantID, pack.variants[0].qualifiedID)
    }

    func testChangingThemeSelectionInvalidatesAnExistingPreview() async throws {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.preview-reset"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ],
            themeAssignment: .fixed(variantID: "catppuccin/mocha")
        )
        let packs = try BundledThemeCatalog().load()
        let engine = ThemeEngine(packs: packs, adapters: [RecordingThemeAdapter()])
        let model = WorkspaceMenuModel(
            workspace: workspace,
            themePacks: packs,
            themeEngine: engine,
            quitAction: {}
        )

        _ = try await model.prepareSelectedTheme()
        XCTAssertNotNil(model.preview)

        model.selectThemeVariant("oh-my-theme/aurora")

        XCTAssertNil(model.preview)
        XCTAssertNil(model.report)
    }

    func testDurableApplyAndUndoRemainAvailableAfterAChangedTarget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-menu-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let packs = try BundledThemeCatalog().load()
        let adapter = RecordingWritableAdapter()
        let engine = ThemeEngine(packs: packs, adapters: [adapter], persistence: persistence)
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
        let model = WorkspaceMenuModel(
            workspace: workspace,
            themePacks: packs,
            themeEngine: engine,
            quitAction: {}
        )

        _ = try await model.prepareSelectedTheme()
        _ = try await model.applyPreparedPreview()

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
        let runtime = RecordingWorkspaceRuntime()
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
        let model = WorkspaceMenuModel(workspace: workspace, quitAction: {})
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

        XCTAssertEqual(report.groups[0].outcomes[0].reach, "Reload required")
        XCTAssertEqual(report.groups[0].outcomes[0].userAction, "Reload Ghostty to use the saved theme.")
        XCTAssertEqual(report.groups[1].outcomes[0].reach, "Next prompt")
        XCTAssertEqual(report.groups[1].outcomes[0].userAction, "Start a new prompt to use the saved theme.")
    }

    func testReportNamesPermissionsConflictsFailuresAndNextLaunch() {
        let target = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "recording.states"),
            displayName: "State Target",
            adapterID: "recording"
        )
        let model = WorkspaceMenuModel(
            workspace: Workspace(
                id: .myMac,
                displayName: "My Mac",
                connectedTargetInstances: [target]
            ),
            quitAction: {}
        )
        let states: [ConfigurationState] = [.permissionRequired, .conflicted, .failed]
        let report = model.present(
            outcomes: states.enumerated().map { index, state in
                TargetCapabilityOutcome(
                    targetInstanceID: target.id,
                    adapterID: target.adapterID,
                    capabilityID: "state-\(index)",
                    sourceType: .generated,
                    sourceRevision: "1",
                    configurationState: state,
                    runningInstanceReach: index == 2 ? .newProcessesOnly : .unavailable,
                    detail: "detail",
                    rollbackState: state == .conflicted ? .blocked : .notNeeded,
                    userActions: state == .permissionRequired
                        ? [UserAction(title: "Grant permission", detail: "Use the requested permission action.")]
                        : []
                )
            },
            kind: .apply
        )

        XCTAssertEqual(
            report.groups[0].outcomes.map(\.configuration),
            ["Permission required", "Conflict", "Failed"]
        )
        XCTAssertEqual(report.groups[0].outcomes[2].reach, "Next launch")
        XCTAssertEqual(report.title, "Theme not applied")
        XCTAssertEqual(report.groups[0].outcomes[0].userAction, "Use the requested permission action.")
        XCTAssertEqual(report.groups[0].outcomes[1].rollback, "Restore blocked")
    }

    func testNoChangeApplyUsesAnHonestReportTitle() {
        let target = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "recording.unchanged"),
            displayName: "Unchanged Target",
            adapterID: "recording"
        )
        let model = WorkspaceMenuModel(
            workspace: Workspace(
                id: .myMac,
                displayName: "My Mac",
                connectedTargetInstances: [target]
            ),
            quitAction: {}
        )

        let report = model.present(
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: target.id,
                    adapterID: target.adapterID,
                    capabilityID: "theme",
                    sourceType: .generated,
                    sourceRevision: "1",
                    configurationState: .unchanged,
                    runningInstanceReach: .currentInstances
                )
            ],
            kind: .apply
        )

        XCTAssertEqual(report.title, "Theme already applied")
    }

    func testPartialApplyUsesAnHonestReportTitle() {
        let target = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "recording.partial"),
            displayName: "Partial Target",
            adapterID: "recording"
        )
        let model = WorkspaceMenuModel(
            workspace: Workspace(
                id: .myMac,
                displayName: "My Mac",
                connectedTargetInstances: [target]
            ),
            quitAction: {}
        )

        let report = model.present(
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: target.id,
                    adapterID: target.adapterID,
                    capabilityID: "theme",
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
        var selectedVariantID: String?
        let model = WorkspaceMenuModel(
            workspace: workspace,
            themeVariantSelection: { selectedVariantID = $0 },
            quitAction: {}
        )

        XCTAssertEqual(model.selectedThemeVariantID, "aurora/light")
        model.selectThemeVariant("aurora/dark")

        XCTAssertEqual(selectedVariantID, "aurora/dark")
    }

    func testRestoreAndDisconnectPresentsTheOutcomeAndRemovesTheTarget() async throws {
        let runtime = RecordingWorkspaceRuntime()
        let instance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "recording.disconnect"),
            displayName: "Recording",
            adapterID: "recording"
        )
        runtime.workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [instance]
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
            workspace: WorkspaceStore().workspace,
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
            workspace: WorkspaceStore().workspace,
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
            workspace: WorkspaceStore().workspace,
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
            workspace: WorkspaceStore().workspace,
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
            workspace: WorkspaceStore().workspace,
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
        let runtime = RecordingWorkspaceRuntime()
        runtime.workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            themeAssignment: .fixed(variantID: "oh-my-theme/aurora")
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
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [connectedInstance]
        )
        let launchAtLogin = RecordingLaunchAtLoginClient(status: .enabled)
        var terminationRequests = 0
        let model = WorkspaceMenuModel(
            workspace: workspace,
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

@MainActor
private final class RecordingWorkspaceRuntime: WorkspaceRuntime {
    private(set) var reviewCalls = 0
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0
    var workspace = Workspace.myMac
    let themePacks: [ThemePack] = []
    let themeEngine: ThemeEngine? = nil
    let persistenceError: String? = nil

    func selectFixedThemeVariant(_ variantID: String) {}

    func start() async throws -> WorkspaceTargetSnapshot {
        WorkspaceTargetSnapshot(workspace: workspace, targets: [])
    }

    func reviewConnection(optionID: TargetInstanceID) async throws -> ConnectionPlan {
        reviewCalls += 1
        return ConnectionPlan(
            targetInstanceID: optionID,
            adapterID: "recording",
            adapterVersion: "1",
            capturedPreChangeState: Data("before".utf8),
            intendedChangeDigest: "reviewed",
            expectedSideEffects: ["Record the connection baseline."],
            requiresApproval: true
        )
    }

    func connect(
        optionID: TargetInstanceID,
        reviewedPlan: ConnectionPlan
    ) async throws -> WorkspaceConnectionResult {
        connectCalls += 1
        let instance = ConnectedTargetInstance(
            id: optionID,
            displayName: "Recording",
            adapterID: "recording"
        )
        workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [instance]
        )
        return WorkspaceConnectionResult(
            snapshot: WorkspaceTargetSnapshot(workspace: workspace, targets: []),
            report: connectionReport(
                targetInstanceID: optionID,
                capabilityID: "connection",
                detail: "Connected."
            )
        )
    }

    func restoreAndDisconnect(
        targetInstanceID: TargetInstanceID
    ) async throws -> WorkspaceConnectionResult {
        disconnectCalls += 1
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: workspace.connectedTargetInstances.filter {
                $0.id != targetInstanceID
            },
            themeAssignment: workspace.themeAssignment
        )
        return WorkspaceConnectionResult(
            snapshot: WorkspaceTargetSnapshot(workspace: workspace, targets: []),
            report: connectionReport(
                targetInstanceID: targetInstanceID,
                capabilityID: "disconnect",
                detail: "Restored and disconnected."
            )
        )
    }

    private func connectionReport(
        targetInstanceID: TargetInstanceID,
        capabilityID: String,
        detail: String
    ) -> ConnectionReport {
        ConnectionReport(
            operationID: UUID(),
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: targetInstanceID,
                    adapterID: "recording",
                    capabilityID: capabilityID,
                    sourceType: .unavailable,
                    sourceRevision: "n/a",
                    configurationState: .updated,
                    runningInstanceReach: .currentInstances,
                    detail: detail
                )
            ]
        )
    }
}
