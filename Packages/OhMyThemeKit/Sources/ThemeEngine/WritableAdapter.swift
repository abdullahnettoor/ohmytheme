import Foundation
import Persistence
import ThemeModel

/// Classification of a target instance state during crash reconciliation.
public enum ReconciliationClassification: String, Codable, Equatable, Sendable {
    /// The external state matches the plan's captured pre-change state.
    case beforeChange
    /// The external state matches the plan's intended after-change state.
    case intendedAfterChange
    /// The external state matches neither and cannot be safely reconciled.
    case conflicting
}

/// A prepared, immutable, serializable Connection Plan.
public struct ConnectionPlan: Codable, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let adapterVersion: String
    public let capturedPreChangeState: Data
    public let intendedChangeDigest: String
    public let staleStateToken: String?
    public let expectedSideEffects: [String]
    public let requiredPermissions: [String]
    public let userActions: [UserAction]
    public let opaquePayload: Data?
    public let requiresApproval: Bool
    public let baselineWasPreviouslyStored: Bool

    public init(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        adapterVersion: String,
        capturedPreChangeState: Data,
        intendedChangeDigest: String,
        staleStateToken: String? = nil,
        expectedSideEffects: [String] = [],
        requiredPermissions: [String] = [],
        userActions: [UserAction] = [],
        opaquePayload: Data? = nil,
        requiresApproval: Bool = false,
        baselineWasPreviouslyStored: Bool = false
    ) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.capturedPreChangeState = capturedPreChangeState
        self.intendedChangeDigest = intendedChangeDigest
        self.staleStateToken = staleStateToken
        self.expectedSideEffects = expectedSideEffects
        self.requiredPermissions = requiredPermissions
        self.userActions = userActions
        self.opaquePayload = opaquePayload
        self.requiresApproval = requiresApproval
        self.baselineWasPreviouslyStored = baselineWasPreviouslyStored
    }

    public func approvingReviewedSetup() -> ConnectionPlan {
        ConnectionPlan(
            targetInstanceID: targetInstanceID,
            adapterID: adapterID,
            adapterVersion: adapterVersion,
            capturedPreChangeState: capturedPreChangeState,
            intendedChangeDigest: intendedChangeDigest,
            staleStateToken: staleStateToken,
            expectedSideEffects: expectedSideEffects,
            requiredPermissions: requiredPermissions,
            userActions: userActions,
            opaquePayload: opaquePayload,
            requiresApproval: false,
            baselineWasPreviouslyStored: baselineWasPreviouslyStored
        )
    }

    func recordingStoredBaseline(_ wasPreviouslyStored: Bool) -> ConnectionPlan {
        ConnectionPlan(
            targetInstanceID: targetInstanceID,
            adapterID: adapterID,
            adapterVersion: adapterVersion,
            capturedPreChangeState: capturedPreChangeState,
            intendedChangeDigest: intendedChangeDigest,
            staleStateToken: staleStateToken,
            expectedSideEffects: expectedSideEffects,
            requiredPermissions: requiredPermissions,
            userActions: userActions,
            opaquePayload: opaquePayload,
            requiresApproval: requiresApproval,
            baselineWasPreviouslyStored: wasPreviouslyStored
        )
    }

    private enum CodingKeys: String, CodingKey {
        case targetInstanceID
        case adapterID
        case adapterVersion
        case capturedPreChangeState
        case intendedChangeDigest
        case staleStateToken
        case expectedSideEffects
        case requiredPermissions
        case userActions
        case opaquePayload
        case requiresApproval
        case baselineWasPreviouslyStored
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            targetInstanceID: try container.decode(TargetInstanceID.self, forKey: .targetInstanceID),
            adapterID: try container.decode(String.self, forKey: .adapterID),
            adapterVersion: try container.decode(String.self, forKey: .adapterVersion),
            capturedPreChangeState: try container.decode(Data.self, forKey: .capturedPreChangeState),
            intendedChangeDigest: try container.decode(String.self, forKey: .intendedChangeDigest),
            staleStateToken: try container.decodeIfPresent(String.self, forKey: .staleStateToken),
            expectedSideEffects: try container.decodeIfPresent([String].self, forKey: .expectedSideEffects) ?? [],
            requiredPermissions: try container.decodeIfPresent([String].self, forKey: .requiredPermissions) ?? [],
            userActions: try container.decodeIfPresent([UserAction].self, forKey: .userActions) ?? [],
            opaquePayload: try container.decodeIfPresent(Data.self, forKey: .opaquePayload),
            requiresApproval: try container.decodeIfPresent(Bool.self, forKey: .requiresApproval) ?? false,
            baselineWasPreviouslyStored: try container.decodeIfPresent(
                Bool.self,
                forKey: .baselineWasPreviouslyStored
            ) ?? false
        )
    }
}

public struct ConnectionReceipt: Codable, Equatable, Sendable {
    public let configurationState: ConfigurationState
    public let runningInstanceReach: ActivationReach
    public let detail: String?

    public init(
        configurationState: ConfigurationState,
        runningInstanceReach: ActivationReach = .currentInstances,
        detail: String? = nil
    ) {
        self.configurationState = configurationState
        self.runningInstanceReach = runningInstanceReach
        self.detail = detail
    }
}

public struct DisconnectPlan: Codable, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let adapterVersion: String
    public let baselineReference: ContentReference
    public let staleStateToken: String?
    public let opaquePayload: Data?

    public init(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        adapterVersion: String,
        baselineReference: ContentReference,
        staleStateToken: String? = nil,
        opaquePayload: Data? = nil
    ) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.baselineReference = baselineReference
        self.staleStateToken = staleStateToken
        self.opaquePayload = opaquePayload
    }
}

/// Marks an adapter failure that occurred after an external mutation may have
/// completed. The engine leaves its journal record in `applying` so launch or
/// pre-operation reconciliation must classify it before proceeding.
public protocol MutationRecoveryRequiredError: CapabilityOutcomeError {}

/// Marks a connection failure that occurred before the adapter began mutating
/// external state, allowing a newly captured baseline to be discarded safely.
public protocol ConnectionMutationNotStartedError: Error {}

/// Marks an Undo failure known to precede any external mutation. The source
/// apply receipt remains valid so the user can retry after the transient issue.
public protocol RollbackMutationNotStartedError: Error {}

/// A conflict raised when write-boundary revalidation detects that the plan is stale.
public struct WriteBoundaryConflict: ConnectionMutationNotStartedError, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let detail: String

    public init(targetInstanceID: TargetInstanceID, detail: String) {
        self.targetInstanceID = targetInstanceID
        self.detail = detail
    }
}

/// The shared adapter safety contract for any adapter that writes user configuration.
///
/// Implementations must:
/// - Perform **no writes** during any `prepare*` call.
/// - Produce **restart-safe** (immutable, serializable) plans that survive a crash.
/// - Be **idempotent** across the mutation seam **or** classify current state as
///   `beforeChange`, `intendedAfterChange`, or `conflicting` via ``classifyApply(plan:)``.
/// - Revalidate at the write boundary via ``revalidateApply(plan:)``; a stale plan
///   throws ``WriteBoundaryConflict`` and no mutation is performed.
/// - Provide a **guarded** rollback in ``rollbackApply(plan:receipt:)``; the rollback
///   must refuse to overwrite state it cannot prove it still owns.
/// - Stop and report on **external edits**, never force-overwrite.
/// - Never leak baseline bytes or other **sensitive data** into logs or reports.
public protocol RecoverableApplyAdapter: WritableThemeAdapter {
    func recoverApplyReceipt(plan: AdapterPlan) async throws -> AdapterReceipt
}

/// A writable adapter whose Undo operation produces a new target acknowledgement.
/// The engine persists this returned receipt on the Undo record instead of copying
/// the original apply receipt.
public protocol AcknowledgedRollbackAdapter: WritableThemeAdapter {
    func rollbackApplyWithReceipt(
        plan: AdapterPlan,
        receipt: AdapterReceipt
    ) async throws -> AdapterReceipt
}

public protocol RecoverableRollbackAdapter: AcknowledgedRollbackAdapter {
    func recoverRollbackReceipt(
        plan: AdapterPlan,
        originalReceipt: AdapterReceipt
    ) async throws -> AdapterReceipt
}

public protocol RecoverableConnectionAdapter: ConnectionAdapter {
    func recoverConnectionReceipt(plan: ConnectionPlan) async throws -> ConnectionReceipt
}

public protocol ReviewedConnectionApproving: Sendable {
    func approveReviewedConnection(_ plan: ConnectionPlan) async throws -> ConnectionPlan
}

public protocol ConnectionAdapter: Sendable {
    var id: String { get }
    var version: String { get }

    func prepareConnection(
        instance: ConnectedTargetInstance,
        approveLinkedSource: Bool
    ) async throws -> ConnectionPlan
    func connect(_ plan: ConnectionPlan) async throws -> ConnectionReceipt
    func revalidateConnection(plan: ConnectionPlan) async throws
    func classifyConnection(plan: ConnectionPlan) async throws -> ReconciliationClassification
    func restoreConnection(instance: ConnectedTargetInstance, baseline: Data) async throws -> ConnectionReceipt

    func prepareDisconnect(
        instance: ConnectedTargetInstance,
        baseline: StoredConnectionBaseline,
        baselineData: Data
    ) async throws -> DisconnectPlan
    func disconnect(_ plan: DisconnectPlan, baseline: Data) async throws -> AdapterReceipt
    func revalidateDisconnect(plan: DisconnectPlan) async throws
    func classifyDisconnect(plan: DisconnectPlan) async throws -> ReconciliationClassification
}

public protocol WritableThemeAdapter: ThemeAdapter, ConnectionAdapter {
    func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme,
        connectionBaseline: Data?
    ) async throws -> AdapterPlan

    func revalidateApply(plan: AdapterPlan) async throws
    func classifyApply(plan: AdapterPlan) async throws -> ReconciliationClassification
    func rollbackApply(plan: AdapterPlan, receipt: AdapterReceipt) async throws
}

public extension ConnectionAdapter {
    func prepareConnection(instance: ConnectedTargetInstance) async throws -> ConnectionPlan {
        try await prepareConnection(instance: instance, approveLinkedSource: false)
    }

    func prepareDisconnect(
        instance: ConnectedTargetInstance,
        baseline: StoredConnectionBaseline
    ) async throws -> DisconnectPlan {
        try await prepareDisconnect(instance: instance, baseline: baseline, baselineData: Data())
    }
}

public extension WritableThemeAdapter {
    func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme,
        connectionBaseline: Data?
    ) async throws -> AdapterPlan {
        try await prepareApply(instance: instance, theme: theme)
    }
}
