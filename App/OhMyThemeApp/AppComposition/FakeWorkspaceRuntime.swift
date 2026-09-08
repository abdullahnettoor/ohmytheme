import Foundation
import PlatformClients
import ThemeEngine
import ThemeModel

@MainActor
final class FakeWorkspaceRuntime: WorkspaceRuntime {
    var workspace: Workspace
    var themePacks: [ThemePack]
    var persistenceError: String?
    var canApplyThemes: Bool

    var startResult: WorkspaceTargetSnapshot?
    var startError: (any Error)?
    var refreshTargetsResult: WorkspaceTargetSnapshot?
    var refreshTargetsError: (any Error)?

    var reviewConnectionResult: ConnectionPlan?
    var reviewConnectionError: (any Error)?

    var connectResult: WorkspaceConnectionResult?
    var connectError: (any Error)?

    var restoreAndDisconnectResult: WorkspaceConnectionResult?
    var restoreAndDisconnectError: (any Error)?

    var setupPlanToReturn: SetupPlan?
    var setupPlanError: (any Error)?
    var setupPlanValidationResult: SetupPlanPreconditionValidation = .valid
    var executeSetupPlanResult: WorkspaceSetupResult?
    var executeSetupPlanError: (any Error)?
    private(set) var executeSetupPlanCalls: [SetupPlan] = []

    var prepareApplyPlanResult: ApplyPlan?
    var prepareApplyPlanError: (any Error)?

    var applyResult: DurableApplyReport?
    var applyError: (any Error)?

    var undoLastResult: UndoReport?
    var undoLastError: (any Error)?

    var undoAvailabilityResult: UndoAvailability

    private(set) var selectVariantCalls: [String] = []
    private(set) var startCalls = 0
    private(set) var refreshTargetsCalls = 0
    private(set) var reviewCalls = 0
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var prepareSetupPlanCalls = 0
    private(set) var prepareSetupPlanRetrySources: [UUID?] = []
    private(set) var validateSetupPlanCalls = 0
    private(set) var cancelRemainingSetupOperationIDs: [UUID] = []
    private(set) var prepareCalls = 0
    private(set) var applyCalls: [UUID] = []
    private(set) var undoCalls = 0
    private(set) var undoAvailabilityCalls = 0
    private(set) var setTargetOptInCalls: [(instanceID: TargetInstanceID, isOptedIn: Bool)] = []
    private(set) var selectAllRecommendedCalls = 0
    private(set) var selectRecommendedCalls: [String] = []

    init(
        workspace: Workspace = .myMac,
        themePacks: [ThemePack] = [],
        persistenceError: String? = nil,
        canApplyThemes: Bool = true,
        undoAvailabilityResult: UndoAvailability = .unavailable
    ) {
        self.workspace = workspace
        self.themePacks = themePacks
        self.persistenceError = persistenceError
        self.canApplyThemes = canApplyThemes
        self.undoAvailabilityResult = undoAvailabilityResult
    }

    func selectFixedThemeVariant(_ variantID: String) {
        selectVariantCalls.append(variantID)
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: workspace.connectedTargetInstances,
            targetOptIns: workspace.targetOptIns,
            themeAssignment: .fixed(variantID: variantID)
        )
    }

    func start() async throws -> WorkspaceTargetSnapshot {
        startCalls += 1
        if let startError {
            throw startError
        }
        if let startResult {
            return startResult
        }
        return WorkspaceTargetSnapshot(
            workspace: workspace,
            targets: defaultTargets(for: workspace)
        )
    }

    func refreshTargets() async throws -> WorkspaceTargetSnapshot {
        refreshTargetsCalls += 1
        if let refreshTargetsError {
            throw refreshTargetsError
        }
        if let refreshTargetsResult {
            workspace = refreshTargetsResult.workspace
            return refreshTargetsResult
        }
        return WorkspaceTargetSnapshot(
            workspace: workspace,
            targets: defaultTargets(for: workspace)
        )
    }

    func reviewConnection(optionID: TargetInstanceID) async throws -> ConnectionPlan {
        reviewCalls += 1
        if let reviewConnectionError {
            throw reviewConnectionError
        }
        if let reviewConnectionResult {
            return reviewConnectionResult
        }
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
        if let connectError {
            throw connectError
        }
        if let connectResult {
            return connectResult
        }
        let instance = ConnectedTargetInstance(
            id: optionID,
            displayName: "Recording",
            adapterID: "recording"
        )
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: workspace.connectedTargetInstances + [instance],
            targetOptIns: workspace.targetOptIns.union([optionID]),
            themeAssignment: workspace.themeAssignment
        )
        return WorkspaceConnectionResult(
            snapshot: WorkspaceTargetSnapshot(
                workspace: workspace,
                targets: defaultTargets(for: workspace)
            ),
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
        if let restoreAndDisconnectError {
            throw restoreAndDisconnectError
        }
        if let restoreAndDisconnectResult {
            return restoreAndDisconnectResult
        }
        var newOptIns = workspace.targetOptIns
        newOptIns.remove(targetInstanceID)
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: workspace.connectedTargetInstances.filter {
                $0.id != targetInstanceID
            },
            targetOptIns: newOptIns,
            themeAssignment: workspace.themeAssignment
        )
        return WorkspaceConnectionResult(
            snapshot: WorkspaceTargetSnapshot(
                workspace: workspace,
                targets: defaultTargets(for: workspace)
            ),
            report: connectionReport(
                targetInstanceID: targetInstanceID,
                capabilityID: "disconnect",
                detail: "Restored and disconnected."
            )
        )
    }

    func prepareSetupPlan(retrySourceOperationID: UUID? = nil) async throws -> SetupPlan {
        prepareSetupPlanCalls += 1
        prepareSetupPlanRetrySources.append(retrySourceOperationID)
        if let setupPlanError {
            throw setupPlanError
        }
        if let setupPlanToReturn {
            return setupPlanToReturn
        }
        let unresolvedIDs = workspace.targetOptIns.filter { !workspace.isConnected($0) }
        return SetupPlan(
            workspaceID: workspace.id,
            targetInstanceIDs: Array(unresolvedIDs),
            targetPlans: [],
            discoveryAndSelectionDigest: "fake-digest",
            retrySourceOperationID: retrySourceOperationID
        )
    }

    func validateSetupPlanPreconditions(_ plan: SetupPlan) async -> SetupPlanPreconditionValidation {
        validateSetupPlanCalls += 1
        let currentUnresolved = Set(workspace.targetOptIns.filter { !workspace.isConnected($0) })
        if currentUnresolved != Set(plan.targetInstanceIDs) {
            return .invalidated(reason: "Target Opt-ins changed since the plan was prepared.")
        }
        return setupPlanValidationResult
    }

    func cancelRemainingSetup(operationID: UUID) async throws {
        cancelRemainingSetupOperationIDs.append(operationID)
    }

    func executeSetupPlan(
        _ plan: SetupPlan,
        onProgress: (@Sendable (SetupProgress) -> Void)? = nil
    ) async throws -> WorkspaceSetupResult {
        executeSetupPlanCalls.append(plan)
        if let executeSetupPlanError {
            throw executeSetupPlanError
        }
        if let executeSetupPlanResult {
            return executeSetupPlanResult
        }
        var newConnected = workspace.connectedTargetInstances
        var outcomes: [TargetCapabilityOutcome] = []
        for targetID in plan.targetInstanceIDs {
            let instance = ConnectedTargetInstance(
                id: targetID,
                displayName: targetID.rawValue,
                adapterID: "recording"
            )
            if !newConnected.contains(where: { $0.id == targetID }) {
                newConnected.append(instance)
            }
            outcomes.append(
                TargetCapabilityOutcome(
                    targetInstanceID: targetID,
                    adapterID: "recording",
                    capabilityID: "connection",
                    sourceType: .unavailable,
                    sourceRevision: "n/a",
                    configurationState: .updated,
                    runningInstanceReach: .currentInstances,
                    detail: "Connected via setup."
                )
            )
        }
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: newConnected,
            targetOptIns: workspace.targetOptIns.union(plan.targetInstanceIDs),
            themeAssignment: workspace.themeAssignment
        )
        return WorkspaceSetupResult(
            snapshot: WorkspaceTargetSnapshot(
                workspace: workspace,
                targets: defaultTargets(for: workspace)
            ),
            report: SetupReport(
                operationID: UUID(),
                outcomes: outcomes
            )
        )
    }

    func prepareApplyPlan() async throws -> ApplyPlan {
        prepareCalls += 1
        if let prepareApplyPlanError {
            throw prepareApplyPlanError
        }
        if let prepareApplyPlanResult {
            return prepareApplyPlanResult
        }
        guard case .fixed(let variantID) = workspace.themeAssignment else {
            throw ThemeEngineError.fixedThemeAssignmentRequired
        }
        let targetPlans: [AdapterPlan] = workspace.connectedTargetInstances.map { instance in
            AdapterPlan(
                targetInstanceID: instance.id,
                adapterID: instance.adapterID,
                adapterVersion: "1",
                capabilityID: "theme",
                payload: AdapterPayloadEnvelope(
                    adapterID: instance.adapterID,
                    adapterVersion: "1",
                    payloadVersion: "1",
                    payload: Data("fake-payload".utf8)
                ),
                intendedChangeDigest: "fake-digest",
                capturedPreChangeState: Data("fake-pre-change".utf8),
                staleStateToken: "token-1",
                expectedSideEffects: [],
                requiredPermissions: [],
                sourceType: .upstream,
                sourceRevision: "1",
                activationReach: .currentInstances,
                setupNeeds: [],
                conflicts: []
            )
        }
        let targetInstanceIDs = targetPlans.map { $0.targetInstanceID }
        return ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: targetInstanceIDs,
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: variantID,
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Fake",
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: targetPlans
        )
    }

    func apply(planID: UUID) async throws -> DurableApplyReport {
        applyCalls.append(planID)
        if let applyError {
            throw applyError
        }
        if let applyResult {
            return applyResult
        }
        let outcomes = workspace.connectedTargetInstances.map { instance in
            TargetCapabilityOutcome(
                targetInstanceID: instance.id,
                adapterID: instance.adapterID,
                capabilityID: "theme",
                sourceType: .upstream,
                sourceRevision: "1",
                configurationState: .updated,
                runningInstanceReach: .currentInstances,
                detail: "Theme applied.",
                rollbackState: .undoAvailable
            )
        }
        let opID = UUID()
        undoAvailabilityResult = .available(sourceOperationID: opID, changedTargetCount: outcomes.count)
        let variantID: String
        if case .fixed(let v) = workspace.themeAssignment {
            variantID = v
        } else {
            variantID = "fake/variant"
        }
        return DurableApplyReport(
            operationID: opID,
            variantID: variantID,
            outcomes: outcomes
        )
    }

    func undoLast() async throws -> UndoReport {
        undoCalls += 1
        if let undoLastError {
            throw undoLastError
        }
        if let undoLastResult {
            return undoLastResult
        }
        let outcomes = workspace.connectedTargetInstances.map { instance in
            TargetCapabilityOutcome(
                targetInstanceID: instance.id,
                adapterID: instance.adapterID,
                capabilityID: "theme",
                sourceType: .upstream,
                sourceRevision: "1",
                configurationState: .updated,
                runningInstanceReach: .currentInstances,
                detail: "Theme change restored.",
                rollbackState: .restored
            )
        }
        undoAvailabilityResult = .unavailable
        return UndoReport(
            operationID: UUID(),
            sourceOperationID: UUID(),
            outcomes: outcomes
        )
    }

    func undoAvailability() async throws -> UndoAvailability {
        undoAvailabilityCalls += 1
        return undoAvailabilityResult
    }

    func setTargetOptIn(
        instanceID: TargetInstanceID,
        isOptedIn: Bool
    ) async throws -> WorkspaceTargetSnapshot {
        setTargetOptInCalls.append((instanceID, isOptedIn))
        var optIns = workspace.targetOptIns
        if isOptedIn {
            optIns.insert(instanceID)
        } else {
            optIns.remove(instanceID)
        }
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: workspace.connectedTargetInstances,
            targetOptIns: optIns,
            themeAssignment: workspace.themeAssignment
        )
        return WorkspaceTargetSnapshot(
            workspace: workspace,
            targets: defaultTargets(for: workspace)
        )
    }

    func selectAllRecommended() async throws -> WorkspaceTargetSnapshot {
        selectAllRecommendedCalls += 1
        let targets = defaultTargets(for: workspace)
        let recommendedIDs = targets.flatMap { $0.instances.filter(\.isRecommended).map(\.id) }
        let optIns = workspace.targetOptIns.union(recommendedIDs)
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: workspace.connectedTargetInstances,
            targetOptIns: optIns,
            themeAssignment: workspace.themeAssignment
        )
        return WorkspaceTargetSnapshot(
            workspace: workspace,
            targets: defaultTargets(for: workspace)
        )
    }

    func selectRecommended(
        applicationID: String
    ) async throws -> WorkspaceTargetSnapshot {
        selectRecommendedCalls.append(applicationID)
        let targets = defaultTargets(for: workspace)
        let target = targets.first { $0.id == applicationID }
        let recommendedIDs = target?.instances.filter(\.isRecommended).map(\.id) ?? []
        let optIns = workspace.targetOptIns.union(recommendedIDs)
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: workspace.connectedTargetInstances,
            targetOptIns: optIns,
            themeAssignment: workspace.themeAssignment
        )
        return WorkspaceTargetSnapshot(
            workspace: workspace,
            targets: defaultTargets(for: workspace)
        )
    }

    private func defaultTargets(for workspace: Workspace) -> [WorkspacePresentationModel.ApplicationTarget] {
        var targets: [WorkspacePresentationModel.ApplicationTarget] = []
        for optInID in workspace.targetOptIns where !workspace.isConnected(optInID) {
            let item = WorkspacePresentationModel.TargetInstanceItem(
                id: optInID,
                displayName: optInID.rawValue,
                adapterID: "fake",
                managementState: .setupNeeded,
                isOptedIn: true,
                isConnected: false,
                isRecommended: true
            )
            targets.append(
                WorkspacePresentationModel.ApplicationTarget(
                    id: optInID.rawValue,
                    name: optInID.rawValue,
                    systemImage: "app",
                    state: .setupNeeded,
                    summary: "Setup Needed",
                    instanceDetails: [optInID.rawValue],
                    connectionOptions: [],
                    instances: [item]
                )
            )
        }
        for instance in workspace.connectedTargetInstances {
            let item = WorkspacePresentationModel.TargetInstanceItem(
                id: instance.id,
                displayName: instance.displayName,
                adapterID: instance.adapterID,
                managementState: .connected,
                isOptedIn: true,
                isConnected: true,
                isRecommended: RecommendedTargetPolicy.isAllowlisted(adapterID: instance.adapterID)
            )
            targets.append(
                WorkspacePresentationModel.ApplicationTarget(
                    id: instance.adapterID,
                    name: instance.displayName,
                    systemImage: "app",
                    state: .connected,
                    summary: "Connected",
                    instanceDetails: [instance.displayName],
                    connectionOptions: [],
                    instances: [item]
                )
            )
        }
        return targets
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
                    sourceType: .generated,
                    sourceRevision: "1",
                    configurationState: .updated,
                    runningInstanceReach: .currentInstances,
                    detail: detail,
                    rollbackState: .undoAvailable
                )
            ]
        )
    }
}
