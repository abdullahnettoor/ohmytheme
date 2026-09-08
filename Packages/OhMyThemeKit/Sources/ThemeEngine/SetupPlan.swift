import CryptoKit
import Foundation
import ThemeModel

/// A preparation failure for a selected target instance during Setup Plan creation.
public struct TargetSetupPreparationFailure: Codable, Equatable, Sendable, Identifiable {
    public var id: TargetInstanceID { targetInstanceID }
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let configurationState: ConfigurationState
    public let detail: String

    public init(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        configurationState: ConfigurationState = .failed,
        detail: String
    ) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.configurationState = configurationState
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case targetInstanceID
        case adapterID
        case configurationState
        case detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetInstanceID = try container.decode(TargetInstanceID.self, forKey: .targetInstanceID)
        adapterID = try container.decode(String.self, forKey: .adapterID)
        configurationState =
            try container.decodeIfPresent(ConfigurationState.self, forKey: .configurationState) ?? .failed
        detail = try container.decode(String.self, forKey: .detail)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetInstanceID, forKey: .targetInstanceID)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(configurationState, forKey: .configurationState)
        try container.encode(detail, forKey: .detail)
    }
}

/// Ownership details for a target instance being configured.
public struct SetupOwnershipDetail: Codable, Equatable, Sendable, Identifiable {
    public var id: TargetInstanceID { targetInstanceID }
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let summary: String
    public let routineDetails: [String]
    public let isConsequential: Bool
    public let consequentialDetail: String?

    public init(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        summary: String,
        routineDetails: [String] = [],
        isConsequential: Bool = false,
        consequentialDetail: String? = nil
    ) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.summary = summary
        self.routineDetails = routineDetails
        self.isConsequential = isConsequential
        self.consequentialDetail = consequentialDetail
    }
}

/// Adapter-owned metadata that identifies one setup effect shared by multiple Target Instances.
public struct ConnectionSharedSetupEffect: Codable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let detail: String?
    public let coveredExpectedSideEffects: [String]
    public let isConsequential: Bool

    public init(
        key: String,
        name: String,
        detail: String? = nil,
        coveredExpectedSideEffects: [String] = [],
        isConsequential: Bool = false
    ) {
        self.key = key
        self.name = name
        self.detail = detail
        self.coveredExpectedSideEffects = coveredExpectedSideEffects
        self.isConsequential = isConsequential
    }
}

/// A setup effect or artifact shared across one or more target instances.
public struct SetupSharedEffect: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let detail: String?
    public let affectedTargetIDs: [TargetInstanceID]
    public let affectedTargetNames: [String]
    public let isConsequential: Bool

    public init(
        name: String,
        detail: String? = nil,
        affectedTargetIDs: [TargetInstanceID],
        affectedTargetNames: [String] = [],
        isConsequential: Bool = false
    ) {
        self.name = name
        self.detail = detail
        self.affectedTargetIDs = affectedTargetIDs
        self.affectedTargetNames = affectedTargetNames
        self.isConsequential = isConsequential
    }
}

/// The result of validating whether material preconditions still hold for a reviewed Setup Plan.
public enum SetupPlanPreconditionValidation: Equatable, Sendable {
    case valid
    case invalidated(reason: String)

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    public var invalidationReason: String? {
        if case .invalidated(let reason) = self { return reason }
        return nil
    }
}

/// An immutable, aggregate plan containing the reviewed preparation for all opted-in target instances.
public struct SetupPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let workspaceID: WorkspaceID
    public let targetInstanceIDs: [TargetInstanceID]
    public let targetPlans: [ConnectionPlan]
    public let preparationFailures: [TargetSetupPreparationFailure]
    public let expectedSideEffects: [String]
    public let requiredPermissions: [String]
    public let userActions: [UserAction]
    public let activationReach: ActivationReach
    public let ownershipDetails: [SetupOwnershipDetail]
    public let recoveryBehavior: String
    public let discoveryAndSelectionDigest: String
    public let sharedEffects: [SetupSharedEffect]
    /// The completed Setup Transaction whose unresolved targets this fresh plan retries.
    public let retrySourceOperationID: UUID?

    public init(
        id: UUID = UUID(),
        workspaceID: WorkspaceID,
        targetInstanceIDs: [TargetInstanceID],
        targetPlans: [ConnectionPlan],
        preparationFailures: [TargetSetupPreparationFailure] = [],
        expectedSideEffects: [String] = [],
        requiredPermissions: [String] = [],
        userActions: [UserAction] = [],
        activationReach: ActivationReach = .currentInstances,
        ownershipDetails: [SetupOwnershipDetail] = [],
        recoveryBehavior: String =
            "Oh My Theme captures a baseline of existing target configurations before any mutation. If setup is cancelled or disconnected, the baseline can be restored safely without force-overwriting external changes.",
        discoveryAndSelectionDigest: String,
        sharedEffects: [SetupSharedEffect] = [],
        retrySourceOperationID: UUID? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.targetInstanceIDs = targetInstanceIDs
        self.targetPlans = targetPlans
        self.preparationFailures = preparationFailures
        self.expectedSideEffects = expectedSideEffects
        self.requiredPermissions = requiredPermissions
        self.userActions = userActions
        self.activationReach = activationReach
        self.ownershipDetails = ownershipDetails
        self.recoveryBehavior = recoveryBehavior
        self.discoveryAndSelectionDigest = discoveryAndSelectionDigest
        self.sharedEffects = sharedEffects
        self.retrySourceOperationID = retrySourceOperationID
    }

    public var requiresApproval: Bool {
        targetPlans.contains(where: \.requiresApproval) || !requiredPermissions.isEmpty
    }

    public var canRunWithoutAdditionalUserInteraction: Bool {
        !requiresApproval && preparationFailures.isEmpty && userActions.isEmpty
    }

    public var hasReadyTargets: Bool {
        !targetPlans.isEmpty
    }

    public var isFullyReady: Bool {
        preparationFailures.isEmpty && hasReadyTargets
    }

    /// Validates the aggregate integrity of the plan before any external mutation begins.
    public func validatePlanIntegrity() throws {
        guard !targetInstanceIDs.isEmpty else {
            throw ThemeEngineError.corruptPlanState(id, reason: "Setup plan has no target instances.")
        }
        guard Set(targetInstanceIDs).count == targetInstanceIDs.count else {
            throw ThemeEngineError.corruptPlanState(id, reason: "Setup plan contains duplicate target instance IDs.")
        }
        guard !discoveryAndSelectionDigest.isEmpty else {
            throw ThemeEngineError.corruptPlanState(id, reason: "Setup plan discovery and selection digest is empty.")
        }

        let planTargetIDs = targetPlans.map(\.targetInstanceID)
        guard Set(planTargetIDs).count == planTargetIDs.count else {
            throw ThemeEngineError.corruptPlanState(id, reason: "Setup plan contains duplicate target plans.")
        }
        let planTargetIDSet = Set(planTargetIDs)

        let failureTargetIDs = preparationFailures.map(\.targetInstanceID)
        guard Set(failureTargetIDs).count == failureTargetIDs.count else {
            throw ThemeEngineError.corruptPlanState(id, reason: "Setup plan contains duplicate preparation failures.")
        }
        let failureTargetIDSet = Set(failureTargetIDs)

        guard planTargetIDSet.isDisjoint(with: failureTargetIDSet) else {
            throw ThemeEngineError.corruptPlanState(
                id,
                reason: "Setup plan contains targets in both ready plans and preparation failures."
            )
        }
        guard planTargetIDSet.union(failureTargetIDSet) == Set(targetInstanceIDs) else {
            throw ThemeEngineError.corruptPlanState(
                id,
                reason: "Setup plan target instance IDs do not match target plans and failures."
            )
        }
        for targetPlan in targetPlans {
            guard !targetPlan.intendedChangeDigest.isEmpty else {
                throw ThemeEngineError.corruptPlanState(
                    id,
                    reason: "Target plan intended change digest is empty for \(targetPlan.targetInstanceID.rawValue)."
                )
            }
            guard !targetPlan.adapterID.isEmpty else {
                throw ThemeEngineError.corruptPlanState(
                    id,
                    reason: "Target plan adapter ID is empty for \(targetPlan.targetInstanceID.rawValue)."
                )
            }
        }
    }
}

/// Progress and live state of a Setup Transaction across its selected target instances.
public struct SetupProgress: Codable, Equatable, Sendable {
    public enum StepStatus: Codable, Equatable, Sendable {
        case waiting
        case configuring
        case needsPermission(detail: String)
        case needsAction(detail: String)
        case connected(reach: ActivationReach)
        case unchanged(detail: String)
        case conflict(detail: String)
        case failed(detail: String)
        case unavailable(detail: String)
        case recoveryRequired(detail: String)
    }

    public struct TargetStep: Codable, Equatable, Identifiable, Sendable {
        public var id: TargetInstanceID { targetInstanceID }
        public let targetInstanceID: TargetInstanceID
        public let displayName: String
        public let adapterID: String
        public var status: StepStatus
        public var currentAction: String?

        public init(
            targetInstanceID: TargetInstanceID,
            displayName: String,
            adapterID: String,
            status: StepStatus = .waiting,
            currentAction: String? = nil
        ) {
            self.targetInstanceID = targetInstanceID
            self.displayName = displayName
            self.adapterID = adapterID
            self.status = status
            self.currentAction = currentAction
        }
    }

    public let operationID: UUID
    public var steps: [TargetStep]
    public var currentTargetID: TargetInstanceID?

    public init(
        operationID: UUID,
        steps: [TargetStep],
        currentTargetID: TargetInstanceID? = nil
    ) {
        self.operationID = operationID
        self.steps = steps
        self.currentTargetID = currentTargetID
    }

    public var completedCount: Int {
        steps.filter { step in
            switch step.status {
            case .waiting, .configuring:
                return false
            case .needsPermission, .needsAction, .connected, .unchanged, .conflict, .failed, .unavailable,
                .recoveryRequired:
                return true
            }
        }.count
    }

    public var totalCount: Int {
        steps.count
    }

    public var fractionCompleted: Double {
        totalCount == 0 ? 1.0 : Double(completedCount) / Double(totalCount)
    }

    public var isComplete: Bool {
        completedCount == totalCount && totalCount > 0
    }

    public var activeStepName: String? {
        guard let currentTargetID else { return nil }
        return steps.first(where: { $0.targetInstanceID == currentTargetID })?.displayName
    }

    public var currentAction: String? {
        guard let currentTargetID else { return nil }
        return steps.first(where: { $0.targetInstanceID == currentTargetID })?.currentAction
    }
}
