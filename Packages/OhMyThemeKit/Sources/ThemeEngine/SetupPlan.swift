import CryptoKit
import Foundation
import ThemeModel

/// A preparation failure for a selected target instance during Setup Plan creation.
public struct TargetSetupPreparationFailure: Codable, Equatable, Sendable, Identifiable {
    public var id: TargetInstanceID { targetInstanceID }
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let detail: String

    public init(targetInstanceID: TargetInstanceID, adapterID: String, detail: String) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.detail = detail
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
        sharedEffects: [SetupSharedEffect] = []
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
}
