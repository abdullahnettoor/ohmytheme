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

    public func connect(
        instance: ConnectedTargetInstance,
        workspace: Workspace,
        approveLinkedSource: Bool = false
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
        guard let adapter = self.writableAdapter(for: instance.adapterID) else {
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

        let plan: ConnectionPlan
        do {
            plan = try await adapter.prepareConnection(
                instance: instance,
                approveLinkedSource: approveLinkedSource
            )
        } catch {
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
                        detail: "Preparation failed: \(error)"
                    )
                ]
            )
        }

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

        // Cancellation is possible up to here. After this point, we begin mutation.
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
            try await adapter.revalidateConnection(plan: plan)
            receipt = try await adapter.connect(plan)
        } catch {
            try persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operation.id,
                    targetInstanceID: instance.id,
                    ordinal: 0,
                    adapterID: adapter.id,
                    adapterVersion: adapter.version,
                    capabilityID: "connection",
                    phase: .failed,
                    intendedChangeDigest: plan.intendedChangeDigest,
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
                        capabilityID: "connection",
                        sourceType: .unavailable,
                        sourceRevision: "n/a",
                        configurationState: .failed,
                        runningInstanceReach: .unavailable,
                        detail: String(describing: error)
                    )
                ]
            )
        }

        let receiptJSON = try encodeReceipt(receipt)
        try persistence.journalSaveRecord(
            JournaledRecord(
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
            )
        )
        try persistence.journalTransitionState(operationID: operation.id, to: .applied)

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
                    detail: receipt.detail
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
            let outcome = await self.runApplyStep(
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

        try persistence.journalTransitionState(operationID: operation.id, to: .applied)
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
    ) async -> TargetCapabilityOutcome {
        guard let adapter = self.adapter(for: plan.adapterID) else {
            try? persistence.journalSaveRecord(
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
                try? persistence.journalSaveRecord(
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
                    detail: conflict.detail
                )
            } catch {
                // Any other revalidation failure is a conflict — do not mutate.
                try? persistence.journalSaveRecord(
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
                        detail: String(describing: error)
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
                    detail: String(describing: error)
                )
            }
        }

        try? persistence.journalSaveRecord(
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
            try? persistence.journalTransitionState(operationID: operationID, to: .applying)
            await self.markMutationBegun(operationID)
        }

        do {
            let receipt = try await adapter.apply(plan)
            let receiptJSON = try? self.encodeReceipt(receipt)
            try? persistence.journalSaveRecord(
                JournaledRecord(
                    operationID: operationID,
                    targetInstanceID: plan.targetInstanceID,
                    ordinal: ordinal,
                    adapterID: plan.adapterID,
                    adapterVersion: plan.adapterVersion,
                    capabilityID: plan.capabilityID,
                    phase: .applied,
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
                detail: receipt.detail
            )
        } catch {
            try? persistence.journalSaveRecord(
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
                    detail: String(describing: error)
                )
            )
            return TargetCapabilityOutcome(
                targetInstanceID: plan.targetInstanceID,
                adapterID: plan.adapterID,
                capabilityID: plan.capabilityID,
                sourceType: plan.sourceType,
                sourceRevision: plan.sourceRevision,
                configurationState: .failed,
                runningInstanceReach: .unavailable,
                detail: String(describing: error)
            )
        }
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
        guard let adapter = self.writableAdapter(for: instance.adapterID) else {
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
                        configurationState: .updated,
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
                        detail: String(describing: error)
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
        guard let adapter = self.writableAdapter(for: instance.adapterID) else {
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
            try persistence.journalSaveRecord(
                JournaledRecord(
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
                )
            )
            try persistence.journalDeleteConnectionBaseline(targetInstanceID: instance.id)
            try persistence.journalTransitionState(operationID: operation.id, to: .applied)
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
                        detail: String(describing: error)
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
            let outcome = await self.runUndoStep(
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

        try persistence.journalTransitionState(operationID: operation.id, to: .applied)
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
    ) async -> TargetCapabilityOutcome {
        guard let adapter = self.writableAdapter(for: record.adapterID) else {
            try? persistence.journalSaveRecord(
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

        // Mark the undo operation as applying just before the first mutation.
        try? persistence.journalSaveRecord(
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
            try? persistence.journalTransitionState(operationID: operationID, to: .applying)
            await self.markMutationBegun(operationID)
        }

        do {
            try await adapter.rollbackApply(
                plan: plan,
                receipt: AdapterReceipt(
                    configurationState: .updated,
                    runningInstanceReach: .currentInstances,
                    detail: "undo"
                )
            )
            // Mark the undo record as applied and the original apply record as rolled back.
            try? persistence.journalSaveRecord(
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
                    receiptJSON: record.receiptJSON,
                    detail: "undone"
                )
            )
            var updated = record
            updated.phase = .rolledBack
            try? persistence.journalSaveRecord(updated)
            return TargetCapabilityOutcome(
                targetInstanceID: record.targetInstanceID,
                adapterID: record.adapterID,
                capabilityID: record.capabilityID,
                sourceType: .unavailable,
                sourceRevision: "n/a",
                configurationState: .updated,
                runningInstanceReach: .currentInstances,
                detail: "undone"
            )
        } catch {
            // Guarded rollback refused (external edit or state mismatch) — record as conflicted.
            try? persistence.journalSaveRecord(
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
            // Ensure the source record is not silently reused by a later undo:
            // promote it from `.applied` to `.conflicted` so LAT still points at
            // this transaction but the specific receipt is no longer undoable.
            var updated = record
            updated.phase = .conflicted
            try? persistence.journalSaveRecord(updated)
            return TargetCapabilityOutcome(
                targetInstanceID: record.targetInstanceID,
                adapterID: record.adapterID,
                capabilityID: record.capabilityID,
                sourceType: .unavailable,
                sourceRevision: "n/a",
                configurationState: .conflicted,
                runningInstanceReach: .unavailable,
                detail: String(describing: error)
            )
        }
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
            let records = try persistence.journalLoadRecords(operationID: operation.id)
            for record in records where record.phase == .applying || record.phase == .prepared {
                let classification = try await self.classify(
                    record: record,
                    operationKind: operation.kind,
                    persistence: persistence
                )
                let newPhase: RecordPhase
                switch classification {
                case .beforeChange: newPhase = .reconciledBefore
                case .intendedAfterChange: newPhase = .reconciledIntended
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
                        receiptJSON: record.receiptJSON,
                        detail: "reconciled:\(classification.rawValue)"
                    )
                )
            }
            try persistence.journalTransitionState(operationID: operation.id, to: .reconciled)
        }
    }

    private func classify(
        record: JournaledRecord,
        operationKind: OperationKind,
        persistence: PersistenceStore
    ) async throws -> ReconciliationClassification {
        guard let writable = self.writableAdapter(for: record.adapterID) else {
            return .conflicting
        }
        guard let digest = record.planDigest else {
            return .beforeChange
        }
        let bytes = try persistence.journalLoadContent(digest: digest)
        switch operationKind {
        case .connect:
            if let plan = try? JSONDecoder().decode(ConnectionPlan.self, from: bytes) {
                return try await writable.classifyConnection(plan: plan)
            }
        case .disconnect:
            if let plan = try? JSONDecoder().decode(DisconnectPlan.self, from: bytes) {
                return try await writable.classifyDisconnect(plan: plan)
            }
        case .apply, .undo:
            if let plan = try? JSONDecoder().decode(AdapterPlan.self, from: bytes) {
                return try await writable.classifyApply(plan: plan)
            }
        case .restore:
            return .conflicting
        }
        return .conflicting
    }

    // MARK: Helpers

    fileprivate func encodeReceipt<T: Encodable>(_ receipt: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        return String(decoding: data, as: UTF8.self)
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
