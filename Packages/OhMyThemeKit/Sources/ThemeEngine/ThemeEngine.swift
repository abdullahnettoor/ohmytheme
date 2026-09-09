import Foundation
import Persistence
import ThemeModel

public enum ThemeSourcePolicy: String, Codable, Equatable, Sendable {
    case preferUpstream
    case requireUpstream
    case useGenerated
}

public enum ThemeSourceKind: String, Codable, Equatable, Sendable {
    case upstream
    case generated
    case unavailable
    case mixed
}

public enum ActivationReach: String, Codable, Equatable, Sendable {
    case currentInstances
    case nextPrompt
    case newProcessesOnly
    case reloadRequired
    case unavailable
}

public enum ConfigurationState: String, Codable, Equatable, Sendable {
    case updated
    case unchanged
    case permissionRequired
    case conflicted
    case failed
    case unavailable
}

/// An error that can preserve a target-specific failure as an honest Capability Outcome.
public protocol CapabilityOutcomeError: Error {
    var capabilityConfigurationState: ConfigurationState { get }
    var capabilityActivationReach: ActivationReach { get }
    var capabilityOutcomeDetail: String { get }
}

public enum UserActionKind: String, Codable, Equatable, Sendable {
    case instruction
    case approval
    case permission
    case reload
}

public struct UserAction: Codable, Equatable, Sendable {
    public let title: String
    public let detail: String
    public let kind: UserActionKind

    public init(title: String, detail: String, kind: UserActionKind = .instruction) {
        self.title = title
        self.detail = detail
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case detail
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decode(String.self, forKey: .title),
            detail: try container.decode(String.self, forKey: .detail),
            kind: try container.decodeIfPresent(UserActionKind.self, forKey: .kind) ?? .instruction
        )
    }
}

public struct PreparedTheme: Codable, Equatable, Sendable {
    public let variantID: String
    public let variant: ThemeVariant
    public let sourceType: ThemeSourceKind
    public let sourceRevision: String
    public let attribution: String
    public let themeSchemaVersion: Int
    public let contentDigest: String
    public let compilerVersion: String
    public let upstreamArtifact: Data?

    public init(
        variantID: String,
        variant: ThemeVariant,
        sourceType: ThemeSourceKind,
        sourceRevision: String,
        attribution: String,
        themeSchemaVersion: Int,
        contentDigest: String,
        compilerVersion: String,
        upstreamArtifact: Data?
    ) {
        self.variantID = variantID
        self.variant = variant
        self.sourceType = sourceType
        self.sourceRevision = sourceRevision
        self.attribution = attribution
        self.themeSchemaVersion = themeSchemaVersion
        self.contentDigest = contentDigest
        self.compilerVersion = compilerVersion
        self.upstreamArtifact = upstreamArtifact
    }
}

public struct AdapterPayloadEnvelope: Codable, Equatable, Sendable {
    public let adapterID: String
    public let adapterVersion: String
    public let payloadVersion: String
    public let payload: Data

    public init(
        adapterID: String,
        adapterVersion: String,
        payloadVersion: String,
        payload: Data
    ) {
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.payloadVersion = payloadVersion
        self.payload = payload
    }
}

public struct PinnedUpstreamArtifact: Codable, Equatable, Sendable {
    public let adapterID: String
    public let variantID: String
    public let revision: String
    public let contentDigest: String
    public let payload: Data

    public init(
        adapterID: String,
        variantID: String,
        revision: String,
        contentDigest: String,
        payload: Data
    ) {
        self.adapterID = adapterID
        self.variantID = variantID
        self.revision = revision
        self.contentDigest = contentDigest
        self.payload = payload
    }
}

public struct AdapterPlan: Codable, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let adapterVersion: String
    public let capabilityID: String
    public let payload: AdapterPayloadEnvelope
    public let intendedChangeDigest: String
    public let capturedPreChangeState: Data?
    public let staleStateToken: String?
    public let expectedSideEffects: [String]
    public let requiredPermissions: [String]
    public let sourceType: ThemeSourceKind
    public let sourceRevision: String
    public let activationReach: ActivationReach
    public let setupNeeds: [UserAction]
    public let conflicts: [String]

    public var artifact: Data {
        payload.payload
    }

    public init(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        adapterVersion: String,
        capabilityID: String,
        payload: AdapterPayloadEnvelope,
        intendedChangeDigest: String,
        capturedPreChangeState: Data? = nil,
        staleStateToken: String? = nil,
        expectedSideEffects: [String] = [],
        requiredPermissions: [String] = [],
        sourceType: ThemeSourceKind,
        sourceRevision: String,
        activationReach: ActivationReach,
        setupNeeds: [UserAction] = [],
        conflicts: [String] = []
    ) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.capabilityID = capabilityID
        self.payload = payload
        self.intendedChangeDigest = intendedChangeDigest
        self.capturedPreChangeState = capturedPreChangeState
        self.staleStateToken = staleStateToken
        self.expectedSideEffects = expectedSideEffects
        self.requiredPermissions = requiredPermissions
        self.sourceType = sourceType
        self.sourceRevision = sourceRevision
        self.activationReach = activationReach
        self.setupNeeds = setupNeeds
        self.conflicts = conflicts
    }
}

public struct AdapterReceipt: Codable, Equatable, Sendable {
    public let configurationState: ConfigurationState
    public let runningInstanceReach: ActivationReach
    public let detail: String?
    public let rollbackData: Data?

    public init(
        configurationState: ConfigurationState,
        runningInstanceReach: ActivationReach,
        detail: String? = nil,
        rollbackData: Data? = nil
    ) {
        self.configurationState = configurationState
        self.runningInstanceReach = runningInstanceReach
        self.detail = detail
        self.rollbackData = rollbackData
    }

    private enum CodingKeys: String, CodingKey {
        case configurationState
        case runningInstanceReach
        case detail
        case rollbackData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            configurationState: try container.decode(ConfigurationState.self, forKey: .configurationState),
            runningInstanceReach: try container.decode(ActivationReach.self, forKey: .runningInstanceReach),
            detail: try container.decodeIfPresent(String.self, forKey: .detail),
            rollbackData: try container.decodeIfPresent(Data.self, forKey: .rollbackData)
        )
    }
}

public enum RollbackState: String, Codable, Equatable, Sendable {
    case notNeeded
    case undoAvailable
    case restored
    case blocked
    case recoveryRequired
}

public struct TargetCapabilityOutcome: Codable, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let capabilityID: String
    public let sourceType: ThemeSourceKind
    public let sourceRevision: String
    public let configurationState: ConfigurationState
    public let runningInstanceReach: ActivationReach
    public let detail: String?
    public let rollbackState: RollbackState
    public let userActions: [UserAction]

    public init(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        capabilityID: String,
        sourceType: ThemeSourceKind,
        sourceRevision: String,
        configurationState: ConfigurationState,
        runningInstanceReach: ActivationReach,
        detail: String? = nil,
        rollbackState: RollbackState = .notNeeded,
        userActions: [UserAction] = []
    ) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.capabilityID = capabilityID
        self.sourceType = sourceType
        self.sourceRevision = sourceRevision
        self.configurationState = configurationState
        self.runningInstanceReach = runningInstanceReach
        self.detail = detail
        self.rollbackState = rollbackState
        self.userActions = userActions
    }
}

public struct ApplyReport: Codable, Equatable, Sendable {
    public let variantID: String
    public let outcomes: [TargetCapabilityOutcome]

    public init(variantID: String, outcomes: [TargetCapabilityOutcome]) {
        self.variantID = variantID
        self.outcomes = outcomes
    }
}

public struct TargetPreparationFailure: Codable, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let detail: String

    public init(targetInstanceID: TargetInstanceID, adapterID: String, detail: String) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.detail = detail
    }
}

public struct ApplyPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let workspaceID: WorkspaceID
    public let targetInstanceIDs: [TargetInstanceID]
    public let requiredThemeAssignment: ThemeAssignment?
    public let variantID: String
    public let sourceType: ThemeSourceKind
    public let sourceRevision: String
    public let attribution: String
    public let activationReach: ActivationReach
    public let setupNeeds: [UserAction]
    public let conflicts: [String]
    public let unavailableCapabilities: [String]
    public let unavailableTargetInstanceIDs: [TargetInstanceID]
    public let preparationFailures: [TargetPreparationFailure]
    public let userActions: [UserAction]
    public let targetPlans: [AdapterPlan]

    public init(
        id: UUID,
        workspaceID: WorkspaceID,
        targetInstanceIDs: [TargetInstanceID],
        requiredThemeAssignment: ThemeAssignment? = nil,
        variantID: String,
        sourceType: ThemeSourceKind,
        sourceRevision: String,
        attribution: String,
        activationReach: ActivationReach,
        setupNeeds: [UserAction],
        conflicts: [String],
        unavailableCapabilities: [String],
        unavailableTargetInstanceIDs: [TargetInstanceID] = [],
        preparationFailures: [TargetPreparationFailure] = [],
        userActions: [UserAction],
        targetPlans: [AdapterPlan]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.targetInstanceIDs = targetInstanceIDs
        self.requiredThemeAssignment = requiredThemeAssignment
        self.variantID = variantID
        self.sourceType = sourceType
        self.sourceRevision = sourceRevision
        self.attribution = attribution
        self.activationReach = activationReach
        self.setupNeeds = setupNeeds
        self.conflicts = conflicts
        self.unavailableCapabilities = unavailableCapabilities
        self.unavailableTargetInstanceIDs = unavailableTargetInstanceIDs
        self.preparationFailures = preparationFailures
        self.userActions = userActions
        self.targetPlans = targetPlans
    }
}

public struct PreflightReviewReason: Equatable, Sendable, Identifiable {
    public var id: String { "\(targetInstanceID?.rawValue ?? "global")-\(category.rawValue)-\(title)" }
    public let targetInstanceID: TargetInstanceID?
    public let category: Category
    public let title: String
    public let detail: String

    public enum Category: String, Equatable, Sendable {
        case conflict
        case ownership
        case permission
        case ambiguousTarget
        case setupNeeded
        case unavailable
    }

    public init(
        targetInstanceID: TargetInstanceID? = nil,
        category: Category,
        title: String,
        detail: String
    ) {
        self.targetInstanceID = targetInstanceID
        self.category = category
        self.title = title
        self.detail = detail
    }
}

extension ApplyPlan {
    public var readyTargetPlans: [AdapterPlan] {
        targetPlans.filter { plan in
            plan.conflicts.isEmpty
                && plan.setupNeeds.isEmpty
                && !unavailableTargetInstanceIDs.contains(plan.targetInstanceID)
                && !preparationFailures.contains(where: { $0.targetInstanceID == plan.targetInstanceID })
        }
    }

    public var readyTargetInstanceIDs: [TargetInstanceID] {
        readyTargetPlans.map(\.targetInstanceID)
    }

    public func preflightReviewReasons(
        acknowledgedUnavailableTargets: Set<TargetInstanceID> = []
    ) -> [PreflightReviewReason] {
        var reasons: [PreflightReviewReason] = []

        // 1. Conflicts
        for plan in targetPlans where !plan.conflicts.isEmpty {
            for conflict in plan.conflicts {
                reasons.append(
                    PreflightReviewReason(
                        targetInstanceID: plan.targetInstanceID,
                        category: .conflict,
                        title: "Conflict",
                        detail: conflict
                    )
                )
            }
        }
        for conflict in conflicts {
            reasons.append(
                PreflightReviewReason(
                    targetInstanceID: nil,
                    category: .conflict,
                    title: "Conflict",
                    detail: conflict
                )
            )
        }


        // 2. Preparation Failures (including ownership changes, permissions, ambiguous targets)
        for failure in preparationFailures {
            let lower = failure.detail.lowercased()
            let category: PreflightReviewReason.Category
            let title: String
            if lower.contains("nix") || lower.contains("linked") || lower.contains("ownership") {
                category = .ownership
                title = "Configuration ownership changed"
            } else if lower.contains("permission") || lower.contains("notauthorized") {
                category = .permission
                title = "Permission needed"
            } else if lower.contains("ambiguous") {
                category = .ambiguousTarget
                title = "Ambiguous configuration"
            } else {
                category = .setupNeeded
                title = "Could not prepare Target"
            }
            reasons.append(
                PreflightReviewReason(
                    targetInstanceID: failure.targetInstanceID,
                    category: category,
                    title: title,
                    detail: failure.detail
                )
            )
        }

        // 3. Setup Needs
        for plan in targetPlans where !plan.setupNeeds.isEmpty {
            for need in plan.setupNeeds {
                let isPerm = need.kind == .permission
                    || need.title.localizedCaseInsensitiveContains("permission")
                    || need.detail.localizedCaseInsensitiveContains("permission")
                let category: PreflightReviewReason.Category = isPerm ? .permission : .setupNeeded
                reasons.append(
                    PreflightReviewReason(
                        targetInstanceID: plan.targetInstanceID,
                        category: category,
                        title: need.title,
                        detail: need.detail
                    )
                )
            }
        }
        for need in setupNeeds {
            if reasons.contains(where: { $0.title == need.title && $0.detail == need.detail }) {
                continue
            }
            let lower = (need.title + " " + need.detail).lowercased()
            let category: PreflightReviewReason.Category = lower.contains("permission") ? .permission : .setupNeeded
            reasons.append(
                PreflightReviewReason(
                    targetInstanceID: nil,
                    category: category,
                    title: need.title,
                    detail: need.detail
                )
            )
        }

        // 4. Unavailable Targets (filter out previously acknowledged)
        let unacknowledged = unavailableTargetInstanceIDs.filter { !acknowledgedUnavailableTargets.contains($0) }
        for id in unacknowledged {
            reasons.append(
                PreflightReviewReason(
                    targetInstanceID: id,
                    category: .unavailable,
                    title: "Target unavailable",
                    detail: "No compatible adapter prepared this Target Instance."
                )
            )
        }

        return reasons
    }

    public func preflightExplanation(
        acknowledgedUnavailableTargets: Set<TargetInstanceID> = []
    ) -> String? {
        let reasons = preflightReviewReasons(acknowledgedUnavailableTargets: acknowledgedUnavailableTargets)
        guard !reasons.isEmpty else { return nil }
        let affectedIDs = Set(reasons.compactMap(\.targetInstanceID))
        let targetPhrase: String
        if affectedIDs.isEmpty {
            targetPhrase = "Review is required"
        } else if affectedIDs.count == 1 {
            targetPhrase = "1 Target Instance requires review"
        } else {
            targetPhrase = "\(affectedIDs.count) Target Instances require review"
        }

        var issueDescriptions: [String] = []
        let categories = Set(reasons.map(\.category))
        if categories.contains(.conflict) { issueDescriptions.append("conflicts") }
        if categories.contains(.ownership) { issueDescriptions.append("configuration ownership changes") }
        if categories.contains(.permission) { issueDescriptions.append("new permissions") }
        if categories.contains(.ambiguousTarget) { issueDescriptions.append("ambiguous configuration") }
        if categories.contains(.setupNeeded) { issueDescriptions.append("required setup") }
        if categories.contains(.unavailable) { issueDescriptions.append("unavailable targets") }

        return "Automatic Apply paused because \(targetPhrase): \(issueDescriptions.joined(separator: ", "))."
    }

    public var hasReviewConditions: Bool {
        hasReviewConditions(acknowledgedUnavailableTargets: [])
    }

    public func hasReviewConditions(
        acknowledgedUnavailableTargets: Set<TargetInstanceID> = []
    ) -> Bool {
        !preflightReviewReasons(acknowledgedUnavailableTargets: acknowledgedUnavailableTargets).isEmpty
    }

    public var isClean: Bool {
        isClean(acknowledgedUnavailableTargets: [])
    }

    public func isClean(
        acknowledgedUnavailableTargets: Set<TargetInstanceID> = []
    ) -> Bool {
        !hasReviewConditions(acknowledgedUnavailableTargets: acknowledgedUnavailableTargets)
            && !readyTargetPlans.isEmpty
    }
}

public protocol ThemeAdapter: Sendable {
    var id: String { get }
    var version: String { get }
    var payloadVersion: String { get }

    func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> AdapterPlan

    func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt

    func verify(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> (status: TargetVerificationStatus, detail: String?)
}

extension ThemeAdapter {
    public func verify(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> (status: TargetVerificationStatus, detail: String?) {
        do {
            let plan = try await prepareApply(instance: instance, theme: theme)
            if !plan.conflicts.isEmpty {
                return (.needsAttention, plan.conflicts.joined(separator: "; "))
            }
            if !plan.setupNeeds.isEmpty {
                return (.needsAttention, plan.setupNeeds.map(\.detail).joined(separator: "; "))
            }
            return (.pending, nil)
        } catch {
            return (.needsAttention, error.localizedDescription)
        }
    }
}

public enum ThemeEngineError: Error, Equatable, Sendable {
    case variantNotFound(String)
    case fixedThemeAssignmentRequired
    case planNotFound(UUID)
    case planWorkspaceChanged(UUID)
    case planMembershipChanged(UUID)
    case corruptPlanState(UUID, reason: String)
    case engineUnavailable
    case applyInProgress
}

public actor ThemeEngine {
    private let packs: [ThemePack]
    internal var adaptersByID: [String: any ThemeAdapter]
    internal var connectionAdaptersByID: [String: any ConnectionAdapter]
    private let sourcePolicy: ThemeSourcePolicy
    private let upstreamArtifacts: [String: PinnedUpstreamArtifact]
    internal let persistenceForOperations: PersistenceStore?
    internal var plansInFlight: [UUID: ApplyPlan] = [:]
    internal var setupPlansInFlight: [UUID: SetupPlan] = [:]

    private var isApplying = false
    internal var currentOperationID: UUID?
    internal var isStartingOperation = false
    internal var pendingCancellations: Set<UUID> = []
    internal var mutationBegun: Set<UUID> = []

    public init(
        packs: [ThemePack],
        adapters: [any ThemeAdapter],
        connectionAdapters: [any ConnectionAdapter] = [],
        sourcePolicy: ThemeSourcePolicy = .preferUpstream,
        upstreamArtifacts: [String: PinnedUpstreamArtifact] = [:],
        persistence: PersistenceStore? = nil
    ) {
        self.packs = packs
        self.adaptersByID = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
        var connectionAdaptersByID = Dictionary(
            uniqueKeysWithValues: connectionAdapters.map { ($0.id, $0) }
        )
        for adapter in adapters {
            if let connectionAdapter = adapter as? any ConnectionAdapter {
                connectionAdaptersByID[adapter.id] = connectionAdapter
            }
        }
        self.connectionAdaptersByID = connectionAdaptersByID
        self.sourcePolicy = sourcePolicy
        self.upstreamArtifacts = upstreamArtifacts
        self.persistenceForOperations = persistence
    }

    public func register(adapter: any ThemeAdapter) {
        adaptersByID[adapter.id] = adapter
        if let connectionAdapter = adapter as? any ConnectionAdapter {
            connectionAdaptersByID[adapter.id] = connectionAdapter
        }
    }

    internal func storePlanInFlight(_ plan: ApplyPlan) {
        plansInFlight[plan.id] = plan
    }

    public func verifyStatus(
        workspace: Workspace,
        persisting: Bool = true
    ) async throws -> WorkspaceThemeStatus {
        let now = Date()
        guard let assignment = workspace.themeAssignment else {
            let status = WorkspaceThemeStatus(
                timestamp: now,
                desiredThemeAssignment: nil,
                targetOutcomes: []
            )
            if persisting, let persistence = persistenceForOperations {
                try? persistence.saveTargetVerificationOutcomes([], workspaceID: workspace.id)
            }
            return status
        }

        let themeVariantID: String
        switch assignment {
        case .fixed(let variantID):
            themeVariantID = variantID
        case .appearancePair(let pair):
            themeVariantID = pair.darkVariantID
        }

        guard let packAndVariant = findVariant(themeVariantID) else {
            let outcomes = workspace.connectedTargetInstances.map { instance in
                TargetVerificationOutcome(
                    targetInstanceID: instance.id,
                    status: .needsAttention,
                    detail: "Theme variant \(themeVariantID) not found in theme catalog.",
                    verifiedVariantID: nil,
                    verifiedAt: now
                )
            }
            let status = WorkspaceThemeStatus(
                timestamp: now,
                desiredThemeAssignment: assignment,
                targetOutcomes: outcomes
            )
            if persisting, let persistence = persistenceForOperations {
                try? persistence.saveTargetVerificationOutcomes(outcomes, workspaceID: workspace.id)
            }
            return status
        }

        let (pack, variant) = packAndVariant
        let orderedInstances = WorkspaceTargetOrder.ordered(workspace.connectedTargetInstances)
        var outcomes: [TargetVerificationOutcome] = []

        for instance in orderedInstances {
            guard let adapter = adaptersByID[instance.adapterID] else {
                outcomes.append(TargetVerificationOutcome(
                    targetInstanceID: instance.id,
                    status: .needsAttention,
                    detail: "Adapter \(instance.adapterID) unavailable.",
                    verifiedVariantID: nil,
                    verifiedAt: now
                ))
                continue
            }

            guard let targetSource = resolveSource(for: pack, variant: variant, adapterID: instance.adapterID) else {
                outcomes.append(TargetVerificationOutcome(
                    targetInstanceID: instance.id,
                    status: .needsAttention,
                    detail: "Theme source unavailable for adapter \(instance.adapterID).",
                    verifiedVariantID: nil,
                    verifiedAt: now
                ))
                continue
            }

            let preparedTheme = PreparedTheme(
                variantID: variant.qualifiedID,
                variant: variant,
                sourceType: targetSource.type,
                sourceRevision: pack.source.revision,
                attribution: pack.source.attribution,
                themeSchemaVersion: pack.schemaVersion,
                contentDigest: variant.contentDigest,
                compilerVersion: "theme-compiler-1",
                upstreamArtifact: targetSource.artifact
            )

            do {
                let (status, detail) = try await adapter.verify(instance: instance, theme: preparedTheme)
                outcomes.append(TargetVerificationOutcome(
                    targetInstanceID: instance.id,
                    status: status,
                    detail: detail,
                    verifiedVariantID: status == .applied ? variant.qualifiedID : nil,
                    verifiedAt: now
                ))
            } catch {
                outcomes.append(TargetVerificationOutcome(
                    targetInstanceID: instance.id,
                    status: .needsAttention,
                    detail: error.localizedDescription,
                    verifiedVariantID: nil,
                    verifiedAt: now
                ))
            }
        }

        let status = WorkspaceThemeStatus(
            timestamp: now,
            desiredThemeAssignment: assignment,
            targetOutcomes: outcomes
        )

        if persisting, let persistence = persistenceForOperations {
            try? persistence.saveTargetVerificationOutcomes(outcomes, workspaceID: workspace.id)
        }

        return status
    }

    public func prepare(workspace: Workspace) async throws -> ApplyPlan {
        guard case .fixed(let themeVariantID) = workspace.themeAssignment else {
            throw ThemeEngineError.fixedThemeAssignmentRequired
        }
        return try await prepare(
            themeVariantID: themeVariantID,
            workspace: workspace,
            requiredThemeAssignment: workspace.themeAssignment
        )
    }

    func prepare(themeVariantID: String, workspace: Workspace) async throws -> ApplyPlan {
        try await prepare(
            themeVariantID: themeVariantID,
            workspace: workspace,
            requiredThemeAssignment: nil
        )
    }

    private func prepare(
        themeVariantID: String,
        workspace: Workspace,
        requiredThemeAssignment: ThemeAssignment?
    ) async throws -> ApplyPlan {
        guard let packAndVariant = findVariant(themeVariantID) else {
            throw ThemeEngineError.variantNotFound(themeVariantID)
        }
        let (pack, variant) = packAndVariant
        let orderedInstances = WorkspaceTargetOrder.ordered(workspace.connectedTargetInstances)
        let resolvedSource = resolveSource(for: pack, variant: variant, adapterID: nil)
        if sourcePolicy == .requireUpstream,
            resolvedSource == nil,
            workspace.connectedTargetInstances.isEmpty
        {
            let plan = ApplyPlan(
                id: UUID(),
                workspaceID: workspace.id,
                targetInstanceIDs: orderedInstances.map(\.id),
                requiredThemeAssignment: requiredThemeAssignment,
                variantID: variant.qualifiedID,
                sourceType: .unavailable,
                sourceRevision: pack.source.revision,
                attribution: pack.source.attribution,
                activationReach: .unavailable,
                setupNeeds: [],
                conflicts: [],
                unavailableCapabilities: orderedInstances.map { _ in "theme" },
                unavailableTargetInstanceIDs: orderedInstances.map(\.id),
                userActions: [],
                targetPlans: []
            )
            plansInFlight[plan.id] = plan
            return plan
        }
        let source =
            resolvedSource
            ?? ResolvedSource(type: .unavailable, revision: pack.source.revision, artifact: nil)
        let planID = UUID()

        var targetPlans: [AdapterPlan] = []
        var setupNeeds: [UserAction] = []
        var conflicts: [String] = []
        var unavailableCapabilities: [String] = []
        var unavailableTargetInstanceIDs: [TargetInstanceID] = []
        var preparationFailures: [TargetPreparationFailure] = []
        var userActions: [UserAction] = []
        for instance in orderedInstances {
            guard let adapter = adaptersByID[instance.adapterID] else {
                unavailableCapabilities.append("theme")
                unavailableTargetInstanceIDs.append(instance.id)
                continue
            }
            guard let targetSource = resolveSource(for: pack, variant: variant, adapterID: instance.adapterID)
            else {
                unavailableCapabilities.append("theme")
                unavailableTargetInstanceIDs.append(instance.id)
                continue
            }
            let preparedTheme = PreparedTheme(
                variantID: variant.qualifiedID,
                variant: variant,
                sourceType: targetSource.type,
                sourceRevision: pack.source.revision,
                attribution: pack.source.attribution,
                themeSchemaVersion: pack.schemaVersion,
                contentDigest: variant.contentDigest,
                compilerVersion: "theme-compiler-1",
                upstreamArtifact: targetSource.artifact
            )
            do {
                let plan: AdapterPlan
                if let writableAdapter = adapter as? any WritableThemeAdapter {
                    let connectionBaseline: Data?
                    if let persistence = persistenceForOperations,
                        let baseline = try persistence.journalLoadConnectionBaseline(targetInstanceID: instance.id),
                        baseline.adapterID == adapter.id,
                        baseline.adapterVersion == adapter.version
                    {
                        connectionBaseline = try persistence.loadContent(baseline.baselineReference)
                    } else {
                        connectionBaseline = nil
                    }
                    plan = try await writableAdapter.prepareApply(
                        instance: instance,
                        theme: preparedTheme,
                        connectionBaseline: connectionBaseline
                    )
                } else {
                    plan = try await adapter.prepareApply(instance: instance, theme: preparedTheme)
                }
                if let persistence = persistenceForOperations {
                    try persist(plan: plan, planID: planID, persistence: persistence)
                }
                targetPlans.append(plan)
                setupNeeds.append(contentsOf: plan.setupNeeds)
                conflicts.append(contentsOf: plan.conflicts)
                userActions.append(contentsOf: plan.setupNeeds)
                userActions.append(
                    contentsOf: plan.requiredPermissions.map {
                        UserAction(title: "Permission needed", detail: $0)
                    })
            } catch {
                preparationFailures.append(
                    TargetPreparationFailure(
                        targetInstanceID: instance.id,
                        adapterID: instance.adapterID,
                        detail: String(describing: error)
                    ))
            }
        }
        if workspace.connectedTargetInstances.isEmpty {
            setupNeeds.append(
                UserAction(
                    title: "Connect an app",
                    detail: "This plan has no Target Instances to change."
                )
            )
            userActions.append(contentsOf: setupNeeds)
        }

        let sourceTypes = Set(targetPlans.map(\.sourceType))
        let planSourceType: ThemeSourceKind
        if sourceTypes.count == 1, let sourceType = sourceTypes.first {
            planSourceType = sourceType
        } else if sourceTypes.isEmpty {
            planSourceType = source.type
        } else {
            planSourceType = .mixed
        }
        let plan = ApplyPlan(
            id: planID,
            workspaceID: workspace.id,
            targetInstanceIDs: orderedInstances.map(\.id),
            requiredThemeAssignment: requiredThemeAssignment,
            variantID: variant.qualifiedID,
            sourceType: planSourceType,
            sourceRevision: pack.source.revision,
            attribution: pack.source.attribution,
            activationReach: targetPlans.isEmpty
                ? .unavailable
                : unavailableTargetInstanceIDs.isEmpty && preparationFailures.isEmpty
                    ? targetPlans.map(\.activationReach).reduce(.currentInstances, Self.worstReach)
                    : .unavailable,
            setupNeeds: setupNeeds,
            conflicts: conflicts,
            unavailableCapabilities: unavailableCapabilities,
            unavailableTargetInstanceIDs: unavailableTargetInstanceIDs,
            preparationFailures: preparationFailures,
            userActions: userActions,
            targetPlans: targetPlans
        )
        plansInFlight[plan.id] = plan
        return plan
    }

    public func apply(planID: UUID) async throws -> ApplyReport {
        guard !isApplying else {
            throw ThemeEngineError.applyInProgress
        }
        guard let plan = plansInFlight.removeValue(forKey: planID) else {
            throw ThemeEngineError.planNotFound(planID)
        }
        isApplying = true
        defer { isApplying = false }

        var outcomes = plan.targetPlans.map { targetPlan in
            TargetCapabilityOutcome(
                targetInstanceID: targetPlan.targetInstanceID,
                adapterID: targetPlan.adapterID,
                capabilityID: targetPlan.capabilityID,
                sourceType: targetPlan.sourceType,
                sourceRevision: targetPlan.sourceRevision,
                configurationState: .failed,
                runningInstanceReach: .unavailable,
                detail: "The Target Instance did not apply."
            )
        }
        for (index, targetPlan) in plan.targetPlans.enumerated() {
            guard let adapter = adaptersByID[targetPlan.adapterID] else {
                outcomes[index] = TargetCapabilityOutcome(
                    targetInstanceID: targetPlan.targetInstanceID,
                    adapterID: targetPlan.adapterID,
                    capabilityID: targetPlan.capabilityID,
                    sourceType: targetPlan.sourceType,
                    sourceRevision: targetPlan.sourceRevision,
                    configurationState: .unavailable,
                    runningInstanceReach: .unavailable,
                    detail: "The adapter is unavailable."
                )
                continue
            }
            if !targetPlan.conflicts.isEmpty {
                let conflictDetail = targetPlan.conflicts.joined(separator: "; ")
                outcomes[index] = TargetCapabilityOutcome(
                    targetInstanceID: targetPlan.targetInstanceID,
                    adapterID: targetPlan.adapterID,
                    capabilityID: targetPlan.capabilityID,
                    sourceType: targetPlan.sourceType,
                    sourceRevision: targetPlan.sourceRevision,
                    configurationState: .conflicted,
                    runningInstanceReach: .unavailable,
                    detail: conflictDetail,
                    rollbackState: .blocked,
                    userActions: [Self.reviewExternalChangeAction]
                )
                continue
            }
            if !targetPlan.setupNeeds.isEmpty {
                let setupDetail = targetPlan.setupNeeds.map(\.detail).joined(separator: "; ")
                let isPermission = targetPlan.setupNeeds.contains {
                    $0.title.localizedCaseInsensitiveContains("permission")
                        || $0.detail.localizedCaseInsensitiveContains("permission")
                }
                outcomes[index] = TargetCapabilityOutcome(
                    targetInstanceID: targetPlan.targetInstanceID,
                    adapterID: targetPlan.adapterID,
                    capabilityID: targetPlan.capabilityID,
                    sourceType: targetPlan.sourceType,
                    sourceRevision: targetPlan.sourceRevision,
                    configurationState: isPermission ? .permissionRequired : .failed,
                    runningInstanceReach: .unavailable,
                    detail: setupDetail,
                    rollbackState: .notNeeded,
                    userActions: targetPlan.setupNeeds
                )
                continue
            }
            guard targetPlan.adapterID == targetPlan.payload.adapterID,
                targetPlan.adapterVersion == targetPlan.payload.adapterVersion,
                targetPlan.adapterVersion == adapter.version,
                targetPlan.payload.payloadVersion == adapter.payloadVersion
            else {
                outcomes[index] = TargetCapabilityOutcome(
                    targetInstanceID: targetPlan.targetInstanceID,
                    adapterID: targetPlan.adapterID,
                    capabilityID: targetPlan.capabilityID,
                    sourceType: targetPlan.sourceType,
                    sourceRevision: targetPlan.sourceRevision,
                    configurationState: .failed,
                    runningInstanceReach: .unavailable,
                    detail: "The adapter payload envelope is incompatible."
                )
                continue
            }
            do {
                let receipt = try await adapter.apply(targetPlan)
                outcomes[index] = TargetCapabilityOutcome(
                    targetInstanceID: targetPlan.targetInstanceID,
                    adapterID: targetPlan.adapterID,
                    capabilityID: targetPlan.capabilityID,
                    sourceType: targetPlan.sourceType,
                    sourceRevision: targetPlan.sourceRevision,
                    configurationState: receipt.configurationState,
                    runningInstanceReach: receipt.runningInstanceReach,
                    detail: receipt.detail
                )
            } catch {
                let failure = Self.capabilityOutcome(for: error, fallbackState: .failed)
                outcomes[index] = TargetCapabilityOutcome(
                    targetInstanceID: targetPlan.targetInstanceID,
                    adapterID: targetPlan.adapterID,
                    capabilityID: targetPlan.capabilityID,
                    sourceType: targetPlan.sourceType,
                    sourceRevision: targetPlan.sourceRevision,
                    configurationState: failure.configurationState,
                    runningInstanceReach: failure.activationReach,
                    detail: failure.detail
                )
            }
        }
        outcomes.append(
            contentsOf: plan.unavailableTargetInstanceIDs.map {
                TargetCapabilityOutcome(
                    targetInstanceID: $0,
                    adapterID: "unavailable",
                    capabilityID: "theme",
                    sourceType: plan.sourceType,
                    sourceRevision: plan.sourceRevision,
                    configurationState: .unavailable,
                    runningInstanceReach: .unavailable,
                    detail: "No compatible adapter prepared this Target Instance."
                )
            })
        outcomes.append(
            contentsOf: plan.preparationFailures.map {
                TargetCapabilityOutcome(
                    targetInstanceID: $0.targetInstanceID,
                    adapterID: $0.adapterID,
                    capabilityID: "theme",
                    sourceType: plan.sourceType,
                    sourceRevision: plan.sourceRevision,
                    configurationState: .failed,
                    runningInstanceReach: .unavailable,
                    detail: $0.detail
                )
            })
        return ApplyReport(variantID: plan.variantID, outcomes: outcomes)
    }

    private func findVariant(_ qualifiedID: String) -> (ThemePack, ThemeVariant)? {
        packs.lazy
            .flatMap { pack in pack.variants.map { (pack, $0) } }
            .first { $0.1.qualifiedID == qualifiedID }
    }

    private func persist(plan: AdapterPlan, planID: UUID, persistence: PersistenceStore) throws {
        let envelope = PersistedPayloadEnvelope(
            id: "\(planID.uuidString).\(plan.targetInstanceID.rawValue)",
            targetInstanceID: plan.targetInstanceID,
            adapterID: plan.adapterID,
            adapterVersion: plan.adapterVersion,
            payloadVersion: plan.payload.payloadVersion,
            payload: plan.payload.payload
        )
        try persistence.savePayloadEnvelope(
            envelope,
            restorationData: plan.capturedPreChangeState
        )
    }

    private func resolveSource(
        for pack: ThemePack,
        variant: ThemeVariant,
        adapterID: String?
    ) -> ResolvedSource? {
        let upstreamArtifact: Data?
        if let adapterID,
            let artifact = upstreamArtifacts["\(adapterID)/\(variant.qualifiedID)"],
            artifact.adapterID == adapterID,
            artifact.variantID == variant.qualifiedID,
            artifact.revision == pack.source.revision,
            artifact.contentDigest == variant.contentDigest
        {
            upstreamArtifact = artifact.payload
        } else {
            upstreamArtifact = nil
        }
        switch sourcePolicy {
        case .preferUpstream:
            if let upstreamArtifact {
                return ResolvedSource(type: .upstream, revision: pack.source.revision, artifact: upstreamArtifact)
            }
            return ResolvedSource(type: .generated, revision: pack.source.revision, artifact: nil)
        case .requireUpstream:
            guard let upstreamArtifact else { return nil }
            return ResolvedSource(type: .upstream, revision: pack.source.revision, artifact: upstreamArtifact)
        case .useGenerated:
            return ResolvedSource(type: .generated, revision: pack.source.revision, artifact: nil)
        }
    }

    internal static func capabilityOutcome(
        for error: any Error,
        fallbackState: ConfigurationState,
        fallbackDetail: String? = nil
    ) -> (configurationState: ConfigurationState, activationReach: ActivationReach, detail: String) {
        if let outcomeError = error as? any CapabilityOutcomeError {
            return (
                outcomeError.capabilityConfigurationState,
                outcomeError.capabilityActivationReach,
                outcomeError.capabilityOutcomeDetail
            )
        }
        return (fallbackState, .unavailable, fallbackDetail ?? String(describing: error))
    }

    static func worstReach(_ left: ActivationReach, _ right: ActivationReach) -> ActivationReach {
        let order: [ActivationReach] = [
            .currentInstances,
            .nextPrompt,
            .reloadRequired,
            .newProcessesOnly,
            .unavailable,
        ]
        guard let leftIndex = order.firstIndex(of: left), let rightIndex = order.firstIndex(of: right) else {
            return .unavailable
        }
        return order[max(leftIndex, rightIndex)]
    }
}

public actor RecordingThemeAdapter: ThemeAdapter {
    public let id = "recording"
    public let version = "1"
    public let payloadVersion = "1"
    private var preparedArtifacts: [Data] = []
    private var appliedArtifactsStorage: [Data] = []

    public init() {}

    public func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> AdapterPlan {
        let artifact: Data
        if let upstreamArtifact = theme.upstreamArtifact {
            artifact = upstreamArtifact
        } else {
            artifact = try GeneratedArtifactEncoder.encode(
                variant: theme.variant,
                themeSchemaVersion: theme.themeSchemaVersion,
                sourceRevision: theme.sourceRevision,
                contentDigest: theme.contentDigest,
                compilerVersion: theme.compilerVersion
            )
        }
        preparedArtifacts.append(artifact)
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
            capturedPreChangeState: Data("recording-target-before-theme".utf8),
            sourceType: theme.sourceType,
            sourceRevision: theme.sourceRevision,
            activationReach: .currentInstances
        )
    }

    public func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        guard plan.payload.adapterID == id,
            plan.payload.adapterVersion == version,
            plan.payload.payloadVersion == payloadVersion
        else {
            throw RecordingThemeAdapterError.incompatiblePayload
        }
        guard preparedArtifacts.contains(plan.payload.payload) else {
            throw RecordingThemeAdapterError.artifactWasNotPrepared
        }
        appliedArtifactsStorage.append(plan.payload.payload)
        return AdapterReceipt(configurationState: .updated, runningInstanceReach: .currentInstances)
    }

    public func appliedArtifacts() -> [Data] {
        appliedArtifactsStorage
    }
}

public enum RecordingThemeAdapterError: Error, Equatable, Sendable {
    case artifactWasNotPrepared
    case incompatiblePayload
}

private struct GeneratedArtifact: Codable, Equatable, Sendable {
    let variantID: String
    let themeSchemaVersion: Int
    let sourceRevision: String
    let contentDigest: String
    let compilerVersion: String
    let appearance: ThemeAppearance
    let roles: [ArtifactRole]
}

private struct ResolvedSource {
    let type: ThemeSourceKind
    let revision: String
    let artifact: Data?
}

private struct ArtifactRole: Codable, Equatable, Sendable {
    let role: String
    let color: String
}

private enum GeneratedArtifactEncoder {
    static func encode(
        variant: ThemeVariant,
        themeSchemaVersion: Int,
        sourceRevision: String,
        contentDigest: String,
        compilerVersion: String
    ) throws -> Data {
        let artifact = GeneratedArtifact(
            variantID: variant.qualifiedID,
            themeSchemaVersion: themeSchemaVersion,
            sourceRevision: sourceRevision,
            contentDigest: contentDigest,
            compilerVersion: compilerVersion,
            appearance: variant.appearance,
            roles: variant.roles
                .map { ArtifactRole(role: $0.key.rawValue, color: $0.value.rawValue) }
                .sorted { $0.role < $1.role }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(artifact)
    }
}
