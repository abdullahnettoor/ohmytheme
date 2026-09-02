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

    public init(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        adapterVersion: String,
        capturedPreChangeState: Data,
        intendedChangeDigest: String,
        staleStateToken: String? = nil,
        expectedSideEffects: [String] = [],
        requiredPermissions: [String] = []
    ) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.capturedPreChangeState = capturedPreChangeState
        self.intendedChangeDigest = intendedChangeDigest
        self.staleStateToken = staleStateToken
        self.expectedSideEffects = expectedSideEffects
        self.requiredPermissions = requiredPermissions
    }
}

public struct ConnectionReceipt: Codable, Equatable, Sendable {
    public let configurationState: ConfigurationState
    public let detail: String?

    public init(configurationState: ConfigurationState, detail: String? = nil) {
        self.configurationState = configurationState
        self.detail = detail
    }
}

public struct DisconnectPlan: Codable, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let adapterVersion: String
    public let baselineReference: ContentReference
    public let staleStateToken: String?

    public init(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        adapterVersion: String,
        baselineReference: ContentReference,
        staleStateToken: String? = nil
    ) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.baselineReference = baselineReference
        self.staleStateToken = staleStateToken
    }
}

/// A conflict raised when write-boundary revalidation detects that the plan is stale.
public struct WriteBoundaryConflict: Error, Equatable, Sendable {
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
public protocol WritableThemeAdapter: ThemeAdapter {
    func prepareConnection(instance: ConnectedTargetInstance) async throws -> ConnectionPlan
    func connect(_ plan: ConnectionPlan) async throws -> ConnectionReceipt

    func revalidateApply(plan: AdapterPlan) async throws
    func classifyApply(plan: AdapterPlan) async throws -> ReconciliationClassification
    func rollbackApply(plan: AdapterPlan, receipt: AdapterReceipt) async throws

    func prepareDisconnect(
        instance: ConnectedTargetInstance,
        baseline: StoredConnectionBaseline
    ) async throws -> DisconnectPlan
    func disconnect(_ plan: DisconnectPlan, baseline: Data) async throws -> AdapterReceipt
}
