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

        let baselineWasPreviouslyStored =
            try persistence.journalLoadConnectionBaseline(targetInstanceID: instance.id) != nil
        plan = plan.recordingStoredBaseline(baselineWasPreviouslyStored)

        // Durably persist Connection Plan and captured baseline BEFORE any external mutation.
        let planPayload = try JSONEncoder().encode(plan)
        let planReference = try persistence.journalStorePlanPayload(
            planPayload,
            ownerID: "connect.\(operation.id.uuidString).\(instance.id.rawValue)"
        )
        _ = try persistence.journalSaveConnectionBaseline(
            targetInstanceID: instance.id,
            adapterID: adapter.id,
            adapterVersion: adapter.version,
            baseline: plan.capturedPreChangeState
        )
        try persistence.journalSaveRecord(
            JournaledRecord(
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
            )
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
                            : mutationNotStarted ? .blocked : .notNeeded,
                        userActions: recoveryRequired
                            ? [Self.recoveryRequiredAction]
                            : failure.configurationState == .permissionRequired
                                ? Self.permissionActions(
                                    setupNeeds: plan.userActions,
                                    requiredPermissions: plan.requiredPermissions
                                )
                                : mutationNotStarted ? [Self.reviewExternalChangeAction] : []
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

    public func applyDurable(previewID: UUID, workspace: Workspace) async throws -> DurableApplyReport {
        guard let persistence = self.persistenceStore else {
            throw DurableOperationError.persistenceRequired
        }
        try await ensureNoOperationInProgress()
        try await reconcileInterruptedOperations()

        guard let pendingPreview = self.previewsInFlight[previewID] else {
            throw ThemeEngineError.previewNotFound(previewID)
        }
        let orderedTargetIDs = WorkspaceTargetOrder.ordered(workspace.connectedTargetInstances).map(\.id)
        let assignmentMatches: Bool
        if let requiredThemeAssignment = pendingPreview.requiredThemeAssignment {
            assignmentMatches = workspace.themeAssignment == requiredThemeAssignment
        } else {
            assignmentMatches =
                workspace.themeAssignment == nil
                || workspace.themeAssignment == .fixed(variantID: pendingPreview.variantID)
        }
        guard pendingPreview.workspaceID == workspace.id,
            pendingPreview.targetInstanceIDs == orderedTargetIDs,
            assignmentMatches
        else {
            throw ThemeEngineError.previewWorkspaceChanged(previewID)
        }
        guard let preview = self.consumePreview(previewID) else {
            throw ThemeEngineError.previewNotFound(previewID)
        }

        let operation = try persistence.journalStartOperation(
            kind: .apply,
            workspaceID: workspace.id,
            variantID: preview.variantID
        )
        try await beginOperationTracking(operation)
        defer { try? closeOperationTracking(operation.id) }

        // Durably persist all Adapter Plans before any external mutation.
        var planReferences: [TargetInstanceID: ContentReference] = [:]
        for (ordinal, plan) in preview.targetPlans.enumerated() {
            let planPayload = try JSONEncoder().encode(plan)
            let reference = try persistence.journalStorePlanPayload(
                planPayload,
                ownerID: "apply.\(operation.id.uuidString).\(plan.targetInstanceID.rawValue)"
            )
            planReferences[plan.targetInstanceID] = reference
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: plan.targetInstanceID,
                    ordinal: ordinal,
                    adapterID: plan.adapterID,
                    adapterVersion: plan.adapterVersion,
                    capabilityID: plan.capabilityID,
                    phase: .prepared,
                    intendedChangeDigest: plan.intendedChangeDigest,
                    staleStateToken: plan.staleStateToken,
                    planDigest: reference.digest,
                    receiptJSON: nil,
                    detail: nil
                )
            )
        }

        try await checkAndConsumeCancellation(operation.id)

        // Iterate in the deterministic order of preview.targetPlans.
        var outcomes: [TargetCapabilityOutcome] = []
        var anyMutated = false
        for (ordinal, plan) in preview.targetPlans.enumerated() {
            let outcome = try await self.runApplyStep(
                plan: plan,
                ordinal: ordinal,
                operationID: operation.id,
                planReference: planReferences[plan.targetInstanceID],
                markMutation: !anyMutated,
                persistence: persistence
            )
            outcomes.append(outcome)
            if outcome.configurationState == .updated {
                anyMutated = true
            }
        }

        for id in preview.unavailableTargetInstanceIDs {
            outcomes.append(
                TargetCapabilityOutcome(
                    targetInstanceID: id,
                    adapterID: "unavailable",
                    capabilityID: "theme",
                    sourceType: preview.sourceType,
                    sourceRevision: preview.sourceRevision,
                    configurationState: .unavailable,
                    runningInstanceReach: .unavailable,
                    detail: "No compatible adapter prepared this Target Instance."
                )
            )
        }
        for failure in preview.preparationFailures {
            outcomes.append(
                TargetCapabilityOutcome(
                    targetInstanceID: failure.targetInstanceID,
                    adapterID: failure.adapterID,
                    capabilityID: "theme",
                    sourceType: preview.sourceType,
                    sourceRevision: preview.sourceRevision,
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
            uniqueKeysWithValues: preview.targetInstanceIDs.enumerated().map { ($0.element, $0.offset) }
        )
        outcomes.sort { left, right in
            let leftIndex = outcomeOrder[left.targetInstanceID] ?? Int.max
            let rightIndex = outcomeOrder[right.targetInstanceID] ?? Int.max
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return left.capabilityID < right.capabilityID
        }
        return DurableApplyReport(
            operationID: operation.id,
            variantID: preview.variantID,
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
        let plan = try await adapter.prepareDisconnect(
            instance: instance,
            baseline: baseline,
            baselineData: baselineData
        )
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
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: instance.id,
                    ordinal: 0,
                    adapterID: adapter.id,
                    adapterVersion: adapter.version,
                    capabilityID: "disconnect",
                    phase: .failed,
                    intendedChangeDigest: "disconnect.\(baseline.baselineReference.digest)",
                    staleStateToken: plan.staleStateToken,
                    planDigest: planReference.digest,
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
                        capabilityID: "disconnect",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: .failed,
                        runningInstanceReach: .unavailable,
                        detail: String(describing: error),
                        rollbackState: error is any MutationRecoveryRequiredError
                            ? .recoveryRequired : .blocked,
                        userActions: error is any MutationRecoveryRequiredError
                            ? [Self.recoveryRequiredAction]
                            : [Self.reviewExternalChangeAction]
                    )
                ]
            )
        }
    }

    // MARK: Cancellation

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
                } else if operation.kind == .connect, classification == .intendedAfterChange {
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
                } else if operation.kind == .disconnect, classification == .intendedAfterChange {
                    reconciledConnectionState = (record.targetInstanceID, false)
                }
                if operation.kind == .connect, classification == .beforeChange {
                    try removeNewConnectionBaseline(
                        for: record,
                        persistence: persistence
                    )
                }
                let newPhase: RecordPhase
                switch classification {
                case .beforeChange: newPhase = .reconciledBefore
                case .intendedAfterChange:
                    if let recoveredAdapterReceipt {
                        newPhase = applyRecordPhase(for: recoveredAdapterReceipt)
                    } else {
                        newPhase = .reconciledIntended
                    }
                case .conflicting: newPhase = .reconciledConflict
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
                        detail: recoveredReceiptJSON == nil
                            ? "reconciled:\(classification.rawValue)"
                            : "reconciled:\(classification.rawValue):receipt-recovered"
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
                case .apply, .undo, .restore:
                    break
                }
            }
            if let (targetInstanceID, connected) = reconciledConnectionState {
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
        case .connect:
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

    private static let reviewExternalChangeAction = UserAction(
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

    fileprivate func consumePreview(_ id: UUID) -> ThemePreview? {
        self.previewsInFlight.removeValue(forKey: id)
    }

    fileprivate func ensureNoOperationInProgress() async throws {
        if self.currentOperationID != nil {
            throw DurableOperationError.operationInProgress
        }
    }

    fileprivate func beginOperationTracking(_ operation: JournaledOperation) async throws {
        if self.currentOperationID != nil {
            throw DurableOperationError.operationInProgress
        }
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
        if self.pendingCancellations.contains(operationID) {
            self.pendingCancellations.remove(operationID)
            throw DurableOperationError.cancellationRefused
        }
    }

    fileprivate func markMutationBegun(_ operationID: UUID) async {
        self.mutationBegun.insert(operationID)
    }
}
