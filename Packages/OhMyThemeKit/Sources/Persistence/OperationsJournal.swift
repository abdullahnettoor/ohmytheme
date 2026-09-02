import Foundation
import GRDB
import ThemeModel

public enum OperationKind: String, Codable, Sendable {
    case connect
    case apply
    case restore
    case disconnect
    case undo
}

public enum OperationState: String, Codable, Sendable {
    case prepared
    case applying
    case applied
    case cancelled
    case failed
    case reconciled
}

public enum RecordPhase: String, Codable, Sendable {
    case prepared
    case applying
    case applied
    case conflicted
    case failed
    case rolledBack = "rolled-back"
    case reconciledBefore = "reconciled-before"
    case reconciledIntended = "reconciled-intended"
    case reconciledConflict = "reconciled-conflict"
}

public struct JournaledOperation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: OperationKind
    public var state: OperationState
    public let workspaceID: WorkspaceID
    public let variantID: String?
    public let createdAt: Date

    public init(
        id: UUID,
        kind: OperationKind,
        state: OperationState,
        workspaceID: WorkspaceID,
        variantID: String?,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.workspaceID = workspaceID
        self.variantID = variantID
        self.createdAt = createdAt
    }
}

public struct JournaledRecord: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let targetInstanceID: TargetInstanceID
    public let ordinal: Int
    public let adapterID: String
    public let adapterVersion: String
    public let capabilityID: String
    public var phase: RecordPhase
    public let intendedChangeDigest: String
    public let staleStateToken: String?
    public let planDigest: String?
    public let receiptJSON: String?
    public let detail: String?

    public init(
        operationID: UUID,
        targetInstanceID: TargetInstanceID,
        ordinal: Int,
        adapterID: String,
        adapterVersion: String,
        capabilityID: String,
        phase: RecordPhase,
        intendedChangeDigest: String,
        staleStateToken: String?,
        planDigest: String?,
        receiptJSON: String?,
        detail: String?
    ) {
        self.operationID = operationID
        self.targetInstanceID = targetInstanceID
        self.ordinal = ordinal
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.capabilityID = capabilityID
        self.phase = phase
        self.intendedChangeDigest = intendedChangeDigest
        self.staleStateToken = staleStateToken
        self.planDigest = planDigest
        self.receiptJSON = receiptJSON
        self.detail = detail
    }
}

public struct StoredConnectionBaseline: Codable, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let adapterVersion: String
    public let baselineReference: ContentReference
    public let capturedAt: Date

    public init(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        adapterVersion: String,
        baselineReference: ContentReference,
        capturedAt: Date
    ) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.baselineReference = baselineReference
        self.capturedAt = capturedAt
    }
}

extension PersistenceStore {
    public func journalStartOperation(
        kind: OperationKind,
        workspaceID: WorkspaceID,
        variantID: String? = nil
    ) throws -> JournaledOperation {
        let operation = JournaledOperation(
            id: UUID(),
            kind: kind,
            state: .prepared,
            workspaceID: workspaceID,
            variantID: variantID,
            createdAt: Date()
        )
        try withWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO operations (id, kind, state, workspace_id, variant_id, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    operation.id.uuidString,
                    operation.kind.rawValue,
                    operation.state.rawValue,
                    operation.workspaceID.rawValue,
                    operation.variantID,
                    operation.createdAt.timeIntervalSince1970,
                ]
            )
        }
        return operation
    }

    public func journalSaveRecord(_ record: JournaledRecord) throws {
        try withWrite { database in
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO operation_records (
                        operation_id, target_instance_id, ordinal,
                        adapter_id, adapter_version, capability_id, phase,
                        intended_change_digest, stale_state_token,
                        plan_digest, receipt_json, detail
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.operationID.uuidString,
                    record.targetInstanceID.rawValue,
                    record.ordinal,
                    record.adapterID,
                    record.adapterVersion,
                    record.capabilityID,
                    record.phase.rawValue,
                    record.intendedChangeDigest,
                    record.staleStateToken,
                    record.planDigest,
                    record.receiptJSON,
                    record.detail,
                ]
            )
        }
    }

    public func journalTransitionState(operationID: UUID, to state: OperationState) throws {
        try withWrite { database in
            try database.execute(
                sql: "UPDATE operations SET state = ? WHERE id = ?",
                arguments: [state.rawValue, operationID.uuidString]
            )
        }
    }

    public func journalLoadOperation(id: UUID) throws -> JournaledOperation? {
        try withRead { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, kind, state, workspace_id, variant_id, created_at
                        FROM operations WHERE id = ?
                        """,
                    arguments: [id.uuidString]
                )
            else { return nil }
            return try Self.decode(operationRow: row)
        }
    }

    /// Returns the most recent completed Apply Transaction for `workspaceID`
    /// that changed at least one Target Instance. This is the Last Apply
    /// Transaction and stays valid until a replacement apply reaches terminal states.
    public func journalFindLastAppliedTransaction(
        workspaceID: WorkspaceID
    ) throws -> JournaledOperation? {
        try withRead { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT o.id, o.kind, o.state, o.workspace_id, o.variant_id, o.created_at
                    FROM operations o
                    WHERE o.kind = 'apply'
                      AND o.state IN ('applied', 'reconciled')
                      AND o.workspace_id = ?
                      AND EXISTS (
                        SELECT 1 FROM operation_records r
                        WHERE r.operation_id = o.id AND r.phase = 'applied'
                      )
                    ORDER BY o.created_at DESC
                    LIMIT 1
                    """,
                arguments: [workspaceID.rawValue]
            )
            return try rows.first.map(Self.decode(operationRow:))
        }
    }

    public func journalLoadRecords(operationID: UUID) throws -> [JournaledRecord] {
        try withRead { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT operation_id, target_instance_id, ordinal,
                           adapter_id, adapter_version, capability_id, phase,
                           intended_change_digest, stale_state_token,
                           plan_digest, receipt_json, detail
                    FROM operation_records
                    WHERE operation_id = ? ORDER BY ordinal
                    """,
                arguments: [operationID.uuidString]
            )
            return try rows.map(Self.decode(recordRow:))
        }
    }

    public func journalInterruptedOperations() throws -> [JournaledOperation] {
        try withRead { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, kind, state, workspace_id, variant_id, created_at
                    FROM operations WHERE state IN ('prepared', 'applying')
                    ORDER BY created_at
                    """
            )
            return try rows.map(Self.decode(operationRow:))
        }
    }

    public func journalSaveConnectionBaseline(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        adapterVersion: String,
        baseline: Data,
        capturedAt: Date = Date()
    ) throws -> StoredConnectionBaseline {
        let reference = try contentStore.put(baseline)
        try withWrite { database in
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO content_references (digest, byte_count, kind, owner_id)
                    VALUES (?, ?, 'connection-baseline', ?)
                    """,
                arguments: [reference.digest, reference.byteCount, targetInstanceID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO connection_baselines
                        (target_instance_id, adapter_id, adapter_version, baseline_digest, captured_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    targetInstanceID.rawValue,
                    adapterID,
                    adapterVersion,
                    reference.digest,
                    capturedAt.timeIntervalSince1970,
                ]
            )
        }
        return StoredConnectionBaseline(
            targetInstanceID: targetInstanceID,
            adapterID: adapterID,
            adapterVersion: adapterVersion,
            baselineReference: reference,
            capturedAt: capturedAt
        )
    }

    public func journalLoadConnectionBaseline(
        targetInstanceID: TargetInstanceID
    ) throws -> StoredConnectionBaseline? {
        try withRead { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT cb.target_instance_id, cb.adapter_id, cb.adapter_version,
                               cb.baseline_digest, cb.captured_at, cr.byte_count
                        FROM connection_baselines cb
                        JOIN content_references cr ON cr.digest = cb.baseline_digest
                        WHERE cb.target_instance_id = ?
                        """,
                    arguments: [targetInstanceID.rawValue]
                )
            else { return nil }
            let digest: String = row["baseline_digest"]
            let byteCount: Int = row["byte_count"]
            let captured: Double = row["captured_at"]
            return StoredConnectionBaseline(
                targetInstanceID: TargetInstanceID(rawValue: row["target_instance_id"]),
                adapterID: row["adapter_id"],
                adapterVersion: row["adapter_version"],
                baselineReference: ContentReference(digest: digest, byteCount: byteCount),
                capturedAt: Date(timeIntervalSince1970: captured)
            )
        }
    }

    public func journalDeleteConnectionBaseline(targetInstanceID: TargetInstanceID) throws {
        try withWrite { database in
            try database.execute(
                sql: "DELETE FROM connection_baselines WHERE target_instance_id = ?",
                arguments: [targetInstanceID.rawValue]
            )
        }
    }

    // Testing / internal use: for content-store-backed plan payloads.
    public func journalStorePlanPayload(_ data: Data, ownerID: String) throws -> ContentReference {
        try saveContent(data, kind: "adapter-plan", ownerID: ownerID)
    }

    public func journalLoadPlanPayload(_ reference: ContentReference) throws -> Data {
        try loadContent(reference)
    }

    /// Load content bytes when only the digest is known. Byte count is looked up from `content_references`.
    public func journalLoadContent(digest: String) throws -> Data {
        try withRead { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: "SELECT byte_count FROM content_references WHERE digest = ?",
                    arguments: [digest]
                )
            else {
                throw ContentStoreError.missingContent(digest)
            }
            let byteCount: Int = row["byte_count"]
            return try contentStore.get(ContentReference(digest: digest, byteCount: byteCount))
        }
    }

    private static func decode(operationRow row: Row) throws -> JournaledOperation {
        let idString: String = row["id"]
        guard let id = UUID(uuidString: idString) else {
            throw PersistenceError.invalidAssignment
        }
        let created: Double = row["created_at"]
        let kindString: String = row["kind"]
        let stateString: String = row["state"]
        guard let kind = OperationKind(rawValue: kindString),
            let state = OperationState(rawValue: stateString)
        else {
            throw PersistenceError.invalidAssignment
        }
        return JournaledOperation(
            id: id,
            kind: kind,
            state: state,
            workspaceID: WorkspaceID(rawValue: row["workspace_id"]),
            variantID: row["variant_id"],
            createdAt: Date(timeIntervalSince1970: created)
        )
    }

    private static func decode(recordRow row: Row) throws -> JournaledRecord {
        let opString: String = row["operation_id"]
        guard let opID = UUID(uuidString: opString) else {
            throw PersistenceError.invalidAssignment
        }
        let phaseString: String = row["phase"]
        guard let phase = RecordPhase(rawValue: phaseString) else {
            throw PersistenceError.invalidAssignment
        }
        return JournaledRecord(
            operationID: opID,
            targetInstanceID: TargetInstanceID(rawValue: row["target_instance_id"]),
            ordinal: row["ordinal"],
            adapterID: row["adapter_id"],
            adapterVersion: row["adapter_version"],
            capabilityID: row["capability_id"],
            phase: phase,
            intendedChangeDigest: row["intended_change_digest"],
            staleStateToken: row["stale_state_token"],
            planDigest: row["plan_digest"],
            receiptJSON: row["receipt_json"],
            detail: row["detail"]
        )
    }
}
