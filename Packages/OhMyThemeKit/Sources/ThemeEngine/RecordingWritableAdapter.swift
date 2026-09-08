import Foundation
import Persistence
import ThemeModel

public enum InterruptionPoint: String, Sendable, CaseIterable {
    case beforePrepareApply
    case beforeApplyWrite
    case afterApplyWrite
    case beforeConnect
    case afterConnect
    case beforeDisconnect
    case afterDisconnect
    case beforeRollback
    case afterRollback
    case beforeRevalidation
}

public struct InterruptionRequested: Error, Equatable, Sendable {
    public let point: InterruptionPoint
    public init(point: InterruptionPoint) {
        self.point = point
    }
}

/// A recording adapter that fully implements the writable safety contract.
///
/// It maintains an in-process "world state" that stands in for real user configuration.
/// Tests can force an interruption at every named transition point and verify that
/// the durable journal accurately classifies the resulting state.
public actor RecordingWritableAdapter: WritableThemeAdapter, DeferredConnectionBaselineCapturing {
    public let id: String
    public let version = "1"
    public let payloadVersion = "1"

    private var worldState: WorldState
    private let reportsUnchangedForSameBytes: Bool
    private var interruptions: Set<InterruptionPoint> = []
    private var connectedInstances: Set<TargetInstanceID> = []
    private var beforeConnectionPreparationHook: (@Sendable (ConnectedTargetInstance) async throws -> Void)? = nil
    private var beforeConnectHook: (@Sendable (ConnectionPlan) async throws -> Void)? = nil
    private let configuredReach: ActivationReach
    private let configuredSideEffects: [String]
    private let configuredPermissions: [String]
    private let configuredSharedSetupEffects: [ConnectionSharedSetupEffect]
    private let baselineCaptureTiming: ConnectionBaselineCaptureTiming
    private let deniesDeferredBaselineCapture: Bool

    public init(
        id: String = "recording",
        initialWorld: Data = Data("recording-world-initial".utf8),
        reportsUnchangedForSameBytes: Bool = false,
        activationReach: ActivationReach = .currentInstances,
        expectedSideEffects: [String] = ["recording-world:include"],
        requiredPermissions: [String] = [],
        sharedSetupEffects: [ConnectionSharedSetupEffect] = [],
        baselineCaptureTiming: ConnectionBaselineCaptureTiming = .duringPlanPreparation,
        deniesDeferredBaselineCapture: Bool = false
    ) {
        self.id = id
        self.worldState = WorldState(bytes: initialWorld, revision: "rev-0")
        self.reportsUnchangedForSameBytes = reportsUnchangedForSameBytes
        self.configuredReach = activationReach
        self.configuredSideEffects = expectedSideEffects
        self.configuredPermissions = requiredPermissions
        self.configuredSharedSetupEffects = sharedSetupEffects
        self.baselineCaptureTiming = baselineCaptureTiming
        self.deniesDeferredBaselineCapture = deniesDeferredBaselineCapture
    }

    public func setBeforeConnectionPreparationHook(
        _ hook: (@Sendable (ConnectedTargetInstance) async throws -> Void)?
    ) {
        self.beforeConnectionPreparationHook = hook
    }

    public func setBeforeConnectHook(_ hook: (@Sendable (ConnectionPlan) async throws -> Void)?) {
        self.beforeConnectHook = hook
    }

    public func setInterruption(_ point: InterruptionPoint, enabled: Bool) {
        if enabled { interruptions.insert(point) } else { interruptions.remove(point) }
    }

    public func currentWorldBytes() -> Data { worldState.bytes }
    public func currentWorldRevision() -> String { worldState.revision }

    /// Simulate an external edit that bumps the world revision, invalidating any in-flight plan.
    public func mutateWorldExternally(_ newBytes: Data) {
        worldState = WorldState(bytes: newBytes, revision: UUID().uuidString)
    }

    public func isConnected(_ id: TargetInstanceID) -> Bool {
        connectedInstances.contains(id)
    }

    // MARK: ThemeAdapter

    public func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> AdapterPlan {
        try trigger(.beforePrepareApply)
        let artifact: Data
        if let upstreamArtifact = theme.upstreamArtifact {
            artifact = upstreamArtifact
        } else {
            artifact = Data("recording-artifact.\(theme.contentDigest)".utf8)
        }
        return AdapterPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capabilityID: "theme",
            payload: AdapterPayloadEnvelope(
                adapterID: id,
                adapterVersion: version,
                payloadVersion: payloadVersion,
                payload: artifact
            ),
            intendedChangeDigest: theme.contentDigest,
            capturedPreChangeState: worldState.bytes,
            staleStateToken: worldState.revision,
            expectedSideEffects: ["recording-world:update"],
            requiredPermissions: [],
            sourceType: theme.sourceType,
            sourceRevision: theme.sourceRevision,
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: []
        )
    }

    public func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        try trigger(.beforeApplyWrite)
        // Envelope compatibility check (idempotent guard).
        guard plan.payload.adapterID == id,
            plan.payload.adapterVersion == version,
            plan.payload.payloadVersion == payloadVersion
        else {
            throw RecordingWritableAdapterError.incompatiblePayload
        }
        if reportsUnchangedForSameBytes && worldState.bytes == plan.payload.payload {
            return AdapterReceipt(
                configurationState: .unchanged,
                runningInstanceReach: .currentInstances,
                detail: "recording-world-already-selected"
            )
        }
        // Perform the mutation.
        worldState = WorldState(bytes: plan.payload.payload, revision: plan.intendedChangeDigest)
        try trigger(.afterApplyWrite)
        return AdapterReceipt(
            configurationState: .updated,
            runningInstanceReach: .currentInstances,
            detail: "recording-write"
        )
    }

    // MARK: WritableThemeAdapter

    public func prepareConnection(
        instance: ConnectedTargetInstance,
        approveLinkedSource: Bool
    ) async throws -> ConnectionPlan {
        if let beforeConnectionPreparationHook {
            try await beforeConnectionPreparationHook(instance)
        }
        let ownership = SetupOwnershipDetail(
            targetInstanceID: instance.id,
            adapterID: id,
            summary: "Recording adapter configuration for \(instance.displayName).",
            routineDetails: configuredSideEffects,
            isConsequential: !configuredPermissions.isEmpty,
            consequentialDetail: configuredPermissions.isEmpty
                ? nil : "Requires permission: \(configuredPermissions.joined(separator: ", "))"
        )

        return ConnectionPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capturedPreChangeState: baselineCaptureTiming == .duringPlanPreparation ? worldState.bytes : Data(),
            intendedChangeDigest: "connect.\(instance.id.rawValue)",
            staleStateToken: baselineCaptureTiming == .duringPlanPreparation ? worldState.revision : nil,
            expectedSideEffects: configuredSideEffects,
            requiredPermissions: configuredPermissions,
            activationReach: configuredReach,
            ownershipDetail: ownership,
            sharedSetupEffects: configuredSharedSetupEffects,
            baselineCaptureTiming: baselineCaptureTiming
        )
    }

    public func captureConnectionBaseline(
        for reviewedPlan: ConnectionPlan
    ) async throws -> ConnectionBaselineCapture {
        guard !deniesDeferredBaselineCapture else {
            throw RecordingDeferredBaselineError.permissionDenied
        }
        return ConnectionBaselineCapture(
            capturedPreChangeState: worldState.bytes,
            staleStateToken: worldState.revision
        )
    }

    public func connect(_ plan: ConnectionPlan) async throws -> ConnectionReceipt {
        try trigger(.beforeConnect)

        if let beforeConnectHook {
            try await beforeConnectHook(plan)
        }
        guard plan.staleStateToken == worldState.revision else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "world revision changed since prepare"
            )
        }

        worldState = WorldState(
            bytes: worldState.bytes + Data(".connected".utf8),
            revision: "connect-\(plan.targetInstanceID.rawValue)"
        )
        connectedInstances.insert(plan.targetInstanceID)
        try trigger(.afterConnect)
        return ConnectionReceipt(
            configurationState: .updated,
            runningInstanceReach: configuredReach,
            detail: "connected"
        )
    }

    public func revalidateConnection(plan: ConnectionPlan) async throws {
        guard plan.staleStateToken == worldState.revision else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "world revision changed since prepare"
            )
        }
    }

    public func classifyConnection(plan: ConnectionPlan) async throws -> ReconciliationClassification {
        if worldState.bytes == plan.capturedPreChangeState {
            return .beforeChange
        }
        if worldState.revision == "connect-\(plan.targetInstanceID.rawValue)" {
            return .intendedAfterChange
        }
        return .conflicting
    }

    public func restoreConnection(
        instance: ConnectedTargetInstance,
        baseline: Data
    ) async throws -> ConnectionReceipt {
        let suffix = Data(".connected".utf8)
        guard connectedInstances.contains(instance.id),
            worldState.bytes.count >= suffix.count,
            Data(worldState.bytes.suffix(suffix.count)).elementsEqual(suffix)
        else {
            throw RecordingWritableAdapterError.rollbackRefused
        }
        worldState = WorldState(bytes: baseline, revision: "restored")
        connectedInstances.remove(instance.id)
        return ConnectionReceipt(configurationState: .updated, detail: "restored")
    }

    public func revalidateApply(plan: AdapterPlan) async throws {
        try trigger(.beforeRevalidation)
        if let token = plan.staleStateToken, token != worldState.revision {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "world revision \(worldState.revision) does not match plan token \(token)"
            )
        }
    }

    public func classifyApply(plan: AdapterPlan) async throws -> ReconciliationClassification {
        if let captured = plan.capturedPreChangeState, worldState.bytes == captured {
            return .beforeChange
        }
        if worldState.bytes == plan.payload.payload {
            return .intendedAfterChange
        }
        return .conflicting
    }

    public func rollbackApply(plan: AdapterPlan, receipt: AdapterReceipt) async throws {
        try trigger(.beforeRollback)
        // Guarded: only roll back if the current state matches the intended after-change.
        guard worldState.bytes == plan.payload.payload else {
            throw RecordingWritableAdapterError.rollbackRefused
        }
        if let captured = plan.capturedPreChangeState {
            worldState = WorldState(bytes: captured, revision: "rolled-back")
        }
        try trigger(.afterRollback)
    }

    public func prepareDisconnect(
        instance: ConnectedTargetInstance,
        baseline: StoredConnectionBaseline,
        baselineData: Data
    ) async throws -> DisconnectPlan {
        DisconnectPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            baselineReference: baseline.baselineReference,
            staleStateToken: worldState.revision
        )
    }

    public func revalidateDisconnect(plan: DisconnectPlan) async throws {
        guard plan.staleStateToken == worldState.revision else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "world revision changed since prepare"
            )
        }
    }

    public func classifyDisconnect(plan: DisconnectPlan) async throws -> ReconciliationClassification {
        connectedInstances.contains(plan.targetInstanceID) ? .beforeChange : .intendedAfterChange
    }

    public func disconnect(_ plan: DisconnectPlan, baseline: Data) async throws -> AdapterReceipt {
        try trigger(.beforeDisconnect)
        // Guarded: don't overwrite non-owned state.
        guard connectedInstances.contains(plan.targetInstanceID) else {
            throw RecordingWritableAdapterError.notConnected
        }
        worldState = WorldState(bytes: baseline, revision: "disconnected")
        connectedInstances.remove(plan.targetInstanceID)
        try trigger(.afterDisconnect)
        return AdapterReceipt(
            configurationState: .updated,
            runningInstanceReach: .currentInstances,
            detail: "disconnected"
        )
    }

    // MARK: Private

    private struct WorldState {
        let bytes: Data
        let revision: String
    }

    private func trigger(_ point: InterruptionPoint) throws {
        if interruptions.contains(point) {
            interruptions.remove(point)
            throw InterruptionRequested(point: point)
        }
    }
}

public enum RecordingDeferredBaselineError: CapabilityOutcomeError, Equatable, Sendable {
    case permissionDenied

    public var capabilityConfigurationState: ConfigurationState { .permissionRequired }
    public var capabilityActivationReach: ActivationReach { .unavailable }
    public var capabilityOutcomeDetail: String { "Permission was denied while capturing the Connection Baseline." }
}

public enum RecordingWritableAdapterError: Error, Equatable, Sendable {
    case incompatiblePayload
    case rollbackRefused
    case notConnected
}

public struct RecordingConnectionPermissionDeniedError: ConnectionMutationNotStartedError, CapabilityOutcomeError,
    Equatable, Sendable
{
    public init() {}
    public var capabilityConfigurationState: ConfigurationState { .permissionRequired }
    public var capabilityActivationReach: ActivationReach { .unavailable }
    public var capabilityOutcomeDetail: String { "Permission was denied during target connection." }
}

public struct RecordingConnectionConflictError: ConnectionMutationNotStartedError, CapabilityOutcomeError, Equatable,
    Sendable
{
    public init() {}
    public var capabilityConfigurationState: ConfigurationState { .conflicted }
    public var capabilityActivationReach: ActivationReach { .unavailable }
    public var capabilityOutcomeDetail: String {
        "Target configuration was externally modified before connection started."
    }
}

public struct RecordingConnectionFailedError: ConnectionMutationNotStartedError, CapabilityOutcomeError, Equatable,
    Sendable
{
    public init() {}
    public var capabilityConfigurationState: ConfigurationState { .failed }
    public var capabilityActivationReach: ActivationReach { .unavailable }
    public var capabilityOutcomeDetail: String { "Connection failed unexpectedly before mutation started." }
}

public struct RecordingConnectionUnavailableError: CapabilityOutcomeError, Equatable, Sendable {
    public init() {}
    public var capabilityConfigurationState: ConfigurationState { .unavailable }
    public var capabilityActivationReach: ActivationReach { .unavailable }
    public var capabilityOutcomeDetail: String { "Target instance cannot be reached." }
}
