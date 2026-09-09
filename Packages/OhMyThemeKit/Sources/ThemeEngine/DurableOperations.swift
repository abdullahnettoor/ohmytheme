import CryptoKit
import Foundation
import Persistence
import ThemeModel

// MARK: - Durable operation reports

public struct ConnectionReport: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let outcomes: [TargetCapabilityOutcome]

    public init(operationID: UUID, outcomes: [TargetCapabilityOutcome]) {
        self.operationID = operationID
        self.outcomes = outcomes
    }
}

public struct DurableApplyReport: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let variantID: String
    public let outcomes: [TargetCapabilityOutcome]

    public init(operationID: UUID, variantID: String, outcomes: [TargetCapabilityOutcome]) {
        self.operationID = operationID
        self.variantID = variantID
        self.outcomes = outcomes
    }
}

public struct SetupReport: Codable, Equatable, Sendable {
    public enum OutcomeKind: String, Codable, Equatable, Sendable {
        case connected
        case unchanged
        case skipped
        case needsPermission
        case conflict
        case failed
        case unavailable
        case recoveryRequired
    }

    public let operationID: UUID
    public let retrySourceOperationID: UUID?
    public let outcomes: [TargetCapabilityOutcome]
    public let combinedOutcomes: [TargetCapabilityOutcome]

    enum CodingKeys: String, CodingKey {
        case operationID
        case retrySourceOperationID
        case outcomes
        case combinedOutcomes
    }

    public init(
        operationID: UUID,
        retrySourceOperationID: UUID? = nil,
        outcomes: [TargetCapabilityOutcome],
        combinedOutcomes: [TargetCapabilityOutcome]? = nil
    ) {
        self.operationID = operationID
        self.retrySourceOperationID = retrySourceOperationID
        self.outcomes = outcomes
        self.combinedOutcomes = combinedOutcomes ?? outcomes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try container.decode(UUID.self, forKey: .operationID)
        retrySourceOperationID = try container.decodeIfPresent(UUID.self, forKey: .retrySourceOperationID)
        outcomes = try container.decode([TargetCapabilityOutcome].self, forKey: .outcomes)
        combinedOutcomes =
            try container.decodeIfPresent([TargetCapabilityOutcome].self, forKey: .combinedOutcomes) ?? outcomes
    }

    public func outcomeKind(for outcome: TargetCapabilityOutcome) -> OutcomeKind {
        if outcome.rollbackState == .recoveryRequired {
            return .recoveryRequired
        }
        if outcome.configurationState == .unchanged && outcome.detail == "Skipped after Cancel Remaining." {
            return .skipped
        }
        switch outcome.configurationState {
        case .updated:
            return .connected
        case .unchanged:
            return .unchanged
        case .permissionRequired:
            return .needsPermission
        case .conflicted:
            return .conflict
        case .failed:
            return .failed
        case .unavailable:
            return .unavailable
        }
    }

    public func kind(for targetInstanceID: TargetInstanceID) -> OutcomeKind? {
        guard let outcome = combinedOutcomes.first(where: { $0.targetInstanceID == targetInstanceID }) else {
            return nil
        }
        return outcomeKind(for: outcome)
    }

    public var connectedOutcomes: [TargetCapabilityOutcome] {
        combinedOutcomes.filter { outcomeKind(for: $0) == .connected }
    }

    public var unchangedOutcomes: [TargetCapabilityOutcome] {
        combinedOutcomes.filter { outcomeKind(for: $0) == .unchanged }
    }

    public var skippedOutcomes: [TargetCapabilityOutcome] {
        combinedOutcomes.filter { outcomeKind(for: $0) == .skipped }
    }

    public var needsPermissionOutcomes: [TargetCapabilityOutcome] {
        combinedOutcomes.filter { outcomeKind(for: $0) == .needsPermission }
    }

    public var conflictOutcomes: [TargetCapabilityOutcome] {
        combinedOutcomes.filter { outcomeKind(for: $0) == .conflict }
    }

    public var failedOutcomes: [TargetCapabilityOutcome] {
        combinedOutcomes.filter { outcomeKind(for: $0) == .failed }
    }

    public var unavailableOutcomes: [TargetCapabilityOutcome] {
        combinedOutcomes.filter { outcomeKind(for: $0) == .unavailable }
    }

    public var recoveryRequiredOutcomes: [TargetCapabilityOutcome] {
        combinedOutcomes.filter { outcomeKind(for: $0) == .recoveryRequired }
    }

    public var resolvedOutcomes: [TargetCapabilityOutcome] {
        combinedOutcomes.filter {
            let k = outcomeKind(for: $0)
            return k == .connected || k == .unchanged
        }
    }

    public var unresolvedOutcomes: [TargetCapabilityOutcome] {
        combinedOutcomes.filter {
            let k = outcomeKind(for: $0)
            return k == .failed || k == .needsPermission || k == .conflict || k == .unavailable || k == .skipped
                || k == .recoveryRequired
        }
    }
}

// MARK: - Errors

public enum DurableOperationError: Error, Equatable, Sendable {
    case persistenceRequired
    case adapterNotWritable(String)
    case adapterUnavailable(String)
    case baselineMissing(TargetInstanceID)
    case cancellationRefused
    case operationInProgress
    case operationNotFound(UUID)
    case noLastApplyTransaction
    case operationCancelled
}

public enum UndoAvailability: Equatable, Sendable {
    case unavailable
    case available(sourceOperationID: UUID, changedTargetCount: Int)
}

public struct UndoReport: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let sourceOperationID: UUID
    public let outcomes: [TargetCapabilityOutcome]

    public init(
        operationID: UUID,
        sourceOperationID: UUID,
        outcomes: [TargetCapabilityOutcome]
    ) {
        self.operationID = operationID
        self.sourceOperationID = sourceOperationID
        self.outcomes = outcomes
    }
}

// MARK: - ThemeEngine additions

extension ThemeEngine {
    // MARK: Setup Plan

    public func prepareSetup(
        workspace: Workspace,
        instances: [ConnectedTargetInstance],
        retrySourceOperationID: UUID? = nil
    ) async throws -> SetupPlan {
        let retryableTargetIDs: Set<TargetInstanceID>?
        if let retrySourceOperationID {
            guard let persistence = persistenceStore else {
                throw DurableOperationError.persistenceRequired
            }
            retryableTargetIDs = try retryableSetupTargetIDs(
                from: retrySourceOperationID,
                persistence: persistence
            )
        } else {
            retryableTargetIDs = nil
        }
        let unconfigured = instances.filter {
            !workspace.isConnected($0.id)
                && (retryableTargetIDs?.contains($0.id) ?? true)
        }
        let orderedInstances = WorkspaceTargetOrder.ordered(unconfigured)
        var targetPlans: [ConnectionPlan] = []
        var preparationFailures: [TargetSetupPreparationFailure] = []
        var expectedSideEffects: [String] = []
        var requiredPermissions: [String] = []
        var userActions: [UserAction] = []
        var ownershipDetails: [SetupOwnershipDetail] = []

        for instance in orderedInstances {
            guard let adapter = self.connectionAdapter(for: instance.adapterID) else {
                let failure = TargetSetupPreparationFailure(
                    targetInstanceID: instance.id,
                    adapterID: instance.adapterID,
                    configurationState: .unavailable,
                    detail: "The adapter is unavailable or does not support connect."
                )
                preparationFailures.append(failure)
                ownershipDetails.append(
                    SetupOwnershipDetail(
                        targetInstanceID: instance.id,
                        adapterID: instance.adapterID,
                        summary: "Adapter unavailable for \(instance.displayName).",
                        routineDetails: [],
                        isConsequential: false,
                        consequentialDetail: nil
                    )
                )
                continue
            }

            do {
                let plan = try await adapter.prepareConnection(
                    instance: instance,
                    approveLinkedSource: false
                )
                targetPlans.append(plan)

                for permission in plan.requiredPermissions where !requiredPermissions.contains(permission) {
                    requiredPermissions.append(permission)
                }
                for action in plan.userActions where !userActions.contains(action) {
                    userActions.append(action)
                }

                let ownership =
                    plan.ownershipDetail
                    ?? SetupOwnershipDetail(
                        targetInstanceID: instance.id,
                        adapterID: instance.adapterID,
                        summary: "Manages configuration for \(instance.displayName).",
                        routineDetails: plan.expectedSideEffects,
                        isConsequential: plan.requiresApproval || !plan.requiredPermissions.isEmpty,
                        consequentialDetail: plan.requiresApproval
                            ? "Approval required before modifying existing configuration."
                            : (plan.requiredPermissions.first.map { "Requires permission: \($0)" })
                    )
                ownershipDetails.append(ownership)
            } catch {
                let outcome = Self.capabilityOutcome(for: error, fallbackState: .failed)
                let failure = TargetSetupPreparationFailure(
                    targetInstanceID: instance.id,
                    adapterID: instance.adapterID,
                    configurationState: outcome.configurationState,
                    detail: outcome.detail
                )
                preparationFailures.append(failure)
                ownershipDetails.append(
                    SetupOwnershipDetail(
                        targetInstanceID: instance.id,
                        adapterID: instance.adapterID,
                        summary: "Failed to prepare connection for \(instance.displayName).",
                        routineDetails: [],
                        isConsequential: false,
                        consequentialDetail: nil
                    )
                )
            }
        }

        let sharedEffectResult = Self.deriveSharedEffects(
            instances: orderedInstances,
            plans: targetPlans
        )
        let instancesByID = Dictionary(uniqueKeysWithValues: orderedInstances.map { ($0.id, $0) })
        let unsharedEffects = targetPlans.flatMap { plan in
            plan.expectedSideEffects.compactMap { effect -> (TargetInstanceID, String)? in
                let coveredEffects = sharedEffectResult.coveredSideEffectsByTarget[plan.targetInstanceID] ?? []
                return coveredEffects.contains(effect) ? nil : (plan.targetInstanceID, effect)
            }
        }
        let effectCounts = Dictionary(grouping: unsharedEffects, by: { $0.1 }).mapValues(\.count)
        expectedSideEffects = unsharedEffects.map { targetID, effect in
            guard effectCounts[effect, default: 0] > 1,
                let instance = instancesByID[targetID]
            else {
                return effect
            }
            return "\(instance.displayName): \(effect)"
        }

        let reach: ActivationReach
        if targetPlans.isEmpty {
            reach = .unavailable
        } else {
            reach = targetPlans.map(\.activationReach).reduce(.currentInstances, Self.worstReach)
        }

        let digest = Self.computeDiscoveryAndSelectionDigest(
            instances: orderedInstances,
            workspace: workspace,
            targetPlans: targetPlans
        )

        let plan = SetupPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: orderedInstances.map(\.id),
            targetPlans: targetPlans,
            preparationFailures: preparationFailures,
            expectedSideEffects: expectedSideEffects,
            requiredPermissions: requiredPermissions,
            userActions: userActions,
            activationReach: reach,
            ownershipDetails: ownershipDetails,
            recoveryBehavior:
                "Oh My Theme captures a baseline of existing target configurations before any mutation. If setup is cancelled or disconnected, the baseline can be restored safely without force-overwriting external changes.",
            discoveryAndSelectionDigest: digest,
            sharedEffects: sharedEffectResult.effects,
            retrySourceOperationID: retrySourceOperationID
        )
        self.setupPlansInFlight[plan.id] = plan
        return plan
    }

    private static func deriveSharedEffects(
        instances: [ConnectedTargetInstance],
        plans: [ConnectionPlan]
    ) -> (effects: [SetupSharedEffect], coveredSideEffectsByTarget: [TargetInstanceID: Set<String>]) {
        struct GroupedEffect {
            let descriptor: ConnectionSharedSetupEffect
            var targets: [(id: TargetInstanceID, name: String, coveredSideEffects: [String])]
        }

        let instancesByID = Dictionary(uniqueKeysWithValues: instances.map { ($0.id, $0) })
        var groups: [String: GroupedEffect] = [:]

        for plan in plans {
            guard let instance = instancesByID[plan.targetInstanceID] else { continue }
            for descriptor in plan.sharedSetupEffects {
                let target = (
                    id: instance.id,
                    name: instance.displayName,
                    coveredSideEffects: descriptor.coveredExpectedSideEffects
                )
                if var group = groups[descriptor.key] {
                    group.targets.append(target)
                    groups[descriptor.key] = group
                } else {
                    groups[descriptor.key] = GroupedEffect(
                        descriptor: descriptor,
                        targets: [target]
                    )
                }
            }
        }

        let sharedGroups = groups.values.filter { $0.targets.count > 1 }
        var coveredSideEffectsByTarget: [TargetInstanceID: Set<String>] = [:]
        for group in sharedGroups {
            for target in group.targets {
                coveredSideEffectsByTarget[target.id, default: []].formUnion(
                    target.coveredSideEffects
                )
            }
        }
        let effects = sharedGroups.map { group in
            SetupSharedEffect(
                name: group.descriptor.name,
                detail: group.descriptor.detail,
                affectedTargetIDs: group.targets.map(\.id),
                affectedTargetNames: group.targets.map(\.name),
                isConsequential: group.descriptor.isConsequential
            )
        }
        .sorted { $0.name < $1.name }

        return (effects, coveredSideEffectsByTarget)
    }

    public func validateSetupPlanPreconditions(
        plan: SetupPlan,
        workspace: Workspace,
        currentInstances: [ConnectedTargetInstance],
        availableTargetInstanceIDs: Set<TargetInstanceID>
    ) async -> SetupPlanPreconditionValidation {
        let currentUnresolvedOptIns = Set(workspace.targetOptIns.filter { !workspace.isConnected($0) })
        let planTargets = Set(plan.targetInstanceIDs)
        let expectedPlanTargets: Set<TargetInstanceID>
        if let retrySourceOperationID = plan.retrySourceOperationID {
            guard let persistence = persistenceStore else {
                return .invalidated(reason: "Persistent retry history is unavailable.")
            }
            do {
                expectedPlanTargets = currentUnresolvedOptIns.intersection(
                    try retryableSetupTargetIDs(from: retrySourceOperationID, persistence: persistence)
                )
            } catch {
                return .invalidated(reason: "Retry history is unavailable: \(error.localizedDescription)")
            }
        } else {
            expectedPlanTargets = currentUnresolvedOptIns
        }
        if expectedPlanTargets != planTargets {
            return .invalidated(
                reason: "Target Opt-ins or retry eligibility changed since the plan was prepared."
            )
        }

        let currentInstancesByID = Dictionary(uniqueKeysWithValues: currentInstances.map { ($0.id, $0) })
        for targetPlan in plan.targetPlans {
            if !availableTargetInstanceIDs.contains(targetPlan.targetInstanceID) {
                return .invalidated(
                    reason: "Target instance \(targetPlan.targetInstanceID.rawValue) is no longer available."
                )
            }
            guard let adapter = self.connectionAdapter(for: targetPlan.adapterID) else {
                return .invalidated(
                    reason: "Adapter \(targetPlan.adapterID) is no longer available."
                )
            }
            do {
                try await adapter.revalidateConnection(plan: targetPlan)
            } catch {
                return .invalidated(
                    reason:
                        "Configuration for \(targetPlan.targetInstanceID.rawValue) was externally modified: \(error.localizedDescription)"
                )
            }
        }

        for failure in plan.preparationFailures {
            guard let instance = currentInstancesByID[failure.targetInstanceID] else {
                return .invalidated(
                    reason: "Target instance \(failure.targetInstanceID.rawValue) is no longer available."
                )
            }
            guard let adapter = self.connectionAdapter(for: instance.adapterID) else {
                if failure.adapterID != instance.adapterID {
                    return .invalidated(
                        reason:
                            "Adapter for \(instance.displayName) changed from \(failure.adapterID) to \(instance.adapterID)."
                    )
                }
                continue
            }
            do {
                _ = try await adapter.prepareConnection(
                    instance: instance,
                    approveLinkedSource: false
                )
                return .invalidated(
                    reason: "Preconditions changed: setup preparation for \(instance.displayName) can now succeed."
                )
            } catch {
                let currentDetail = String(describing: error)
                if currentDetail != failure.detail {
                    return .invalidated(
                        reason: "Preparation conditions for \(instance.displayName) changed: \(currentDetail)"
                    )
                }
            }
        }

        let orderedAvailable = WorkspaceTargetOrder.ordered(
            plan.targetInstanceIDs.compactMap { currentInstancesByID[$0] }
        )
        let currentDigest = Self.computeDiscoveryAndSelectionDigest(
            instances: orderedAvailable,
            workspace: workspace,
            targetPlans: plan.targetPlans
        )
        if currentDigest != plan.discoveryAndSelectionDigest {
            return .invalidated(
                reason: "Material preconditions or discovery digest changed since the plan was prepared."
            )
        }

        return .valid
    }

    static func computeDiscoveryAndSelectionDigest(
        instances: [ConnectedTargetInstance],
        workspace: Workspace,
        targetPlans: [ConnectionPlan]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(workspace.id.rawValue.utf8))
        for instance in instances {
            hasher.update(data: Data(instance.id.rawValue.utf8))
            hasher.update(data: Data(instance.adapterID.utf8))
        }
        for optIn in workspace.targetOptIns.map(\.rawValue).sorted() {
            hasher.update(data: Data(optIn.utf8))
        }
        for plan in targetPlans {
            hasher.update(data: Data(plan.targetInstanceID.rawValue.utf8))
            hasher.update(data: Data(plan.adapterID.utf8))
            hasher.update(data: Data(plan.adapterVersion.utf8))
            hasher.update(data: Data(plan.intendedChangeDigest.utf8))
            if let token = plan.staleStateToken {
                hasher.update(data: Data(token.utf8))
            }
            hasher.update(data: plan.capturedPreChangeState)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ThemeEngine {
    // MARK: - Setup Transaction

    public func executeSetup(
        planID: UUID,
        workspace: Workspace,
        instances: [ConnectedTargetInstance] = [],
        onProgress: (@Sendable (SetupProgress) -> Void)? = nil
    ) async throws -> SetupReport {
        guard let plan = setupPlansInFlight.removeValue(forKey: planID) else {
            throw ThemeEngineError.planNotFound(planID)
        }
        return try await executeSetup(plan: plan, workspace: workspace, instances: instances, onProgress: onProgress)
    }

    public func executeSetup(
        plan: SetupPlan,
        workspace: Workspace,
        instances: [ConnectedTargetInstance] = [],
        onProgress: (@Sendable (SetupProgress) -> Void)? = nil
    ) async throws -> SetupReport {
        guard let persistence = self.persistenceStore else {
            throw DurableOperationError.persistenceRequired
        }
        try await ensureNoOperationInProgress()
        try reserveOperationStart()
        var trackingStarted = false
        defer {
            if !trackingStarted {
                releaseOperationStart()
            }
        }
        try await reconcileInterruptedOperations()

        guard plan.workspaceID == workspace.id else {
            throw ThemeEngineError.planWorkspaceChanged(plan.id)
        }

        try plan.validatePlanIntegrity()

        let currentUnresolvedOptIns = Set(workspace.targetOptIns.filter { !workspace.isConnected($0) })
        let planTargets = Set(plan.targetInstanceIDs)
        let expectedPlanTargets: Set<TargetInstanceID>
        if let retrySourceOperationID = plan.retrySourceOperationID {
            expectedPlanTargets = currentUnresolvedOptIns.intersection(
                try retryableSetupTargetIDs(from: retrySourceOperationID, persistence: persistence)
            )
        } else {
            expectedPlanTargets = currentUnresolvedOptIns
        }
        guard expectedPlanTargets == planTargets else {
            throw ThemeEngineError.planMembershipChanged(plan.id)
        }

        let isPreCancelled = pendingCancellations.contains(plan.id)
        setupPlansInFlight.removeValue(forKey: plan.id)

        var instanceMap: [TargetInstanceID: ConnectedTargetInstance] = [:]
        for instance in instances {
            instanceMap[instance.id] = instance
        }
        for instance in workspace.connectedTargetInstances where instanceMap[instance.id] == nil {
            instanceMap[instance.id] = instance
        }

        var planReferences: [TargetInstanceID: ContentReference] = [:]
        var baselineWasPreviouslyStored: [TargetInstanceID: Bool] = [:]
        let originalPlansByID = Dictionary(uniqueKeysWithValues: plan.targetPlans.map { ($0.targetInstanceID, $0) })
        let failuresByID = Dictionary(uniqueKeysWithValues: plan.preparationFailures.map { ($0.targetInstanceID, $0) })
        var initialRecords: [JournaledRecord] = []

        // Store every reviewed plan before creating the Setup Transaction. The
        // transaction and all per-target records are then committed together, so
        // reconciliation can classify every target from its first checkpoint.
        for (ordinal, targetID) in plan.targetInstanceIDs.enumerated() {
            if let targetPlan = originalPlansByID[targetID] {
                let reference = try persistence.journalStorePlanPayload(
                    JSONEncoder().encode(targetPlan),
                    ownerID: "setup.\(plan.id.uuidString).\(targetID.rawValue)"
                )
                planReferences[targetID] = reference
                baselineWasPreviouslyStored[targetID] =
                    try persistence.journalLoadConnectionBaseline(targetInstanceID: targetID) != nil
                initialRecords.append(
                    JournaledRecord(
                        operationID: plan.id,
                        targetInstanceID: targetID,
                        ordinal: ordinal,
                        adapterID: targetPlan.adapterID,
                        adapterVersion: targetPlan.adapterVersion,
                        capabilityID: "connection",
                        phase: .prepared,
                        intendedChangeDigest: targetPlan.intendedChangeDigest,
                        staleStateToken: targetPlan.staleStateToken,
                        planDigest: reference.digest,
                        receiptJSON: nil,
                        detail: nil
                    )
                )
            } else if let failure = failuresByID[targetID] {
                initialRecords.append(
                    JournaledRecord(
                        operationID: plan.id,
                        targetInstanceID: targetID,
                        ordinal: ordinal,
                        adapterID: failure.adapterID,
                        adapterVersion: "n/a",
                        capabilityID: "connection",
                        phase: .failed,
                        intendedChangeDigest: "n/a",
                        staleStateToken: nil,
                        planDigest: nil,
                        receiptJSON: nil,
                        detail: failure.detail
                    )
                )
            }
        }

        let operation = try persistence.journalStartSetupOperation(
            id: plan.id,
            workspaceID: workspace.id,
            parentOperationID: plan.retrySourceOperationID,
            cancellationRequested: isPreCancelled,
            records: initialRecords
        )
        try await beginOperationTracking(operation)
        trackingStarted = true
        defer { try? closeOperationTracking(operation.id) }

        var steps: [SetupProgress.TargetStep] = []
        for targetID in plan.targetInstanceIDs {
            let displayName = instanceMap[targetID]?.displayName ?? targetID.rawValue
            if let targetPlan = originalPlansByID[targetID] {
                steps.append(
                    SetupProgress.TargetStep(
                        targetInstanceID: targetID,
                        displayName: displayName,
                        adapterID: targetPlan.adapterID,
                        status: .waiting
                    )
                )
            } else if let failure = failuresByID[targetID] {
                steps.append(
                    SetupProgress.TargetStep(
                        targetInstanceID: targetID,
                        displayName: displayName,
                        adapterID: failure.adapterID,
                        status: Self.setupProgressStatus(
                            configurationState: failure.configurationState,
                            activationReach: .unavailable,
                            detail: failure.detail
                        )
                    )
                )
            }
        }
        var currentProgress = SetupProgress(
            operationID: operation.id,
            steps: steps,
            currentTargetID: nil
        )
        onProgress?(currentProgress)

        do {
            try await checkAndConsumeCancellation(operation.id)
        } catch let error as DurableOperationError where error == .operationCancelled {
            for (ordinal, targetID) in plan.targetInstanceIDs.enumerated() {
                if let targetPlan = originalPlansByID[targetID] {
                    try persistence.journalSaveRecord(
                        JournaledRecord(
                            operationID: operation.id,
                            targetInstanceID: targetID,
                            ordinal: ordinal,
                            adapterID: targetPlan.adapterID,
                            adapterVersion: targetPlan.adapterVersion,
                            capabilityID: "connection",
                            phase: .skipped,
                            intendedChangeDigest: targetPlan.intendedChangeDigest,
                            staleStateToken: targetPlan.staleStateToken,
                            planDigest: planReferences[targetID]?.digest,
                            receiptJSON: nil,
                            detail: "Skipped after Cancel Remaining."
                        )
                    )
                }
            }
            try persistence.journalTransitionState(operationID: operation.id, to: .cancelled)
            throw error
        }

        // Capture immediate baselines only after the transaction is durable and
        // cancellation has been checked. Deferred baselines remain absent until
        // their permission disclosure immediately before execution.
        let initialRecordsByTarget = Dictionary(
            uniqueKeysWithValues: initialRecords.map { ($0.targetInstanceID, $0) }
        )
        for targetPlan in plan.targetPlans where targetPlan.baselineCaptureTiming != .immediatelyBeforeExecution {
            guard let record = initialRecordsByTarget[targetPlan.targetInstanceID] else { continue }
            try persistence.saveConnectionPreparation(
                record: record,
                baseline: targetPlan.capturedPreChangeState
            )
        }

        try persistence.journalTransitionState(operationID: operation.id, to: .applying)

        var outcomes: [TargetCapabilityOutcome] = []
        var anyMutated = false
        var cancellationRequested = false

        setupLoop: for (ordinal, targetID) in plan.targetInstanceIDs.enumerated() {
            if consumeSetupCancellation(operation.id) {
                cancellationRequested = true
                break setupLoop
            }
            currentProgress.currentTargetID = targetID

            if let failure = failuresByID[targetID] {
                outcomes.append(
                    TargetCapabilityOutcome(
                        targetInstanceID: targetID,
                        adapterID: failure.adapterID,
                        capabilityID: "connection",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: failure.configurationState,
                        runningInstanceReach: .unavailable,
                        detail: failure.detail
                    )
                )
                continue
            }

            guard let targetPlan = originalPlansByID[targetID] else {
                continue
            }

            let instance =
                instanceMap[targetID]
                ?? ConnectedTargetInstance(
                    id: targetID,
                    displayName: targetID.rawValue,
                    adapterID: targetPlan.adapterID
                )

            guard let adapter = self.connectionAdapter(for: targetPlan.adapterID) else {
                let executionPlan = targetPlan.recordingStoredBaseline(
                    baselineWasPreviouslyStored[targetID] ?? false
                )
                try removeNewConnectionBaseline(for: executionPlan, persistence: persistence)
                let failureOutcome = TargetCapabilityOutcome(
                    targetInstanceID: targetID,
                    adapterID: targetPlan.adapterID,
                    capabilityID: "connection",
                    sourceType: .unavailable,
                    sourceRevision: "n/a",
                    configurationState: .unavailable,
                    runningInstanceReach: .unavailable,
                    detail: "The adapter is unavailable or does not support connect."
                )
                outcomes.append(failureOutcome)
                try persistence.journalSaveRecord(
                    JournaledRecord(
                        operationID: operation.id,
                        targetInstanceID: targetID,
                        ordinal: ordinal,
                        adapterID: targetPlan.adapterID,
                        adapterVersion: targetPlan.adapterVersion,
                        capabilityID: "connection",
                        phase: .failed,
                        intendedChangeDigest: targetPlan.intendedChangeDigest,
                        staleStateToken: targetPlan.staleStateToken,
                        planDigest: planReferences[targetID]?.digest,
                        receiptJSON: nil,
                        detail: failureOutcome.detail
                    )
                )
                currentProgress.steps[ordinal].status = .unavailable(
                    detail: failureOutcome.detail ?? "Adapter unavailable")
                onProgress?(currentProgress)
                continue
            }

            if !targetPlan.requiredPermissions.isEmpty {
                currentProgress.steps[ordinal].status = .configuring
                currentProgress.steps[ordinal].currentAction =
                    "Waiting for permission: \(targetPlan.requiredPermissions.joined(separator: ", "))"
            } else {
                currentProgress.steps[ordinal].status = .configuring
                currentProgress.steps[ordinal].currentAction = "Configuring..."
            }
            onProgress?(currentProgress)
            if targetPlan.baselineCaptureTiming == .immediatelyBeforeExecution {
                await Task.yield()
            }

            var executionPlan = targetPlan
            if targetPlan.baselineCaptureTiming == .immediatelyBeforeExecution {
                guard let capturingAdapter = adapter as? any DeferredConnectionBaselineCapturing else {
                    let detail = "The adapter cannot capture its deferred Connection Baseline."
                    try persistence.journalSaveRecord(
                        JournaledRecord(
                            operationID: operation.id,
                            targetInstanceID: targetID,
                            ordinal: ordinal,
                            adapterID: adapter.id,
                            adapterVersion: adapter.version,
                            capabilityID: "connection",
                            phase: .failed,
                            intendedChangeDigest: targetPlan.intendedChangeDigest,
                            staleStateToken: targetPlan.staleStateToken,
                            planDigest: planReferences[targetID]?.digest,
                            receiptJSON: nil,
                            detail: detail
                        )
                    )
                    outcomes.append(
                        TargetCapabilityOutcome(
                            targetInstanceID: targetID,
                            adapterID: adapter.id,
                            capabilityID: "connection",
                            sourceType: .unavailable,
                            sourceRevision: "n/a",
                            configurationState: .failed,
                            runningInstanceReach: .unavailable,
                            detail: detail
                        )
                    )
                    currentProgress.steps[ordinal].status = .failed(detail: detail)
                    currentProgress.steps[ordinal].currentAction = nil
                    onProgress?(currentProgress)
                    continue
                }

                do {
                    let capture = try await capturingAdapter.captureConnectionBaseline(for: targetPlan)
                    executionPlan = targetPlan.recordingExecutionBaseline(capture)
                    let hadStoredBaseline = baselineWasPreviouslyStored[targetID] ?? false
                    executionPlan = executionPlan.recordingStoredBaseline(hadStoredBaseline)
                    let reference = try persistence.journalStorePlanPayload(
                        JSONEncoder().encode(executionPlan),
                        ownerID: "setup.\(operation.id.uuidString).\(targetID.rawValue)"
                    )
                    planReferences[targetID] = reference
                    try persistence.saveConnectionPreparation(
                        record: JournaledRecord(
                            operationID: operation.id,
                            targetInstanceID: targetID,
                            ordinal: ordinal,
                            adapterID: executionPlan.adapterID,
                            adapterVersion: executionPlan.adapterVersion,
                            capabilityID: "connection",
                            phase: .prepared,
                            intendedChangeDigest: executionPlan.intendedChangeDigest,
                            staleStateToken: executionPlan.staleStateToken,
                            planDigest: reference.digest,
                            receiptJSON: nil,
                            detail: nil
                        ),
                        baseline: executionPlan.capturedPreChangeState
                    )
                } catch {
                    let failure = Self.capabilityOutcome(
                        for: error,
                        fallbackState: .failed,
                        fallbackDetail: "Execution preparation failed: \(error)"
                    )
                    try persistence.journalSaveRecord(
                        JournaledRecord(
                            operationID: operation.id,
                            targetInstanceID: targetID,
                            ordinal: ordinal,
                            adapterID: adapter.id,
                            adapterVersion: adapter.version,
                            capabilityID: "connection",
                            phase: .failed,
                            intendedChangeDigest: targetPlan.intendedChangeDigest,
                            staleStateToken: targetPlan.staleStateToken,
                            planDigest: planReferences[targetID]?.digest,
                            receiptJSON: nil,
                            detail: failure.detail
                        )
                    )
                    outcomes.append(
                        TargetCapabilityOutcome(
                            targetInstanceID: targetID,
                            adapterID: adapter.id,
                            capabilityID: "connection",
                            sourceType: .unavailable,
                            sourceRevision: "n/a",
                            configurationState: failure.configurationState,
                            runningInstanceReach: failure.activationReach,
                            detail: failure.detail,
                            userActions: failure.configurationState == .permissionRequired
                                ? Self.permissionActions(
                                    setupNeeds: targetPlan.userActions,
                                    requiredPermissions: targetPlan.requiredPermissions
                                )
                                : []
                        )
                    )
                    currentProgress.steps[ordinal].status = Self.setupProgressStatus(
                        configurationState: failure.configurationState,
                        activationReach: failure.activationReach,
                        detail: failure.detail
                    )
                    currentProgress.steps[ordinal].currentAction = nil
                    onProgress?(currentProgress)
                    continue
                }
            } else {
                executionPlan = executionPlan.recordingStoredBaseline(
                    baselineWasPreviouslyStored[targetID] ?? false
                )
            }

            if consumeSetupCancellation(operation.id) {
                try removeNewConnectionBaseline(for: executionPlan, persistence: persistence)
                cancellationRequested = true
                break setupLoop
            }

            if executionPlan.requiresApproval, let approvingAdapter = adapter as? any ReviewedConnectionApproving {
                executionPlan = try await approvingAdapter.approveReviewedConnection(executionPlan)
            } else if executionPlan.requiresApproval {
                executionPlan = executionPlan.approvingReviewedSetup()
            }

            if consumeSetupCancellation(operation.id) {
                try removeNewConnectionBaseline(for: executionPlan, persistence: persistence)
                cancellationRequested = true
                break setupLoop
            }

            let executionPlanReference = try persistence.journalStorePlanPayload(
                JSONEncoder().encode(executionPlan),
                ownerID: "setup.\(operation.id.uuidString).\(targetID.rawValue)"
            )
            planReferences[targetID] = executionPlanReference
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: targetID,
                    ordinal: ordinal,
                    adapterID: executionPlan.adapterID,
                    adapterVersion: executionPlan.adapterVersion,
                    capabilityID: "connection",
                    phase: .prepared,
                    intendedChangeDigest: executionPlan.intendedChangeDigest,
                    staleStateToken: executionPlan.staleStateToken,
                    planDigest: executionPlanReference.digest,
                    receiptJSON: nil,
                    detail: nil
                )
            )

            if !anyMutated {
                await markMutationBegun(operation.id)
                anyMutated = true
            }

            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: targetID,
                    ordinal: ordinal,
                    adapterID: adapter.id,
                    adapterVersion: adapter.version,
                    capabilityID: "connection",
                    phase: .applying,
                    intendedChangeDigest: executionPlan.intendedChangeDigest,
                    staleStateToken: executionPlan.staleStateToken,
                    planDigest: planReferences[targetID]?.digest,
                    receiptJSON: nil,
                    detail: nil
                )
            )

            do {
                let receipt = try await adapter.connect(executionPlan)
                let receiptJSON = try encodeReceipt(receipt)
                let appliedRecord = JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: targetID,
                    ordinal: ordinal,
                    adapterID: adapter.id,
                    adapterVersion: adapter.version,
                    capabilityID: "connection",
                    phase: .applied,
                    intendedChangeDigest: executionPlan.intendedChangeDigest,
                    staleStateToken: executionPlan.staleStateToken,
                    planDigest: planReferences[targetID]?.digest,
                    receiptJSON: receiptJSON,
                    detail: receipt.detail
                )
                try persistence.recordSetupConnectionReceipt(
                    record: appliedRecord,
                    instance: instance,
                    workspace: workspace
                )
                let outcome = TargetCapabilityOutcome(
                    targetInstanceID: targetID,
                    adapterID: adapter.id,
                    capabilityID: "connection",
                    sourceType: .unavailable,
                    sourceRevision: "n/a",
                    configurationState: receipt.configurationState,
                    runningInstanceReach: receipt.runningInstanceReach,
                    detail: receipt.detail,
                    userActions: Self.activationActions(
                        for: receipt.runningInstanceReach,
                        adapterID: adapter.id
                    )
                )
                outcomes.append(outcome)
                currentProgress.steps[ordinal].status = Self.setupProgressStatus(
                    configurationState: receipt.configurationState,
                    activationReach: receipt.runningInstanceReach,
                    detail: receipt.detail ?? "Target configuration unchanged"
                )
                currentProgress.steps[ordinal].currentAction = nil
                onProgress?(currentProgress)
            } catch {
                let mutationNotStarted = error is any ConnectionMutationNotStartedError
                let failureOutcome = Self.capabilityOutcome(
                    for: error,
                    fallbackState: mutationNotStarted ? .conflicted : .failed
                )
                if mutationNotStarted {
                    try removeNewConnectionBaseline(for: executionPlan, persistence: persistence)
                }
                let recoveryRequired = error is any MutationRecoveryRequiredError
                let preMutationConflict =
                    mutationNotStarted && failureOutcome.configurationState == .conflicted
                try persistence.journalSaveRecord(
                    JournaledRecord(
                        operationID: operation.id,
                        targetInstanceID: targetID,
                        ordinal: ordinal,
                        adapterID: adapter.id,
                        adapterVersion: adapter.version,
                        capabilityID: "connection",
                        phase: recoveryRequired ? .applying : .failed,
                        intendedChangeDigest: executionPlan.intendedChangeDigest,
                        staleStateToken: executionPlan.staleStateToken,
                        planDigest: planReferences[targetID]?.digest,
                        receiptJSON: nil,
                        detail: failureOutcome.detail
                    )
                )
                let outcome = TargetCapabilityOutcome(
                    targetInstanceID: targetID,
                    adapterID: adapter.id,
                    capabilityID: "connection",
                    sourceType: .unavailable,
                    sourceRevision: "n/a",
                    configurationState: failureOutcome.configurationState,
                    runningInstanceReach: failureOutcome.activationReach,
                    detail: failureOutcome.detail,
                    rollbackState: recoveryRequired
                        ? .recoveryRequired
                        : preMutationConflict ? .blocked : .notNeeded,
                    userActions: recoveryRequired
                        ? [Self.recoveryRequiredAction]
                        : failureOutcome.configurationState == .permissionRequired
                            ? Self.permissionActions(
                                setupNeeds: targetPlan.userActions,
                                requiredPermissions: targetPlan.requiredPermissions
                            )
                            : preMutationConflict ? [Self.reviewExternalChangeAction] : []
                )
                outcomes.append(outcome)
                currentProgress.steps[ordinal].status = Self.setupProgressStatus(
                    configurationState: failureOutcome.configurationState,
                    activationReach: failureOutcome.activationReach,
                    detail: failureOutcome.detail,
                    isRecoveryRequired: recoveryRequired
                )
                currentProgress.steps[ordinal].currentAction = nil
                onProgress?(currentProgress)
            }
        }

        if cancellationRequested {
            let completedTargetIDs = Set(outcomes.map(\.targetInstanceID))
            for (ordinal, targetID) in plan.targetInstanceIDs.enumerated() where !completedTargetIDs.contains(targetID)
            {
                if let failure = failuresByID[targetID] {
                    outcomes.append(
                        TargetCapabilityOutcome(
                            targetInstanceID: targetID,
                            adapterID: failure.adapterID,
                            capabilityID: "connection",
                            sourceType: .unavailable,
                            sourceRevision: "n/a",
                            configurationState: .failed,
                            runningInstanceReach: .unavailable,
                            detail: failure.detail
                        )
                    )
                    continue
                }
                guard let targetPlan = originalPlansByID[targetID] else { continue }
                let detail = "Skipped after Cancel Remaining."
                try persistence.journalSaveRecord(
                    JournaledRecord(
                        operationID: operation.id,
                        targetInstanceID: targetID,
                        ordinal: ordinal,
                        adapterID: targetPlan.adapterID,
                        adapterVersion: targetPlan.adapterVersion,
                        capabilityID: "connection",
                        phase: .skipped,
                        intendedChangeDigest: targetPlan.intendedChangeDigest,
                        staleStateToken: targetPlan.staleStateToken,
                        planDigest: planReferences[targetID]?.digest,
                        receiptJSON: nil,
                        detail: detail
                    )
                )
                outcomes.append(
                    TargetCapabilityOutcome(
                        targetInstanceID: targetID,
                        adapterID: targetPlan.adapterID,
                        capabilityID: "connection",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: .unchanged,
                        runningInstanceReach: .unavailable,
                        detail: detail
                    )
                )
                currentProgress.steps[ordinal].status = .unchanged(detail: detail)
            }
            try persistence.journalTransitionState(operationID: operation.id, to: .cancelled)
        }

        currentProgress.currentTargetID = nil
        onProgress?(currentProgress)

        let records = try persistence.journalLoadRecords(operationID: operation.id)
        if !cancellationRequested && !records.contains(where: { $0.phase == .applying }) {
            let allFailed = records.allSatisfy { $0.phase == .failed }
            try persistence.journalTransitionState(operationID: operation.id, to: allFailed ? .failed : .applied)
        }

        var combinedOutcomes = outcomes
        if let parentID = plan.retrySourceOperationID, let persistence = self.persistenceStore {
            do {
                let priorOutcomes = try loadLineageOutcomes(for: parentID, persistence: persistence)
                var mergedByID: [TargetInstanceID: TargetCapabilityOutcome] = [:]
                for outcome in priorOutcomes {
                    mergedByID[outcome.targetInstanceID] = outcome
                }
                for outcome in outcomes {
                    mergedByID[outcome.targetInstanceID] = outcome
                }
                combinedOutcomes = Array(mergedByID.values).sorted { left, right in
                    let leftRank = WorkspaceTargetOrder.rank(adapterID: left.adapterID)
                    let rightRank = WorkspaceTargetOrder.rank(adapterID: right.adapterID)
                    if leftRank != rightRank { return leftRank < rightRank }
                    if left.adapterID != right.adapterID { return left.adapterID < right.adapterID }
                    return left.targetInstanceID.rawValue < right.targetInstanceID.rawValue
                }
            } catch {
                combinedOutcomes = outcomes
            }
        }

        return SetupReport(
            operationID: operation.id,
            retrySourceOperationID: plan.retrySourceOperationID,
            outcomes: outcomes,
            combinedOutcomes: combinedOutcomes
        )
    }

    private func retryableSetupTargetIDs(
        from sourceOperationID: UUID,
        persistence: PersistenceStore
    ) throws -> Set<TargetInstanceID> {
        var operationChain: [UUID] = []
        var nextID: UUID? = sourceOperationID
        var visited: Set<UUID> = []

        while let currentID = nextID, !visited.contains(currentID) {
            guard let operation = try persistence.journalLoadOperation(id: currentID) else {
                throw DurableOperationError.operationNotFound(currentID)
            }
            guard operation.kind == .setup else {
                return []
            }
            visited.insert(currentID)
            operationChain.append(currentID)
            nextID = operation.parentOperationID
        }

        var latestRecords: [TargetInstanceID: JournaledRecord] = [:]
        for operationID in operationChain.reversed() {
            for record in try persistence.journalLoadRecords(operationID: operationID) {
                latestRecords[record.targetInstanceID] = record
            }
        }

        return Set(
            latestRecords.values.compactMap { record in
                switch record.phase {
                case .failed, .skipped, .conflicted, .reconciledBefore:
                    return record.targetInstanceID
                case .prepared, .applying, .applied, .rolledBack, .reconciledIntended, .reconciledConflict:
                    return nil
                }
            }
        )
    }

    private func loadLineageOutcomes(
        for parentOperationID: UUID,
        persistence: PersistenceStore
    ) throws -> [TargetCapabilityOutcome] {
        var operationChain: [UUID] = []
        var nextID: UUID? = parentOperationID
        var visited: Set<UUID> = []

        while let currentID = nextID, !visited.contains(currentID) {
            visited.insert(currentID)
            operationChain.append(currentID)
            if let op = try persistence.journalLoadOperation(id: currentID) {
                nextID = op.parentOperationID
            } else {
                break
            }
        }

        var mergedByID: [TargetInstanceID: TargetCapabilityOutcome] = [:]
        for opID in operationChain.reversed() {
            let records = try persistence.journalLoadRecords(operationID: opID)
            for record in records {
                let outcome = try outcome(from: record)
                mergedByID[record.targetInstanceID] = outcome
            }
        }

        return Array(mergedByID.values)
    }

    private func outcome(from record: JournaledRecord) throws -> TargetCapabilityOutcome {
        if let receiptJSON = record.receiptJSON,
            let receiptData = receiptJSON.data(using: .utf8),
            let receipt = try? JSONDecoder().decode(ConnectionReceipt.self, from: receiptData)
        {
            return TargetCapabilityOutcome(
                targetInstanceID: record.targetInstanceID,
                adapterID: record.adapterID,
                capabilityID: record.capabilityID,
                sourceType: .unavailable,
                sourceRevision: "n/a",
                configurationState: receipt.configurationState,
                runningInstanceReach: receipt.runningInstanceReach,
                detail: receipt.detail,
                userActions: Self.activationActions(
                    for: receipt.runningInstanceReach,
                    adapterID: record.adapterID
                )
            )
        }

        let configurationState: ConfigurationState
        switch record.phase {
        case .skipped:
            configurationState = .unchanged
        case .failed:
            if let detail = record.detail?.lowercased() {
                if detail.contains("permission") {
                    configurationState = .permissionRequired
                } else if detail.contains("conflict") {
                    configurationState = .conflicted
                } else if detail.contains("unavailable") {
                    configurationState = .unavailable
                } else {
                    configurationState = .failed
                }
            } else {
                configurationState = .failed
            }
        case .applied:
            configurationState = .updated
        default:
            configurationState = .failed
        }

        return TargetCapabilityOutcome(
            targetInstanceID: record.targetInstanceID,
            adapterID: record.adapterID,
            capabilityID: record.capabilityID,
            sourceType: .unavailable,
            sourceRevision: "n/a",
            configurationState: configurationState,
            runningInstanceReach: .unavailable,
            detail: record.detail
        )
    }

    // MARK: Connect

    public func prepareConnection(
        instance: ConnectedTargetInstance
    ) async throws -> ConnectionPlan {
        guard let adapter = self.connectionAdapter(for: instance.adapterID) else {
            throw DurableOperationError.adapterUnavailable(instance.adapterID)
        }
        return try await adapter.prepareConnection(
            instance: instance,
            approveLinkedSource: false
        )
    }

    public func connect(
        instance: ConnectedTargetInstance,
        workspace: Workspace,
        approveLinkedSource: Bool = false,
        reviewedPlan: ConnectionPlan? = nil
    ) async throws -> ConnectionReport {
        guard let persistence = self.persistenceStore else {
            throw DurableOperationError.persistenceRequired
        }
        try await ensureNoOperationInProgress()
        try await reconcileInterruptedOperations()

        let operation = try persistence.journalStartOperation(
            kind: .connect,
            workspaceID: workspace.id,
            variantID: nil
        )
        try await beginOperationTracking(operation)

        defer { try? closeOperationTracking(operation.id) }
        guard let adapter = self.connectionAdapter(for: instance.adapterID) else {
            try persistence.journalTransitionState(operationID: operation.id, to: .failed)
            return ConnectionReport(
                operationID: operation.id,
                outcomes: [
                    TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: instance.adapterID,
                        capabilityID: "connection",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: .unavailable,
                        runningInstanceReach: .unavailable,
                        detail: "The adapter is unavailable or does not support connect."
                    )
                ]
            )
        }

        var plan: ConnectionPlan
        do {
            if let reviewedPlan {
                guard reviewedPlan.targetInstanceID == instance.id,
                    reviewedPlan.adapterID == adapter.id,
                    reviewedPlan.adapterVersion == adapter.version
                else {
                    throw DurableOperationError.adapterUnavailable(instance.adapterID)
                }
                if approveLinkedSource,
                    let approvingAdapter = adapter as? any ReviewedConnectionApproving
                {
                    plan = try await approvingAdapter.approveReviewedConnection(reviewedPlan)
                } else {
                    plan = approveLinkedSource ? reviewedPlan.approvingReviewedSetup() : reviewedPlan
                }
            } else {
                plan = try await adapter.prepareConnection(
                    instance: instance,
                    approveLinkedSource: approveLinkedSource
                )
            }
        } catch {
            let failure = Self.capabilityOutcome(
                for: error,
                fallbackState: .failed,
                fallbackDetail: "Preparation failed: \(error)"
            )
            try persistence.journalTransitionState(operationID: operation.id, to: .failed)
            return ConnectionReport(
                operationID: operation.id,
                outcomes: [
                    TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: adapter.id,
                        capabilityID: "connection",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: failure.configurationState,
                        runningInstanceReach: failure.activationReach,
                        detail: failure.detail
                    )
                ]
            )
        }

        guard !plan.requiresApproval else {
            try persistence.journalTransitionState(operationID: operation.id, to: .cancelled)
            return ConnectionReport(
                operationID: operation.id,
                outcomes: [
                    TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: adapter.id,
                        capabilityID: "connection",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: .permissionRequired,
                        runningInstanceReach: .unavailable,
                        detail: plan.userActions.first?.detail
                            ?? "Approve the requested setup before connecting.",
                        userActions: Self.permissionActions(
                            setupNeeds: plan.userActions,
                            requiredPermissions: plan.requiredPermissions
                        )
                    )
                ]
            )
        }

        if plan.baselineCaptureTiming == .immediatelyBeforeExecution {
            guard let baselineCapturingAdapter = adapter as? any DeferredConnectionBaselineCapturing else {
                try persistence.journalTransitionState(operationID: operation.id, to: .failed)
                return ConnectionReport(
                    operationID: operation.id,
                    outcomes: [
                        TargetCapabilityOutcome(
                            targetInstanceID: instance.id,
                            adapterID: adapter.id,
                            capabilityID: "connection",
                            sourceType: .unavailable,
                            sourceRevision: "n/a",
                            configurationState: .failed,
                            runningInstanceReach: .unavailable,
                            detail: "The adapter cannot capture its deferred Connection Baseline."
                        )
                    ]
                )
            }
            do {
                let capture = try await baselineCapturingAdapter.captureConnectionBaseline(for: plan)
                plan = plan.recordingExecutionBaseline(capture)
            } catch {
                let failure = Self.capabilityOutcome(
                    for: error,
                    fallbackState: .failed,
                    fallbackDetail: "Execution preparation failed: \(error)"
                )
                try persistence.journalTransitionState(operationID: operation.id, to: .failed)
                return ConnectionReport(
                    operationID: operation.id,
                    outcomes: [
                        TargetCapabilityOutcome(
                            targetInstanceID: instance.id,
                            adapterID: adapter.id,
                            capabilityID: "connection",
                            sourceType: .unavailable,
                            sourceRevision: "n/a",
                            configurationState: failure.configurationState,
                            runningInstanceReach: failure.activationReach,
                            detail: failure.detail,
                            userActions: Self.permissionActions(
                                setupNeeds: plan.userActions,
                                requiredPermissions: plan.requiredPermissions
                            )
                        )
                    ]
                )
            }
        }

        let baselineWasPreviouslyStored =
            try persistence.journalLoadConnectionBaseline(targetInstanceID: instance.id) != nil
        plan = plan.recordingStoredBaseline(baselineWasPreviouslyStored)

        // Durably persist Connection Plan and captured baseline BEFORE any external mutation.
        let planPayload = try JSONEncoder().encode(plan)
        let planReference = try persistence.journalStorePlanPayload(
            planPayload,
            ownerID: "connect.\(operation.id.uuidString).\(instance.id.rawValue)"
        )
        try persistence.saveConnectionPreparation(
            record: JournaledRecord(
                operationID: operation.id,
                targetInstanceID: instance.id,
                ordinal: 0,
                adapterID: adapter.id,
                adapterVersion: adapter.version,
                capabilityID: "connection",
                phase: .prepared,
                intendedChangeDigest: plan.intendedChangeDigest,
                staleStateToken: plan.staleStateToken,
                planDigest: planReference.digest,
                receiptJSON: nil,
                detail: nil
            ),
            baseline: plan.capturedPreChangeState
        )
        try persistence.setTargetInstance(instance, connected: false, workspace: workspace)

        // Cancellation is possible up to here. After this point, the adapter owns
        // final write-boundary validation and the external mutation.
        try await checkAndConsumeCancellation(operation.id)

        try persistence.journalTransitionState(operationID: operation.id, to: .applying)
        try persistence.journalSaveRecord(
            JournaledRecord(
                operationID: operation.id,
                targetInstanceID: instance.id,
                ordinal: 0,
                adapterID: adapter.id,
                adapterVersion: adapter.version,
                capabilityID: "connection",
                phase: .applying,
                intendedChangeDigest: plan.intendedChangeDigest,
                staleStateToken: plan.staleStateToken,
                planDigest: planReference.digest,
                receiptJSON: nil,
                detail: nil
            )
        )
        await markMutationBegun(operation.id)

        let receipt: ConnectionReceipt
        do {
            receipt = try await adapter.connect(plan)
        } catch {
            let mutationNotStarted = error is any ConnectionMutationNotStartedError
            let failure = Self.capabilityOutcome(
                for: error,
                fallbackState: mutationNotStarted ? .conflicted : .failed
            )
            if mutationNotStarted {
                try removeNewConnectionBaseline(for: plan, persistence: persistence)
            }
            let recoveryRequired = error is any MutationRecoveryRequiredError
            let preMutationConflict = mutationNotStarted && failure.configurationState == .conflicted
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: instance.id,
                    ordinal: 0,
                    adapterID: adapter.id,
                    adapterVersion: adapter.version,
                    capabilityID: "connection",
                    phase: recoveryRequired ? .applying : .failed,
                    intendedChangeDigest: plan.intendedChangeDigest,
                    staleStateToken: plan.staleStateToken,
                    planDigest: planReference.digest,
                    receiptJSON: nil,
                    detail: failure.detail
                )
            )
            if !recoveryRequired {
                try persistence.journalTransitionState(operationID: operation.id, to: .failed)
            }
            return ConnectionReport(
                operationID: operation.id,
                outcomes: [
                    TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: adapter.id,
                        capabilityID: "connection",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: failure.configurationState,
                        runningInstanceReach: failure.activationReach,
                        detail: failure.detail,
                        rollbackState: recoveryRequired
                            ? .recoveryRequired
                            : preMutationConflict ? .blocked : .notNeeded,
                        userActions: recoveryRequired
                            ? [Self.recoveryRequiredAction]
                            : failure.configurationState == .permissionRequired
                                ? Self.permissionActions(
                                    setupNeeds: plan.userActions,
                                    requiredPermissions: plan.requiredPermissions
                                )
                                : preMutationConflict ? [Self.reviewExternalChangeAction] : []
                    )
                ]
            )
        }

        let receiptJSON = try encodeReceipt(receipt)
        try persistence.finalizeConnectionOperation(
            record: JournaledRecord(
                operationID: operation.id,
                targetInstanceID: instance.id,
                ordinal: 0,
                adapterID: adapter.id,
                adapterVersion: adapter.version,
                capabilityID: "connection",
                phase: .applied,
                intendedChangeDigest: plan.intendedChangeDigest,
                staleStateToken: plan.staleStateToken,
                planDigest: planReference.digest,
                receiptJSON: receiptJSON,
                detail: receipt.detail
            ),
            instance: instance,
            connected: true,
            workspace: workspace
        )

        return ConnectionReport(
            operationID: operation.id,
            outcomes: [
                TargetCapabilityOutcome(
                    targetInstanceID: instance.id,
                    adapterID: adapter.id,
                    capabilityID: "connection",
                    sourceType: .unavailable,
                    sourceRevision: "n/a",
                    configurationState: receipt.configurationState,
                    runningInstanceReach: receipt.runningInstanceReach,
                    detail: receipt.detail,
                    userActions: Self.activationActions(
                        for: receipt.runningInstanceReach,
                        adapterID: adapter.id
                    )
                )
            ]
        )
    }

    // MARK: Apply (durable)

    public func applyDurable(planID: UUID, workspace: Workspace) async throws -> DurableApplyReport {
        guard let persistence = self.persistenceStore else {
            throw DurableOperationError.persistenceRequired
        }
        try await ensureNoOperationInProgress()
        try await reconcileInterruptedOperations()

        guard let pendingPlan = self.plansInFlight[planID] else {
            throw ThemeEngineError.planNotFound(planID)
        }
        let orderedTargetIDs = WorkspaceTargetOrder.ordered(workspace.connectedTargetInstances).map(\.id)
        let assignmentMatches: Bool
        if let requiredThemeAssignment = pendingPlan.requiredThemeAssignment {
            assignmentMatches = workspace.themeAssignment == requiredThemeAssignment
        } else {
            assignmentMatches =
                workspace.themeAssignment == nil
                || workspace.themeAssignment == .fixed(variantID: pendingPlan.variantID)
        }
        guard pendingPlan.workspaceID == workspace.id,
            pendingPlan.targetInstanceIDs == orderedTargetIDs,
            assignmentMatches
        else {
            throw ThemeEngineError.planWorkspaceChanged(planID)
        }
        guard let plan = self.consumePlan(planID) else {
            throw ThemeEngineError.planNotFound(planID)
        }

        let operation = try persistence.journalStartOperation(
            kind: .apply,
            workspaceID: workspace.id,
            variantID: plan.variantID
        )
        try await beginOperationTracking(operation)
        defer { try? closeOperationTracking(operation.id) }

        // Durably persist all Adapter Plans before any external mutation.
        var planReferences: [TargetInstanceID: ContentReference] = [:]
        for (ordinal, targetPlan) in plan.targetPlans.enumerated() {
            let planPayload = try JSONEncoder().encode(targetPlan)
            let reference = try persistence.journalStorePlanPayload(
                planPayload,
                ownerID: "apply.\(operation.id.uuidString).\(targetPlan.targetInstanceID.rawValue)"
            )
            planReferences[targetPlan.targetInstanceID] = reference
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: targetPlan.targetInstanceID,
                    ordinal: ordinal,
                    adapterID: targetPlan.adapterID,
                    adapterVersion: targetPlan.adapterVersion,
                    capabilityID: targetPlan.capabilityID,
                    phase: .prepared,
                    intendedChangeDigest: targetPlan.intendedChangeDigest,
                    staleStateToken: targetPlan.staleStateToken,
                    planDigest: reference.digest,
                    receiptJSON: nil,
                    detail: nil
                )
            )
        }

        try await checkAndConsumeCancellation(operation.id)

        // Iterate in the deterministic order of plan.targetPlans.
        var outcomes: [TargetCapabilityOutcome] = []
        var anyMutated = false
        for (ordinal, targetPlan) in plan.targetPlans.enumerated() {
            let outcome = try await self.runApplyStep(
                plan: targetPlan,
                ordinal: ordinal,
                operationID: operation.id,
                planReference: planReferences[targetPlan.targetInstanceID],
                markMutation: !anyMutated,
                persistence: persistence
            )
            outcomes.append(outcome)
            if outcome.configurationState == .updated {
                anyMutated = true
            }
        }

        for id in plan.unavailableTargetInstanceIDs {
            outcomes.append(
                TargetCapabilityOutcome(
                    targetInstanceID: id,
                    adapterID: "unavailable",
                    capabilityID: "theme",
                    sourceType: plan.sourceType,
                    sourceRevision: plan.sourceRevision,
                    configurationState: .unavailable,
                    runningInstanceReach: .unavailable,
                    detail: "No compatible adapter prepared this Target Instance."
                )
            )
        }
        for failure in plan.preparationFailures {
            outcomes.append(
                TargetCapabilityOutcome(
                    targetInstanceID: failure.targetInstanceID,
                    adapterID: failure.adapterID,
                    capabilityID: "theme",
                    sourceType: plan.sourceType,
                    sourceRevision: plan.sourceRevision,
                    configurationState: .failed,
                    runningInstanceReach: .unavailable,
                    detail: failure.detail
                )
            )
        }

        let records = try persistence.journalLoadRecords(operationID: operation.id)
        if !records.contains(where: { $0.phase == .applying }) {
            try persistence.journalTransitionState(operationID: operation.id, to: .applied)
        }
        let outcomeOrder = Dictionary(
            uniqueKeysWithValues: plan.targetInstanceIDs.enumerated().map { ($0.element, $0.offset) }
        )
        outcomes.sort { left, right in
            let leftIndex = outcomeOrder[left.targetInstanceID] ?? Int.max
            let rightIndex = outcomeOrder[right.targetInstanceID] ?? Int.max
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return left.capabilityID < right.capabilityID
        }
        return DurableApplyReport(
            operationID: operation.id,
            variantID: plan.variantID,
            outcomes: outcomes
        )
    }

    private func runApplyStep(
        plan: AdapterPlan,
        ordinal: Int,
        operationID: UUID,
        planReference: ContentReference?,
        markMutation: Bool,
        persistence: PersistenceStore
    ) async throws -> TargetCapabilityOutcome {
        guard let adapter = self.adapter(for: plan.adapterID) else {
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operationID,
                    targetInstanceID: plan.targetInstanceID,
                    ordinal: ordinal,
                    adapterID: plan.adapterID,
                    adapterVersion: plan.adapterVersion,
                    capabilityID: plan.capabilityID,
                    phase: .failed,
                    intendedChangeDigest: plan.intendedChangeDigest,
                    staleStateToken: plan.staleStateToken,
                    planDigest: planReference?.digest,
                    receiptJSON: nil,
                    detail: "adapter unavailable"
                )
            )
            return TargetCapabilityOutcome(
                targetInstanceID: plan.targetInstanceID,
                adapterID: plan.adapterID,
                capabilityID: plan.capabilityID,
                sourceType: plan.sourceType,
                sourceRevision: plan.sourceRevision,
                configurationState: .unavailable,
                runningInstanceReach: .unavailable,
                detail: "The adapter is unavailable."
            )
        }

        if !plan.conflicts.isEmpty {
            let conflictDetail = plan.conflicts.joined(separator: "; ")
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operationID,
                    targetInstanceID: plan.targetInstanceID,
                    ordinal: ordinal,
                    adapterID: plan.adapterID,
                    adapterVersion: plan.adapterVersion,
                    capabilityID: plan.capabilityID,
                    phase: .conflicted,
                    intendedChangeDigest: plan.intendedChangeDigest,
                    staleStateToken: plan.staleStateToken,
                    planDigest: planReference?.digest,
                    receiptJSON: nil,
                    detail: conflictDetail
                )
            )
            return TargetCapabilityOutcome(
                targetInstanceID: plan.targetInstanceID,
                adapterID: plan.adapterID,
                capabilityID: plan.capabilityID,
                sourceType: plan.sourceType,
                sourceRevision: plan.sourceRevision,
                configurationState: .conflicted,
                runningInstanceReach: .unavailable,
                detail: conflictDetail,
                rollbackState: .blocked,
                userActions: [Self.reviewExternalChangeAction]
            )
        }



        // Write-boundary revalidation — a changed precondition becomes a conflict.
        if let writable = adapter as? any WritableThemeAdapter {
            do {
                try await writable.revalidateApply(plan: plan)
            } catch let conflict as WriteBoundaryConflict {
                try persistence.journalSaveRecord(
                    JournaledRecord(
                        operationID: operationID,
                        targetInstanceID: plan.targetInstanceID,
                        ordinal: ordinal,
                        adapterID: plan.adapterID,
                        adapterVersion: plan.adapterVersion,
                        capabilityID: plan.capabilityID,
                        phase: .conflicted,
                        intendedChangeDigest: plan.intendedChangeDigest,
                        staleStateToken: plan.staleStateToken,
                        planDigest: planReference?.digest,
                        receiptJSON: nil,
                        detail: conflict.detail
                    )
                )
                return TargetCapabilityOutcome(
                    targetInstanceID: plan.targetInstanceID,
                    adapterID: plan.adapterID,
                    capabilityID: plan.capabilityID,
                    sourceType: plan.sourceType,
                    sourceRevision: plan.sourceRevision,
                    configurationState: .conflicted,
                    runningInstanceReach: .unavailable,
                    detail: conflict.detail,
                    rollbackState: .blocked,
                    userActions: [Self.reviewExternalChangeAction]
                )
            } catch {
                // Target-specific failures such as a revoked permission remain honest
                // Capability Outcomes. Unknown revalidation failures are conflicts.
                let failure = Self.capabilityOutcome(for: error, fallbackState: .conflicted)
                try persistence.journalSaveRecord(
                    JournaledRecord(
                        operationID: operationID,
                        targetInstanceID: plan.targetInstanceID,
                        ordinal: ordinal,
                        adapterID: plan.adapterID,
                        adapterVersion: plan.adapterVersion,
                        capabilityID: plan.capabilityID,
                        phase: failure.configurationState == .conflicted ? .conflicted : .failed,
                        intendedChangeDigest: plan.intendedChangeDigest,
                        staleStateToken: plan.staleStateToken,
                        planDigest: planReference?.digest,
                        receiptJSON: nil,
                        detail: failure.detail
                    )
                )
                return TargetCapabilityOutcome(
                    targetInstanceID: plan.targetInstanceID,
                    adapterID: plan.adapterID,
                    capabilityID: plan.capabilityID,
                    sourceType: plan.sourceType,
                    sourceRevision: plan.sourceRevision,
                    configurationState: failure.configurationState,
                    runningInstanceReach: failure.activationReach,
                    detail: failure.detail,
                    rollbackState: Self.applyRollbackState(
                        configurationState: failure.configurationState
                    ),
                    userActions: Self.applyUserActions(
                        plan: plan,
                        configurationState: failure.configurationState,
                        runningInstanceReach: failure.activationReach
                    )
                )
            }
        }

        try persistence.journalSaveRecord(
            JournaledRecord(
                operationID: operationID,
                targetInstanceID: plan.targetInstanceID,
                ordinal: ordinal,
                adapterID: plan.adapterID,
                adapterVersion: plan.adapterVersion,
                capabilityID: plan.capabilityID,
                phase: .applying,
                intendedChangeDigest: plan.intendedChangeDigest,
                staleStateToken: plan.staleStateToken,
                planDigest: planReference?.digest,
                receiptJSON: nil,
                detail: nil
            )
        )
        if markMutation {
            try persistence.journalTransitionState(operationID: operationID, to: .applying)
            await self.markMutationBegun(operationID)
        }

        let receipt: AdapterReceipt
        do {
            receipt = try await adapter.apply(plan)
        } catch {
            let failure = Self.capabilityOutcome(for: error, fallbackState: .failed)
            let recoveryRequired = error is any MutationRecoveryRequiredError
            if recoveryRequired,
                let recovered = await self.recoverApplyReceipt(plan: plan)
            {
                try persistence.journalSaveRecord(
                    JournaledRecord(
                        operationID: operationID,
                        targetInstanceID: plan.targetInstanceID,
                        ordinal: ordinal,
                        adapterID: plan.adapterID,
                        adapterVersion: plan.adapterVersion,
                        capabilityID: plan.capabilityID,
                        phase: applyRecordPhase(for: recovered),
                        intendedChangeDigest: plan.intendedChangeDigest,
                        staleStateToken: plan.staleStateToken,
                        planDigest: planReference?.digest,
                        receiptJSON: try self.encodeReceipt(recovered),
                        detail: "Recovered after apply error: \(recovered.detail ?? "write completed")"
                    )
                )
                return TargetCapabilityOutcome(
                    targetInstanceID: plan.targetInstanceID,
                    adapterID: plan.adapterID,
                    capabilityID: plan.capabilityID,
                    sourceType: plan.sourceType,
                    sourceRevision: plan.sourceRevision,
                    configurationState: recovered.configurationState,
                    runningInstanceReach: recovered.runningInstanceReach,
                    detail: "Recovered after apply error: \(recovered.detail ?? "write completed")",
                    rollbackState: Self.applyRollbackState(
                        configurationState: recovered.configurationState
                    ),
                    userActions: Self.applyUserActions(
                        plan: plan,
                        configurationState: recovered.configurationState,
                        runningInstanceReach: recovered.runningInstanceReach
                    )
                )
            }
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operationID,
                    targetInstanceID: plan.targetInstanceID,
                    ordinal: ordinal,
                    adapterID: plan.adapterID,
                    adapterVersion: plan.adapterVersion,
                    capabilityID: plan.capabilityID,
                    phase: recoveryRequired ? .applying : .failed,
                    intendedChangeDigest: plan.intendedChangeDigest,
                    staleStateToken: plan.staleStateToken,
                    planDigest: planReference?.digest,
                    receiptJSON: nil,
                    detail: failure.detail
                )
            )
            return TargetCapabilityOutcome(
                targetInstanceID: plan.targetInstanceID,
                adapterID: plan.adapterID,
                capabilityID: plan.capabilityID,
                sourceType: plan.sourceType,
                sourceRevision: plan.sourceRevision,
                configurationState: failure.configurationState,
                runningInstanceReach: failure.activationReach,
                detail: failure.detail,
                rollbackState: recoveryRequired
                    ? .recoveryRequired
                    : Self.applyRollbackState(configurationState: failure.configurationState),
                userActions: Self.applyUserActions(
                    plan: plan,
                    configurationState: failure.configurationState,
                    runningInstanceReach: failure.activationReach,
                    recoveryRequired: recoveryRequired
                )
            )
        }

        // Receipt encoding and persistence are outside the adapter-error path. If
        // either fails after mutation, the applying record remains available for
        // launch reconciliation instead of being misreported as a target failure.
        let receiptJSON = try self.encodeReceipt(receipt)
        try persistence.journalSaveRecord(
            JournaledRecord(
                operationID: operationID,
                targetInstanceID: plan.targetInstanceID,
                ordinal: ordinal,
                adapterID: plan.adapterID,
                adapterVersion: plan.adapterVersion,
                capabilityID: plan.capabilityID,
                phase: applyRecordPhase(for: receipt),
                intendedChangeDigest: plan.intendedChangeDigest,
                staleStateToken: plan.staleStateToken,
                planDigest: planReference?.digest,
                receiptJSON: receiptJSON,
                detail: receipt.detail
            )
        )
        return TargetCapabilityOutcome(
            targetInstanceID: plan.targetInstanceID,
            adapterID: plan.adapterID,
            capabilityID: plan.capabilityID,
            sourceType: plan.sourceType,
            sourceRevision: plan.sourceRevision,
            configurationState: receipt.configurationState,
            runningInstanceReach: receipt.runningInstanceReach,
            detail: receipt.detail,
            rollbackState: Self.applyRollbackState(
                configurationState: receipt.configurationState
            ),
            userActions: Self.applyUserActions(
                plan: plan,
                configurationState: receipt.configurationState,
                runningInstanceReach: receipt.runningInstanceReach
            )
        )
    }

    // MARK: Restore

    public func restore(
        instance: ConnectedTargetInstance,
        workspace: Workspace
    ) async throws -> ConnectionReport {
        guard let persistence = self.persistenceStore else {
            throw DurableOperationError.persistenceRequired
        }
        try await ensureNoOperationInProgress()
        try await reconcileInterruptedOperations()

        guard
            let baseline = try persistence.journalLoadConnectionBaseline(
                targetInstanceID: instance.id
            )
        else {
            throw DurableOperationError.baselineMissing(instance.id)
        }
        guard let adapter = self.connectionAdapter(for: instance.adapterID) else {
            throw DurableOperationError.adapterNotWritable(instance.adapterID)
        }

        let operation = try persistence.journalStartOperation(
            kind: .restore,
            workspaceID: workspace.id,
            variantID: nil
        )
        try await beginOperationTracking(operation)
        defer { try? closeOperationTracking(operation.id) }
        try await checkAndConsumeCancellation(operation.id)
        try persistence.journalTransitionState(operationID: operation.id, to: .applying)
        await markMutationBegun(operation.id)

        let baselineData = try persistence.loadContent(baseline.baselineReference)
        do {
            let receipt = try await adapter.restoreConnection(
                instance: instance,
                baseline: baselineData
            )
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: instance.id,
                    ordinal: 0,
                    adapterID: adapter.id,
                    adapterVersion: adapter.version,
                    capabilityID: "theme",
                    phase: .rolledBack,
                    intendedChangeDigest: "restore",
                    staleStateToken: nil,
                    planDigest: nil,
                    receiptJSON: nil,
                    detail: nil
                )
            )
            try persistence.journalTransitionState(operationID: operation.id, to: .applied)
            return ConnectionReport(
                operationID: operation.id,
                outcomes: [
                    TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: adapter.id,
                        capabilityID: "theme",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: receipt.configurationState,
                        runningInstanceReach: receipt.runningInstanceReach,
                        detail: receipt.detail
                    )
                ]
            )
        } catch {
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: instance.id,
                    ordinal: 0,
                    adapterID: adapter.id,
                    adapterVersion: adapter.version,
                    capabilityID: "theme",
                    phase: .conflicted,
                    intendedChangeDigest: "restore",
                    staleStateToken: nil,
                    planDigest: nil,
                    receiptJSON: nil,
                    detail: String(describing: error)
                )
            )
            try persistence.journalTransitionState(operationID: operation.id, to: .failed)
            return ConnectionReport(
                operationID: operation.id,
                outcomes: [
                    TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: adapter.id,
                        capabilityID: "theme",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: .conflicted,
                        runningInstanceReach: .unavailable,
                        detail: String(describing: error),
                        rollbackState: .blocked,
                        userActions: [Self.reviewExternalChangeAction]
                    )
                ]
            )
        }
    }

    // MARK: Disconnect

    public func disconnect(
        instance: ConnectedTargetInstance,
        workspace: Workspace
    ) async throws -> ConnectionReport {
        guard let persistence = self.persistenceStore else {
            throw DurableOperationError.persistenceRequired
        }
        try await ensureNoOperationInProgress()
        try await reconcileInterruptedOperations()

        guard
            let baseline = try persistence.journalLoadConnectionBaseline(
                targetInstanceID: instance.id
            )
        else {
            throw DurableOperationError.baselineMissing(instance.id)
        }
        guard let adapter = self.connectionAdapter(for: instance.adapterID) else {
            throw DurableOperationError.adapterNotWritable(instance.adapterID)
        }

        let operation = try persistence.journalStartOperation(
            kind: .disconnect,
            workspaceID: workspace.id,
            variantID: nil
        )
        try await beginOperationTracking(operation)
        defer { try? closeOperationTracking(operation.id) }

        let baselineData = try persistence.loadContent(baseline.baselineReference)
        let plan: DisconnectPlan
        do {
            plan = try await adapter.prepareDisconnect(
                instance: instance,
                baseline: baseline,
                baselineData: baselineData
            )
        } catch {
            let failure = Self.capabilityOutcome(for: error, fallbackState: .conflicted)
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: instance.id,
                    ordinal: 0,
                    adapterID: adapter.id,
                    adapterVersion: adapter.version,
                    capabilityID: "disconnect",
                    phase: failure.configurationState == .conflicted ? .conflicted : .failed,
                    intendedChangeDigest: "disconnect.\(baseline.baselineReference.digest)",
                    staleStateToken: nil,
                    planDigest: nil,
                    receiptJSON: nil,
                    detail: failure.detail
                )
            )
            try persistence.journalTransitionState(operationID: operation.id, to: .failed)
            return ConnectionReport(
                operationID: operation.id,
                outcomes: [
                    TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: adapter.id,
                        capabilityID: "disconnect",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: failure.configurationState,
                        runningInstanceReach: failure.activationReach,
                        detail: failure.detail,
                        rollbackState: failure.configurationState == .conflicted ? .blocked : .notNeeded,
                        userActions: Self.connectionOperationFailureActions(
                            configurationState: failure.configurationState,
                            recoveryRequired: false
                        )
                    )
                ]
            )
        }
        let planPayload = try JSONEncoder().encode(plan)
        let planReference = try persistence.journalStorePlanPayload(
            planPayload,
            ownerID: "disconnect.\(operation.id.uuidString).\(instance.id.rawValue)"
        )
        try persistence.journalSaveRecord(
            JournaledRecord(
                operationID: operation.id,
                targetInstanceID: instance.id,
                ordinal: 0,
                adapterID: adapter.id,
                adapterVersion: adapter.version,
                capabilityID: "disconnect",
                phase: .prepared,
                intendedChangeDigest: "disconnect.\(baseline.baselineReference.digest)",
                staleStateToken: plan.staleStateToken,
                planDigest: planReference.digest,
                receiptJSON: nil,
                detail: nil
            )
        )
        try await checkAndConsumeCancellation(operation.id)
        try persistence.journalTransitionState(operationID: operation.id, to: .applying)
        try persistence.journalSaveRecord(
            JournaledRecord(
                operationID: operation.id,
                targetInstanceID: instance.id,
                ordinal: 0,
                adapterID: adapter.id,
                adapterVersion: adapter.version,
                capabilityID: "disconnect",
                phase: .applying,
                intendedChangeDigest: "disconnect.\(baseline.baselineReference.digest)",
                staleStateToken: plan.staleStateToken,
                planDigest: planReference.digest,
                receiptJSON: nil,
                detail: nil
            )
        )
        await markMutationBegun(operation.id)

        do {
            try await adapter.revalidateDisconnect(plan: plan)
            let receipt = try await adapter.disconnect(plan, baseline: baselineData)
            try persistence.finalizeConnectionOperation(
                record: JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: instance.id,
                    ordinal: 0,
                    adapterID: adapter.id,
                    adapterVersion: adapter.version,
                    capabilityID: "disconnect",
                    phase: .applied,
                    intendedChangeDigest: "disconnect.\(baseline.baselineReference.digest)",
                    staleStateToken: plan.staleStateToken,
                    planDigest: planReference.digest,
                    receiptJSON: try? encodeReceipt(receipt),
                    detail: receipt.detail
                ),
                instance: instance,
                connected: false,
                workspace: workspace,
                removeBaseline: true
            )
            return ConnectionReport(
                operationID: operation.id,
                outcomes: [
                    TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: adapter.id,
                        capabilityID: "disconnect",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: receipt.configurationState,
                        runningInstanceReach: receipt.runningInstanceReach,
                        detail: receipt.detail
                    )
                ]
            )
        } catch {
            let recoveryRequired = error is any MutationRecoveryRequiredError
            let fallbackState: ConfigurationState = error is WriteBoundaryConflict ? .conflicted : .failed
            let failure = Self.capabilityOutcome(for: error, fallbackState: fallbackState)
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: instance.id,
                    ordinal: 0,
                    adapterID: adapter.id,
                    adapterVersion: adapter.version,
                    capabilityID: "disconnect",
                    phase: recoveryRequired
                        ? .applying : failure.configurationState == .conflicted ? .conflicted : .failed,
                    intendedChangeDigest: "disconnect.\(baseline.baselineReference.digest)",
                    staleStateToken: plan.staleStateToken,
                    planDigest: planReference.digest,
                    receiptJSON: nil,
                    detail: failure.detail
                )
            )
            if !recoveryRequired {
                try persistence.journalTransitionState(operationID: operation.id, to: .failed)
            }
            return ConnectionReport(
                operationID: operation.id,
                outcomes: [
                    TargetCapabilityOutcome(
                        targetInstanceID: instance.id,
                        adapterID: adapter.id,
                        capabilityID: "disconnect",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: failure.configurationState,
                        runningInstanceReach: failure.activationReach,
                        detail: failure.detail,
                        rollbackState: recoveryRequired
                            ? .recoveryRequired
                            : failure.configurationState == .conflicted ? .blocked : .notNeeded,
                        userActions: Self.connectionOperationFailureActions(
                            configurationState: failure.configurationState,
                            recoveryRequired: recoveryRequired
                        )
                    )
                ]
            )
        }
    }

    // MARK: Cancellation

    /// Requests that a running Setup Transaction stop before its next target boundary.
    /// The current adapter call always completes and any untouched targets are recorded as skipped.
    public func cancelRemainingSetup(operationID: UUID) async throws -> Bool {
        guard let persistence = self.persistenceStore else {
            throw DurableOperationError.persistenceRequired
        }
        if setupPlansInFlight[operationID] != nil {
            recordCancellationRequest(operationID)
            try? persistence.journalRecordCancellationRequest(operationID: operationID)
            return true
        }
        guard currentOperationID == operationID,
            let operation = try persistence.journalLoadOperation(id: operationID),
            operation.kind == .setup,
            (operation.state == .prepared || operation.state == .applying)
        else {
            throw DurableOperationError.cancellationRefused
        }
        recordCancellationRequest(operationID)
        try persistence.journalRecordCancellationRequest(operationID: operationID)
        if operation.state == .prepared {
            try persistence.journalTransitionState(operationID: operationID, to: .cancelled)
        }
        return true
    }

    /// Request cancellation of an in-flight operation. Only permitted before the first mutation.
    public func cancel(operationID: UUID) async throws -> Bool {
        guard let persistence = self.persistenceStore else {
            throw DurableOperationError.persistenceRequired
        }
        guard let operation = try persistence.journalLoadOperation(id: operationID) else {
            throw DurableOperationError.operationNotFound(operationID)
        }
        guard operation.state == .prepared else {
            throw DurableOperationError.cancellationRefused
        }
        self.recordCancellationRequest(operationID)
        try persistence.journalRecordCancellationRequest(operationID: operationID)
        try persistence.journalTransitionState(operationID: operationID, to: .cancelled)
        return true
    }

    // MARK: Undo Last Apply Transaction

    public func undoAvailability(workspace: Workspace) throws -> UndoAvailability {
        guard let persistence = self.persistenceStore,
            let operation = try persistence.journalFindLastAppliedTransaction(workspaceID: workspace.id)
        else {
            return .unavailable
        }
        let changedTargetCount = try persistence.journalLoadRecords(operationID: operation.id)
            .filter { $0.phase == .applied }
            .count
        guard changedTargetCount > 0 else { return .unavailable }
        return .available(
            sourceOperationID: operation.id,
            changedTargetCount: changedTargetCount
        )
    }

    /// Undo the Last Apply Transaction for the given workspace.
    ///
    /// The Last Apply Transaction is the most recent completed apply operation that
    /// changed at least one Target Instance. Undo runs through the same journal and
    /// recovery machinery as apply: it prepares a new `undo` operation, iterates the
    /// Last Apply Transaction's applied per-target records in deterministic order,
    /// and rolls each one back through the writable adapter's guarded rollback.
    ///
    /// - A receipt whose current external state no longer matches the intended
    ///   after-change is left visible as `.conflicted` and is not silently reused
    ///   by a later undo.
    /// - Records that were previously rolled back or marked conflicted are skipped.
    public func undoLast(workspace: Workspace) async throws -> UndoReport {
        guard let persistence = self.persistenceStore else {
            throw DurableOperationError.persistenceRequired
        }
        try await ensureNoOperationInProgress()
        try await reconcileInterruptedOperations()

        guard
            let lat = try persistence.journalFindLastAppliedTransaction(
                workspaceID: workspace.id
            )
        else {
            throw DurableOperationError.noLastApplyTransaction
        }
        let latRecords = try persistence.journalLoadRecords(operationID: lat.id)
        let undoableRecords = latRecords.filter { $0.phase == .applied }

        let operation = try persistence.journalStartOperation(
            kind: .undo,
            workspaceID: workspace.id,
            variantID: lat.variantID
        )
        try await beginOperationTracking(operation)
        defer { try? closeOperationTracking(operation.id) }

        for (ordinal, record) in undoableRecords.enumerated() {
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: record.targetInstanceID,
                    ordinal: ordinal,
                    adapterID: record.adapterID,
                    adapterVersion: record.adapterVersion,
                    capabilityID: record.capabilityID,
                    phase: .prepared,
                    intendedChangeDigest: "undo.\(record.intendedChangeDigest)",
                    staleStateToken: record.staleStateToken,
                    planDigest: record.planDigest,
                    receiptJSON: record.receiptJSON,
                    detail: nil
                )
            )
        }

        try await checkAndConsumeCancellation(operation.id)

        var outcomes: [TargetCapabilityOutcome] = []
        var anyRolledBack = false
        for (ordinal, record) in undoableRecords.enumerated() {
            let outcome = try await self.runUndoStep(
                record: record,
                ordinal: ordinal,
                operationID: operation.id,
                markMutation: !anyRolledBack,
                persistence: persistence
            )
            outcomes.append(outcome)
            if outcome.configurationState == .updated {
                anyRolledBack = true
            }
        }

        let records = try persistence.journalLoadRecords(operationID: operation.id)
        if !records.contains(where: { $0.phase == .applying }) {
            try persistence.journalTransitionState(operationID: operation.id, to: .applied)
        }
        return UndoReport(
            operationID: operation.id,
            sourceOperationID: lat.id,
            outcomes: outcomes
        )
    }

    private func runUndoStep(
        record: JournaledRecord,
        ordinal: Int,
        operationID: UUID,
        markMutation: Bool,
        persistence: PersistenceStore
    ) async throws -> TargetCapabilityOutcome {
        guard let adapter = self.writableAdapter(for: record.adapterID) else {
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operationID,
                    targetInstanceID: record.targetInstanceID,
                    ordinal: ordinal,
                    adapterID: record.adapterID,
                    adapterVersion: record.adapterVersion,
                    capabilityID: record.capabilityID,
                    phase: .failed,
                    intendedChangeDigest: "undo.\(record.intendedChangeDigest)",
                    staleStateToken: record.staleStateToken,
                    planDigest: record.planDigest,
                    receiptJSON: nil,
                    detail: "adapter unavailable"
                )
            )
            return TargetCapabilityOutcome(
                targetInstanceID: record.targetInstanceID,
                adapterID: record.adapterID,
                capabilityID: record.capabilityID,
                sourceType: .unavailable,
                sourceRevision: "n/a",
                configurationState: .unavailable,
                runningInstanceReach: .unavailable,
                detail: "The adapter is unavailable."
            )
        }
        guard let planDigest = record.planDigest else {
            return TargetCapabilityOutcome(
                targetInstanceID: record.targetInstanceID,
                adapterID: record.adapterID,
                capabilityID: record.capabilityID,
                sourceType: .unavailable,
                sourceRevision: "n/a",
                configurationState: .failed,
                runningInstanceReach: .unavailable,
                detail: "The original plan payload is missing."
            )
        }
        let plan: AdapterPlan
        do {
            let bytes = try persistence.journalLoadContent(digest: planDigest)
            plan = try JSONDecoder().decode(AdapterPlan.self, from: bytes)
        } catch {
            return TargetCapabilityOutcome(
                targetInstanceID: record.targetInstanceID,
                adapterID: record.adapterID,
                capabilityID: record.capabilityID,
                sourceType: .unavailable,
                sourceRevision: "n/a",
                configurationState: .failed,
                runningInstanceReach: .unavailable,
                detail: "Could not load the original plan: \(error)"
            )
        }
        guard let receiptJSON = record.receiptJSON,
            let receiptData = receiptJSON.data(using: .utf8),
            let receipt = try? JSONDecoder().decode(AdapterReceipt.self, from: receiptData)
        else {
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operationID,
                    targetInstanceID: record.targetInstanceID,
                    ordinal: ordinal,
                    adapterID: record.adapterID,
                    adapterVersion: record.adapterVersion,
                    capabilityID: record.capabilityID,
                    phase: .failed,
                    intendedChangeDigest: "undo.\(record.intendedChangeDigest)",
                    staleStateToken: record.staleStateToken,
                    planDigest: record.planDigest,
                    receiptJSON: nil,
                    detail: "The original apply receipt is missing or malformed."
                )
            )
            var updated = record
            updated.phase = .conflicted
            try persistence.journalSaveRecord(updated)
            return TargetCapabilityOutcome(
                targetInstanceID: record.targetInstanceID,
                adapterID: record.adapterID,
                capabilityID: record.capabilityID,
                sourceType: .unavailable,
                sourceRevision: "n/a",
                configurationState: .conflicted,
                runningInstanceReach: .unavailable,
                detail: "The original apply receipt is missing or malformed."
            )
        }

        // Mark the undo operation as applying just before the first mutation.
        try persistence.journalSaveRecord(
            JournaledRecord(
                operationID: operationID,
                targetInstanceID: record.targetInstanceID,
                ordinal: ordinal,
                adapterID: record.adapterID,
                adapterVersion: record.adapterVersion,
                capabilityID: record.capabilityID,
                phase: .applying,
                intendedChangeDigest: "undo.\(record.intendedChangeDigest)",
                staleStateToken: record.staleStateToken,
                planDigest: record.planDigest,
                receiptJSON: record.receiptJSON,
                detail: nil
            )
        )
        if markMutation {
            try persistence.journalTransitionState(operationID: operationID, to: .applying)
            await self.markMutationBegun(operationID)
        }

        let undoReceipt: AdapterReceipt
        do {
            if let acknowledged = adapter as? any AcknowledgedRollbackAdapter {
                undoReceipt = try await acknowledged.rollbackApplyWithReceipt(
                    plan: plan,
                    receipt: receipt
                )
            } else {
                try await adapter.rollbackApply(plan: plan, receipt: receipt)
                undoReceipt = AdapterReceipt(
                    configurationState: .updated,
                    runningInstanceReach: receipt.runningInstanceReach,
                    detail: "undone",
                    rollbackData: receipt.rollbackData
                )
            }
        } catch {
            let failure = Self.capabilityOutcome(for: error, fallbackState: .conflicted)
            if error is any MutationRecoveryRequiredError {
                try persistence.journalSaveRecord(
                    JournaledRecord(
                        operationID: operationID,
                        targetInstanceID: record.targetInstanceID,
                        ordinal: ordinal,
                        adapterID: record.adapterID,
                        adapterVersion: record.adapterVersion,
                        capabilityID: record.capabilityID,
                        phase: .applying,
                        intendedChangeDigest: "undo.\(record.intendedChangeDigest)",
                        staleStateToken: record.staleStateToken,
                        planDigest: record.planDigest,
                        receiptJSON: record.receiptJSON,
                        detail: failure.detail
                    )
                )
                return TargetCapabilityOutcome(
                    targetInstanceID: record.targetInstanceID,
                    adapterID: record.adapterID,
                    capabilityID: record.capabilityID,
                    sourceType: plan.sourceType,
                    sourceRevision: plan.sourceRevision,
                    configurationState: failure.configurationState,
                    runningInstanceReach: failure.activationReach,
                    detail: failure.detail,
                    rollbackState: .recoveryRequired,
                    userActions: [Self.recoveryRequiredAction]
                )
            }
            // Guarded rollback refused (external edit or state mismatch) — record as conflicted.
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operationID,
                    targetInstanceID: record.targetInstanceID,
                    ordinal: ordinal,
                    adapterID: record.adapterID,
                    adapterVersion: record.adapterVersion,
                    capabilityID: record.capabilityID,
                    phase: .conflicted,
                    intendedChangeDigest: "undo.\(record.intendedChangeDigest)",
                    staleStateToken: record.staleStateToken,
                    planDigest: record.planDigest,
                    receiptJSON: record.receiptJSON,
                    detail: String(describing: error)
                )
            )
            // A known pre-mutation failure leaves the source receipt available for
            // retry. A guarded refusal after reaching the rollback boundary retires it.
            if !(error is any RollbackMutationNotStartedError) {
                var updated = record
                updated.phase = .conflicted
                try persistence.journalSaveRecord(updated)
            }
            return TargetCapabilityOutcome(
                targetInstanceID: record.targetInstanceID,
                adapterID: record.adapterID,
                capabilityID: record.capabilityID,
                sourceType: plan.sourceType,
                sourceRevision: plan.sourceRevision,
                configurationState: failure.configurationState,
                runningInstanceReach: failure.activationReach,
                detail: failure.detail,
                rollbackState: .blocked,
                userActions: [Self.reviewExternalChangeAction]
            )
        }

        // Persist the fresh Undo acknowledgement before retiring the source receipt.
        try persistence.journalSaveRecord(
            JournaledRecord(
                operationID: operationID,
                targetInstanceID: record.targetInstanceID,
                ordinal: ordinal,
                adapterID: record.adapterID,
                adapterVersion: record.adapterVersion,
                capabilityID: record.capabilityID,
                phase: .applied,
                intendedChangeDigest: "undo.\(record.intendedChangeDigest)",
                staleStateToken: record.staleStateToken,
                planDigest: record.planDigest,
                receiptJSON: try self.encodeReceipt(undoReceipt),
                detail: undoReceipt.detail ?? "undone"
            )
        )
        var updated = record
        updated.phase = .rolledBack
        try persistence.journalSaveRecord(updated)
        return TargetCapabilityOutcome(
            targetInstanceID: record.targetInstanceID,
            adapterID: record.adapterID,
            capabilityID: record.capabilityID,
            sourceType: plan.sourceType,
            sourceRevision: plan.sourceRevision,
            configurationState: undoReceipt.configurationState,
            runningInstanceReach: undoReceipt.runningInstanceReach,
            detail: undoReceipt.detail ?? "undone",
            rollbackState: .restored,
            userActions: Self.activationActions(
                for: undoReceipt.runningInstanceReach,
                adapterID: record.adapterID
            )
        )
    }

    // MARK: Reconciliation

    /// Reconcile any operations left interrupted from a prior run.
    ///
    /// Classifies each per-target record as `beforeChange`, `intendedAfterChange`,
    /// or `conflicting`. Interrupted operations are transitioned to `.reconciled`
    /// before any new mutation is accepted.
    public func reconcileInterruptedOperations() async throws {
        guard let persistence = self.persistenceStore else { return }
        let interrupted = try persistence.journalInterruptedOperations()
        for operation in interrupted {
            var reconciledConnectionState: (TargetInstanceID, Bool)?
            let records = try persistence.journalLoadRecords(operationID: operation.id)
            for record in records
            where record.phase == .applying || record.phase == .prepared
                || (operation.kind == .undo && record.phase == .applied)
            {
                if operation.kind == .undo, record.phase == .applied {
                    try markUndoSourceRolledBack(
                        operation: operation,
                        record: record,
                        persistence: persistence
                    )
                    continue
                }
                let classification = try await self.classify(
                    record: record,
                    operationKind: operation.kind,
                    persistence: persistence
                )
                let recoveredAdapterReceipt: AdapterReceipt?
                let recoveredReceiptJSON: String?
                if operation.kind == .apply, classification == .intendedAfterChange {
                    recoveredAdapterReceipt = try await recoverApplyReceipt(
                        record: record,
                        persistence: persistence
                    )
                    recoveredReceiptJSON = try recoveredAdapterReceipt.map(encodeReceipt)
                } else if operation.kind == .undo, classification == .intendedAfterChange {
                    recoveredAdapterReceipt = try await recoverRollbackReceipt(
                        record: record,
                        persistence: persistence
                    )
                    recoveredReceiptJSON = try recoveredAdapterReceipt.map(encodeReceipt)
                } else if (operation.kind == .connect || operation.kind == .setup),
                    classification == .intendedAfterChange
                {
                    recoveredAdapterReceipt = nil
                    recoveredReceiptJSON = try await recoverConnectionReceipt(
                        record: record,
                        persistence: persistence
                    ).map(encodeReceipt)
                } else {
                    recoveredAdapterReceipt = nil
                    recoveredReceiptJSON = nil
                }
                if operation.kind == .connect, classification == .intendedAfterChange {
                    reconciledConnectionState = (record.targetInstanceID, true)
                } else if operation.kind == .setup, classification == .intendedAfterChange {
                    try persistence.recordRecoveredSetupConnection(
                        targetInstanceID: record.targetInstanceID,
                        adapterID: record.adapterID,
                        workspaceID: operation.workspaceID
                    )
                } else if operation.kind == .disconnect, classification == .intendedAfterChange {
                    reconciledConnectionState = (record.targetInstanceID, false)
                }
                if (operation.kind == .connect || operation.kind == .setup), classification == .beforeChange {
                    try removeNewConnectionBaseline(
                        for: record,
                        persistence: persistence
                    )
                }
                let newPhase: RecordPhase
                switch classification {
                case .beforeChange:
                    if operation.cancellationRequested {
                        newPhase = .skipped
                    } else {
                        newPhase = .reconciledBefore
                    }
                case .intendedAfterChange:
                    if let recoveredAdapterReceipt {
                        newPhase = applyRecordPhase(for: recoveredAdapterReceipt)
                    } else {
                        newPhase = .reconciledIntended
                    }
                case .conflicting: newPhase = .reconciledConflict
                }
                let detailString: String
                if operation.cancellationRequested && classification == .beforeChange {
                    detailString = "Skipped after Cancel Remaining."
                } else if recoveredReceiptJSON != nil {
                    detailString = "reconciled:\(classification.rawValue):receipt-recovered"
                } else {
                    detailString = "reconciled:\(classification.rawValue)"
                }
                try persistence.journalSaveRecord(
                    JournaledRecord(
                        operationID: record.operationID,
                        targetInstanceID: record.targetInstanceID,
                        ordinal: record.ordinal,
                        adapterID: record.adapterID,
                        adapterVersion: record.adapterVersion,
                        capabilityID: record.capabilityID,
                        phase: newPhase,
                        intendedChangeDigest: record.intendedChangeDigest,
                        staleStateToken: record.staleStateToken,
                        planDigest: record.planDigest,
                        receiptJSON: recoveredReceiptJSON,
                        detail: detailString
                    )
                )
                if operation.kind == .undo, classification == .intendedAfterChange {
                    try markUndoSourceRolledBack(
                        operation: operation,
                        record: record,
                        persistence: persistence
                    )
                }
            }
            if reconciledConnectionState == nil,
                let intendedRecord = records.first(where: { $0.phase == .reconciledIntended })
            {
                switch operation.kind {
                case .connect:
                    reconciledConnectionState = (intendedRecord.targetInstanceID, true)
                case .disconnect:
                    reconciledConnectionState = (intendedRecord.targetInstanceID, false)
                case .apply, .undo, .restore, .setup:
                    break
                }
            }
            if operation.cancellationRequested {
                try persistence.journalTransitionState(operationID: operation.id, to: .cancelled)
            } else if let (targetInstanceID, connected) = reconciledConnectionState {
                try persistence.transitionOperation(
                    operationID: operation.id,
                    to: .reconciled,
                    targetInstanceID: targetInstanceID,
                    connected: connected
                )
            } else {
                try persistence.journalTransitionState(operationID: operation.id, to: .reconciled)
            }
        }
    }

    private static func setupProgressStatus(
        configurationState: ConfigurationState,
        activationReach: ActivationReach,
        detail: String,
        isRecoveryRequired: Bool = false
    ) -> SetupProgress.StepStatus {
        if isRecoveryRequired {
            return .recoveryRequired(detail: detail)
        }
        switch configurationState {
        case .updated:
            return .connected(reach: activationReach)
        case .unchanged:
            return .unchanged(detail: detail)
        case .permissionRequired:
            return .needsPermission(detail: detail)
        case .conflicted:
            return .conflict(detail: detail)
        case .failed:
            return .failed(detail: detail)
        case .unavailable:
            return .unavailable(detail: detail)
        }
    }

    private func applyRecordPhase(for receipt: AdapterReceipt) -> RecordPhase {
        switch receipt.configurationState {
        case .updated:
            return .applied
        case .unchanged:
            return .skipped
        case .conflicted:
            return .conflicted
        case .permissionRequired, .failed, .unavailable:
            return .failed
        }
    }

    private func removeNewConnectionBaseline(
        for record: JournaledRecord,
        persistence: PersistenceStore
    ) throws {
        guard let digest = record.planDigest else { return }
        let bytes = try persistence.journalLoadContent(digest: digest)
        guard let plan = try? JSONDecoder().decode(ConnectionPlan.self, from: bytes) else {
            return
        }
        try removeNewConnectionBaseline(for: plan, persistence: persistence)
    }

    private func removeNewConnectionBaseline(
        for plan: ConnectionPlan,
        persistence: PersistenceStore
    ) throws {
        guard !plan.baselineWasPreviouslyStored,
            let stored = try persistence.journalLoadConnectionBaseline(
                targetInstanceID: plan.targetInstanceID
            ),
            try persistence.journalLoadContent(digest: stored.baselineReference.digest)
                == plan.capturedPreChangeState
        else { return }
        try persistence.journalDeleteConnectionBaseline(
            targetInstanceID: plan.targetInstanceID
        )
    }

    private func recoverConnectionReceipt(
        record: JournaledRecord,
        persistence: PersistenceStore
    ) async throws -> ConnectionReceipt? {
        guard let adapter = self.connectionAdapter(for: record.adapterID) as? any RecoverableConnectionAdapter,
            let digest = record.planDigest
        else { return nil }
        let bytes = try persistence.journalLoadContent(digest: digest)
        guard let plan = try? JSONDecoder().decode(ConnectionPlan.self, from: bytes) else {
            return nil
        }
        return try await adapter.recoverConnectionReceipt(plan: plan)
    }

    private func recoverApplyReceipt(plan: AdapterPlan) async -> AdapterReceipt? {
        guard let adapter = self.adapter(for: plan.adapterID) as? any RecoverableApplyAdapter else {
            return nil
        }
        return try? await adapter.recoverApplyReceipt(plan: plan)
    }

    private func recoverApplyReceipt(
        record: JournaledRecord,
        persistence: PersistenceStore
    ) async throws -> AdapterReceipt? {
        guard let digest = record.planDigest else { return nil }
        let bytes = try persistence.journalLoadContent(digest: digest)
        guard let plan = try? JSONDecoder().decode(AdapterPlan.self, from: bytes) else {
            return nil
        }
        return await recoverApplyReceipt(plan: plan)
    }

    private func recoverRollbackReceipt(
        record: JournaledRecord,
        persistence: PersistenceStore
    ) async throws -> AdapterReceipt? {
        guard let adapter = self.adapter(for: record.adapterID) as? any RecoverableRollbackAdapter,
            let digest = record.planDigest,
            let receiptJSON = record.receiptJSON,
            let receiptData = receiptJSON.data(using: .utf8),
            let originalReceipt = try? JSONDecoder().decode(AdapterReceipt.self, from: receiptData)
        else { return nil }
        let bytes = try persistence.journalLoadContent(digest: digest)
        guard let plan = try? JSONDecoder().decode(AdapterPlan.self, from: bytes) else {
            return nil
        }
        return try await adapter.recoverRollbackReceipt(
            plan: plan,
            originalReceipt: originalReceipt
        )
    }

    private func markUndoSourceRolledBack(
        operation: JournaledOperation,
        record: JournaledRecord,
        persistence: PersistenceStore
    ) throws {
        guard
            let source = try persistence.journalFindLastAppliedTransaction(
                workspaceID: operation.workspaceID
            )
        else { return }
        let sourceRecords = try persistence.journalLoadRecords(operationID: source.id)
        guard
            var sourceRecord = sourceRecords.first(where: {
                $0.targetInstanceID == record.targetInstanceID
                    && $0.adapterID == record.adapterID
                    && $0.planDigest == record.planDigest
                    && $0.phase == .applied
            })
        else { return }
        sourceRecord.phase = .rolledBack
        try persistence.journalSaveRecord(sourceRecord)
    }

    private func classify(
        record: JournaledRecord,
        operationKind: OperationKind,
        persistence: PersistenceStore
    ) async throws -> ReconciliationClassification {
        guard let digest = record.planDigest else {
            return .beforeChange
        }
        let bytes = try persistence.journalLoadContent(digest: digest)
        switch operationKind {
        case .connect, .setup:
            if let adapter = self.connectionAdapter(for: record.adapterID),
                let plan = try? JSONDecoder().decode(ConnectionPlan.self, from: bytes)
            {
                return try await adapter.classifyConnection(plan: plan)
            }
        case .disconnect:
            if let adapter = self.connectionAdapter(for: record.adapterID),
                let plan = try? JSONDecoder().decode(DisconnectPlan.self, from: bytes)
            {
                return try await adapter.classifyDisconnect(plan: plan)
            }
        case .apply:
            if let adapter = self.writableAdapter(for: record.adapterID),
                let plan = try? JSONDecoder().decode(AdapterPlan.self, from: bytes)
            {
                return try await adapter.classifyApply(plan: plan)
            }
        case .undo:
            if let adapter = self.writableAdapter(for: record.adapterID),
                let plan = try? JSONDecoder().decode(AdapterPlan.self, from: bytes)
            {
                switch try await adapter.classifyApply(plan: plan) {
                case .beforeChange: return .intendedAfterChange
                case .intendedAfterChange: return .beforeChange
                case .conflicting: return .conflicting
                }
            }
        case .restore:
            return .conflicting
        }
        return .conflicting
    }

    // MARK: Helpers

    internal static let reviewExternalChangeAction = UserAction(
        title: "Review external change",
        detail: "Review the external change before trying again."
    )

    private static let recoveryRequiredAction = UserAction(
        title: "Finish recovery",
        detail: "Restart Oh My Theme to reconcile this Target before trying another change."
    )

    private static func applyRollbackState(
        configurationState: ConfigurationState
    ) -> RollbackState {
        switch configurationState {
        case .updated: .undoAvailable
        case .conflicted: .blocked
        case .unchanged, .permissionRequired, .failed, .unavailable: .notNeeded
        }
    }

    private static func applyUserActions(
        plan: AdapterPlan,
        configurationState: ConfigurationState,
        runningInstanceReach: ActivationReach,
        recoveryRequired: Bool = false
    ) -> [UserAction] {
        if recoveryRequired {
            return [recoveryRequiredAction]
        }

        switch configurationState {
        case .permissionRequired:
            return permissionActions(
                setupNeeds: plan.setupNeeds,
                requiredPermissions: plan.requiredPermissions
            )
        case .conflicted:
            return [reviewExternalChangeAction]
        case .failed:
            return [
                UserAction(
                    title: "Review failure",
                    detail: "Review the failure details before trying again."
                )
            ]
        case .unavailable:
            return [
                UserAction(
                    title: "Connect Target",
                    detail: "Connect this Target, then prepare the Theme Variant again."
                )
            ]
        case .updated, .unchanged:
            return activationActions(for: runningInstanceReach, adapterID: plan.adapterID)
        }
    }

    private static func connectionOperationFailureActions(
        configurationState: ConfigurationState,
        recoveryRequired: Bool
    ) -> [UserAction] {
        if recoveryRequired {
            return [recoveryRequiredAction]
        }
        switch configurationState {
        case .permissionRequired:
            return permissionActions(setupNeeds: [], requiredPermissions: [])
        case .conflicted:
            return [reviewExternalChangeAction]
        case .failed, .unavailable:
            return [
                UserAction(
                    title: "Review failure",
                    detail: "Review the failure details before trying again."
                )
            ]
        case .updated, .unchanged:
            return []
        }
    }

    private static func permissionActions(
        setupNeeds: [UserAction],
        requiredPermissions: [String]
    ) -> [UserAction] {
        if !setupNeeds.isEmpty {
            return setupNeeds
        }
        if !requiredPermissions.isEmpty {
            return requiredPermissions.map {
                UserAction(title: "Grant permission", detail: $0)
            }
        }
        return [
            UserAction(
                title: "Grant permission",
                detail: "Grant the requested permission, then try again."
            )
        ]
    }

    private static func activationActions(
        for reach: ActivationReach,
        adapterID: String
    ) -> [UserAction] {
        switch reach {
        case .reloadRequired:
            let detail =
                adapterID == "ghostty"
                ? "Reload Ghostty to use the saved theme."
                : "Reload this Target to use the saved theme."
            return [UserAction(title: "Reload", detail: detail)]
        case .nextPrompt:
            return [
                UserAction(
                    title: "Start a new prompt",
                    detail: "Start a new prompt to use the saved theme."
                )
            ]
        case .newProcessesOnly:
            return [
                UserAction(
                    title: "Start a new process",
                    detail: "Start a new process to use the saved theme."
                )
            ]
        case .currentInstances, .unavailable:
            return []
        }
    }

    fileprivate func encodeReceipt<T: Encodable>(_ receipt: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        return String(decoding: data, as: UTF8.self)
    }

    fileprivate func connectionAdapter(for id: String) -> (any ConnectionAdapter)? {
        self.connectionAdaptersByID[id]
    }

    fileprivate func writableAdapter(for id: String) -> (any WritableThemeAdapter)? {
        self.adapter(for: id) as? any WritableThemeAdapter
    }
}

// MARK: - Actor-owned in-memory operation tracking

extension ThemeEngine {
    fileprivate var persistenceStore: PersistenceStore? { self.persistenceForOperations }

    fileprivate func adapter(for id: String) -> (any ThemeAdapter)? {
        self.adaptersByID[id]
    }

    fileprivate func consumePlan(_ id: UUID) -> ApplyPlan? {
        self.plansInFlight.removeValue(forKey: id)
    }

    fileprivate func ensureNoOperationInProgress() async throws {
        if self.currentOperationID != nil {
            throw DurableOperationError.operationInProgress
        }
    }

    fileprivate func reserveOperationStart() throws {
        if currentOperationID != nil || isStartingOperation {
            throw DurableOperationError.operationInProgress
        }
        isStartingOperation = true
    }

    fileprivate func releaseOperationStart() {
        isStartingOperation = false
    }

    fileprivate func beginOperationTracking(_ operation: JournaledOperation) async throws {
        if self.currentOperationID != nil {
            throw DurableOperationError.operationInProgress
        }
        isStartingOperation = false
        self.currentOperationID = operation.id
        self.mutationBegun.remove(operation.id)
    }

    fileprivate func closeOperationTracking(_ operationID: UUID) throws {
        if self.currentOperationID == operationID {
            self.currentOperationID = nil
        }
        self.pendingCancellations.remove(operationID)
        self.mutationBegun.remove(operationID)
    }

    fileprivate func recordCancellationRequest(_ operationID: UUID) {
        self.pendingCancellations.insert(operationID)
    }

    fileprivate func checkAndConsumeCancellation(_ operationID: UUID) async throws {
        let isPersistedCancellation =
            (try? persistenceStore?.journalIsCancellationRequested(operationID: operationID)) ?? false
        if self.pendingCancellations.contains(operationID) || isPersistedCancellation {
            self.pendingCancellations.remove(operationID)
            throw DurableOperationError.operationCancelled
        }
    }

    fileprivate func consumeSetupCancellation(_ operationID: UUID) -> Bool {
        let isPersistedCancellation =
            (try? persistenceStore?.journalIsCancellationRequested(operationID: operationID)) ?? false
        let removedFromMemory = pendingCancellations.remove(operationID) != nil
        return removedFromMemory || isPersistedCancellation
    }

    fileprivate func markMutationBegun(_ operationID: UUID) async {
        self.mutationBegun.insert(operationID)
    }
}
