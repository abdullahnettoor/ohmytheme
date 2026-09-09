import Foundation
import Combine
import PlatformClients
import ThemeEngine
import ThemeModel

@MainActor
final class FakeWorkspaceRuntime: WorkspaceRuntime {
    var workspace: Workspace
    var themePacks: [ThemePack]
    var persistenceError: String?
    var canApplyThemes: Bool
    @Published var onboardingDisposition: OnboardingDisposition
    @Published var workspaceThemeStatus: WorkspaceThemeStatus?
    @Published var unresolvedRecovery: String?
    var latestSetupReport: SetupReport?
    var latestApplyReport: DurableApplyReport?

    var workspaceStatusPublisher: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

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

    var reviewDisconnectResult: DisconnectReview?
    var reviewDisconnectError: (any Error)?
    var relinquishResult: WorkspaceRelinquishResult?
    var relinquishError: (any Error)?

    var replacementSuggestions: [ConnectionReplacementSuggestion] = []

    var reviewResetResult: ResetReview?
    var reviewResetError: (any Error)?
    private(set) var reviewResetCalls = 0
    var finalizeResetResult: WorkspaceTargetSnapshot?
    var finalizeResetError: (any Error)?
    private(set) var finalizeResetCalls = 0

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

    var verifyThemeStatusResult: WorkspaceThemeStatus?
    private(set) var verifyThemeStatusCalls = 0

    private(set) var selectVariantCalls: [String] = []
    private(set) var startCalls = 0
    private(set) var refreshTargetsCalls = 0
    private(set) var reviewCalls = 0
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var reviewDisconnectCalls: [TargetInstanceID] = []
    private(set) var relinquishCalls: [TargetInstanceID] = []
    private(set) var prepareSetupPlanCalls = 0
    private(set) var prepareSetupPlanRetrySources: [UUID?] = []
    private(set) var validateSetupPlanCalls = 0
    private(set) var cancelRemainingSetupOperationIDs: [UUID] = []
    private(set) var cancelRemainingApplyOperationIDs: [UUID] = []
    var cancelRemainingApplyHandler: ((UUID) async throws -> Void)?
    var onApplyExecution: ((UUID, (@Sendable (ApplyProgress) -> Void)?) async throws -> DurableApplyReport?)?
    private(set) var prepareCalls = 0
    private(set) var applyCalls: [UUID] = []
    private(set) var applyTargetInstanceIDSets: [Set<TargetInstanceID>?] = []
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
        undoAvailabilityResult: UndoAvailability = .unavailable,
        workspaceThemeStatus: WorkspaceThemeStatus? = nil,
        unresolvedRecovery: String? = nil,
        onboardingDisposition: OnboardingDisposition = .completed
    ) {
        self.workspace = workspace
        self.themePacks = themePacks
        self.persistenceError = persistenceError
        self.canApplyThemes = canApplyThemes
        self.undoAvailabilityResult = undoAvailabilityResult
        self.workspaceThemeStatus = workspaceThemeStatus
        self.unresolvedRecovery = unresolvedRecovery
        self.onboardingDisposition = onboardingDisposition
    }

    private(set) var updateOnboardingDispositionCalls: [OnboardingDisposition] = []
    func updateOnboardingDisposition(_ disposition: OnboardingDisposition) async throws {
        updateOnboardingDispositionCalls.append(disposition)
        onboardingDisposition = disposition
    }

    @discardableResult
    func verifyThemeStatus() async throws -> WorkspaceThemeStatus {
        verifyThemeStatusCalls += 1
        if let verifyThemeStatusResult {
            workspaceThemeStatus = verifyThemeStatusResult
            return verifyThemeStatusResult
        }
        let variantID: String?
        if case .fixed(let v) = workspace.themeAssignment {
            variantID = v
        } else {
            variantID = nil
        }
        let outcomes: [TargetVerificationOutcome] = workspace.connectedTargetInstances.map { instance in
            TargetVerificationOutcome(
                targetInstanceID: instance.id,
                status: .applied,
                detail: nil,
                verifiedVariantID: variantID,
                verifiedAt: Date()
            )
        }
        let status = WorkspaceThemeStatus(
            timestamp: Date(),
            desiredThemeAssignment: workspace.themeAssignment,
            targetOutcomes: outcomes
        )
        workspaceThemeStatus = status
        return status
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
        Task { [weak self] in
            _ = try? await self?.verifyThemeStatus()
        }
    }

    func start() async throws -> WorkspaceTargetSnapshot {
        startCalls += 1
        if let startError {
            throw startError
        }
        _ = try? await verifyThemeStatus()
        if let startResult {
            return startResult
        }
        return snapshot(for: workspace)
    }

    func refreshTargets() async throws -> WorkspaceTargetSnapshot {
        refreshTargetsCalls += 1
        if let refreshTargetsError {
            throw refreshTargetsError
        }
        _ = try? await verifyThemeStatus()
        if let refreshTargetsResult {
            workspace = refreshTargetsResult.workspace
            return refreshTargetsResult
        }
        return snapshot(for: workspace)
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
        _ = try? await verifyThemeStatus()
        return WorkspaceConnectionResult(
            snapshot: snapshot(for: workspace),
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
        _ = try? await verifyThemeStatus()
        return WorkspaceConnectionResult(
            snapshot: snapshot(for: workspace),
            report: connectionReport(
                targetInstanceID: targetInstanceID,
                capabilityID: "disconnect",
                detail: "Restored and disconnected."
            )
        )
    }

    func reviewDisconnect(targetInstanceID: TargetInstanceID) async throws -> DisconnectReview {
        reviewDisconnectCalls.append(targetInstanceID)
        if let reviewDisconnectError {
            throw reviewDisconnectError
        }
        if let reviewDisconnectResult {
            return reviewDisconnectResult
        }
        guard let instance = workspace.connectedTargetInstances.first(where: { $0.id == targetInstanceID }) else {
            throw ProductionWorkspaceRuntimeError.targetNoLongerAvailable(targetInstanceID)
        }
        return DisconnectReview(
            targetInstanceID: targetInstanceID,
            adapterID: instance.adapterID,
            isSafeToRestore: true,
            restorationSummary:
                "Restore the captured Connection Baseline for \(instance.displayName) and stop managing it.",
            expectedEffects: [
                "Restore original configuration.", "Remove managed setup.", "Stop managing target.",
            ],
            residualPathsIfRelinquished: ["Managed configuration for \(instance.displayName) remains in place."],
            conflictDetail: nil,
            baselineDigest: "fake-baseline"
        )
    }

    func relinquishManagement(
        targetInstanceID: TargetInstanceID
    ) async throws -> WorkspaceRelinquishResult {
        relinquishCalls.append(targetInstanceID)
        if let relinquishError {
            throw relinquishError
        }
        if let relinquishResult {
            return relinquishResult
        }
        guard let instance = workspace.connectedTargetInstances.first(where: { $0.id == targetInstanceID }) else {
            throw ProductionWorkspaceRuntimeError.targetNoLongerAvailable(targetInstanceID)
        }
        var newOptIns = workspace.targetOptIns
        newOptIns.remove(targetInstanceID)
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: workspace.connectedTargetInstances.filter { $0.id != targetInstanceID },
            targetOptIns: newOptIns,
            themeAssignment: workspace.themeAssignment
        )
        _ = try? await verifyThemeStatus()
        let report = RelinquishReport(
            operationID: UUID(),
            targetInstanceID: targetInstanceID,
            adapterID: instance.adapterID,
            residualPaths: ["Managed configuration for \(instance.displayName) remains in place."],
            detail: "Management relinquished for \(instance.displayName) without restoration."
        )
        return WorkspaceRelinquishResult(
            snapshot: snapshot(for: workspace),
            report: report
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

    func cancelRemainingApply(operationID: UUID) async throws {
        cancelRemainingApplyOperationIDs.append(operationID)
        if let cancelRemainingApplyHandler {
            try await cancelRemainingApplyHandler(operationID)
        }
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
        _ = try? await verifyThemeStatus()
        return WorkspaceSetupResult(
            snapshot: snapshot(for: workspace),
            report: SetupReport(
                operationID: UUID(),
                outcomes: outcomes
            )
        )
    }

    func prepareApplyPlan() async throws -> ApplyPlan {
        prepareCalls += 1
        _ = try? await verifyThemeStatus()
        if let prepareApplyPlanError {
            throw prepareApplyPlanError
        }
        if let prepareApplyPlanResult {
            return prepareApplyPlanResult
        }
        guard case .fixed(let variantID) = workspace.themeAssignment else {
            throw ThemeEngineError.fixedThemeAssignmentRequired
        }
        let orderedInstances = WorkspaceTargetOrder.ordered(workspace.connectedTargetInstances)
        let targetPlans: [AdapterPlan] = orderedInstances.map { instance in
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

    func apply(
        planID: UUID,
        targetInstanceIDs: Set<TargetInstanceID>? = nil,
        onProgress: (@Sendable (ApplyProgress) -> Void)? = nil
    ) async throws -> DurableApplyReport {
        applyCalls.append(planID)
        applyTargetInstanceIDSets.append(targetInstanceIDs)
        if let applyError {
            throw applyError
        }
        if let onApplyExecution, let customReport = try await onApplyExecution(planID, onProgress) {
            _ = try? await verifyThemeStatus()
            return customReport
        }
        if let applyResult {
            latestApplyReport = applyResult
            _ = try? await verifyThemeStatus()
            return applyResult
        }
        let plan = prepareApplyPlanResult?.id == planID ? prepareApplyPlanResult : nil
        let orderedInstances = WorkspaceTargetOrder.ordered(workspace.connectedTargetInstances)
        if let onProgress {
            let initialSteps = orderedInstances.map {
                ApplyProgress.TargetStep(
                    targetInstanceID: $0.id,
                    displayName: $0.displayName,
                    adapterID: $0.adapterID,
                    status: .waiting
                )
            }
            onProgress(ApplyProgress(operationID: planID, steps: initialSteps))
        }
        let outcomes = orderedInstances.map { instance in
            if let plan, let targetPlan = plan.targetPlans.first(where: { $0.targetInstanceID == instance.id }) {
                if !targetPlan.conflicts.isEmpty {
                    return TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: instance.adapterID,
                        capabilityID: targetPlan.capabilityID,
                        sourceType: targetPlan.sourceType,
                        sourceRevision: targetPlan.sourceRevision,
                        configurationState: .conflicted,
                        runningInstanceReach: .unavailable,
                        detail: targetPlan.conflicts.joined(separator: "; "),
                        rollbackState: .blocked,
                        userActions: []
                    )
                }
                if !targetPlan.setupNeeds.isEmpty {
                    let isPermission = targetPlan.setupNeeds.contains {
                        $0.kind == .permission
                            || $0.title.localizedCaseInsensitiveContains("permission")
                            || $0.detail.localizedCaseInsensitiveContains("permission")
                    }
                    return TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: instance.adapterID,
                        capabilityID: targetPlan.capabilityID,
                        sourceType: targetPlan.sourceType,
                        sourceRevision: targetPlan.sourceRevision,
                        configurationState: isPermission ? .permissionRequired : .failed,
                        runningInstanceReach: .unavailable,
                        detail: targetPlan.setupNeeds.map(\.detail).joined(separator: "; "),
                        rollbackState: .notNeeded,
                        userActions: targetPlan.setupNeeds
                    )
                }
            } else if let plan, plan.unavailableTargetInstanceIDs.contains(instance.id) {
                return TargetCapabilityOutcome(
                    targetInstanceID: instance.id,
                    adapterID: instance.adapterID,
                    capabilityID: "theme",
                    sourceType: .unavailable,
                    sourceRevision: "",
                    configurationState: .unavailable,
                    runningInstanceReach: .unavailable,
                    detail: "Target unavailable.",
                    rollbackState: .notNeeded
                )
            }
            return TargetCapabilityOutcome(
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
        let updatedCount = outcomes.filter { $0.configurationState == .updated }.count
        if updatedCount > 0 {
            undoAvailabilityResult = .available(sourceOperationID: opID, changedTargetCount: updatedCount)
        } else {
            undoAvailabilityResult = .unavailable
        }
        let variantID: String
        if case .fixed(let v) = workspace.themeAssignment {
            variantID = v
        } else {
            variantID = "fake/variant"
        }
        _ = try? await verifyThemeStatus()
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
            _ = try? await verifyThemeStatus()
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
        _ = try? await verifyThemeStatus()
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
        _ = try? await verifyThemeStatus()
        return snapshot(for: workspace)
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
        _ = try? await verifyThemeStatus()
        return snapshot(for: workspace)
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
        _ = try? await verifyThemeStatus()
        return snapshot(for: workspace)
    }

    private func snapshot(for workspace: Workspace) -> WorkspaceTargetSnapshot {
        WorkspaceTargetSnapshot(
            workspace: workspace,
            targets: defaultTargets(for: workspace),
            replacementSuggestions: replacementSuggestions
        )
    }

    func reviewReset() async throws -> ResetReview {
        reviewResetCalls += 1
        if let reviewResetError {
            throw reviewResetError
        }
        if let reviewResetResult {
            return reviewResetResult
        }
        return ResetReview(
            entries: workspace.connectedTargetInstances.map { instance in
                DisconnectReview(
                    targetInstanceID: instance.id,
                    adapterID: instance.adapterID,
                    isSafeToRestore: true,
                    restorationSummary:
                        "Restore the captured Connection Baseline for \(instance.displayName) and stop managing it.",
                    expectedEffects: ["Restore original configuration."],
                    residualPathsIfRelinquished: [],
                    conflictDetail: nil,
                    baselineDigest: "fake-baseline"
                )
            }
        )
    }

    func finalizeReset() async throws -> WorkspaceTargetSnapshot {
        finalizeResetCalls += 1
        if let finalizeResetError {
            throw finalizeResetError
        }
        if let finalizeResetResult {
            workspace = finalizeResetResult.workspace
            return finalizeResetResult
        }
        guard workspace.connectedTargetInstances.isEmpty else {
            throw ProductionWorkspaceRuntimeError.resetBlockedByConnectedTargets(
                workspace.connectedTargetInstances.map(\.id)
            )
        }
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName
        )
        replacementSuggestions = []
        onboardingDisposition = .inProgress
        latestSetupReport = nil
        latestApplyReport = nil
        _ = try? await verifyThemeStatus()
        return snapshot(for: workspace)
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
