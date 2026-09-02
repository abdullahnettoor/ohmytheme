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
    case newProcessesOnly
    case reloadRequired
    case unavailable
}

public enum ConfigurationState: String, Codable, Equatable, Sendable {
    case updated
    case unchanged
    case conflicted
    case failed
    case unavailable
}

public struct UserAction: Codable, Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
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

    public init(
        configurationState: ConfigurationState,
        runningInstanceReach: ActivationReach,
        detail: String? = nil
    ) {
        self.configurationState = configurationState
        self.runningInstanceReach = runningInstanceReach
        self.detail = detail
    }
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

    public init(
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        capabilityID: String,
        sourceType: ThemeSourceKind,
        sourceRevision: String,
        configurationState: ConfigurationState,
        runningInstanceReach: ActivationReach,
        detail: String? = nil
    ) {
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.capabilityID = capabilityID
        self.sourceType = sourceType
        self.sourceRevision = sourceRevision
        self.configurationState = configurationState
        self.runningInstanceReach = runningInstanceReach
        self.detail = detail
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

public struct ThemePreview: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
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

public protocol ThemeAdapter: Sendable {
    var id: String { get }
    var version: String { get }
    var payloadVersion: String { get }

    func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> AdapterPlan

    func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt
}

public enum ThemeEngineError: Error, Equatable, Sendable {
    case variantNotFound(String)
    case previewNotFound(UUID)
    case engineUnavailable
    case applyInProgress
}

public actor ThemeEngine {
    private let packs: [ThemePack]
    private let adapters: [String: any ThemeAdapter]
    private let sourcePolicy: ThemeSourcePolicy
    private let upstreamArtifacts: [String: PinnedUpstreamArtifact]
    private let persistence: PersistenceStore?
    private var previews: [UUID: ThemePreview] = [:]
    private var isApplying = false

    public init(
        packs: [ThemePack],
        adapters: [any ThemeAdapter],
        sourcePolicy: ThemeSourcePolicy = .preferUpstream,
        upstreamArtifacts: [String: PinnedUpstreamArtifact] = [:],
        persistence: PersistenceStore? = nil
    ) {
        self.packs = packs
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
        self.sourcePolicy = sourcePolicy
        self.upstreamArtifacts = upstreamArtifacts
        self.persistence = persistence
    }

    public func prepare(themeVariantID: String, workspace: Workspace) async throws -> ThemePreview {
        guard let packAndVariant = findVariant(themeVariantID) else {
            throw ThemeEngineError.variantNotFound(themeVariantID)
        }
        let (pack, variant) = packAndVariant
        let resolvedSource = resolveSource(for: pack, variant: variant, adapterID: nil)
        if sourcePolicy == .requireUpstream,
            resolvedSource == nil,
            workspace.connectedTargetInstances.isEmpty
        {
            let preview = ThemePreview(
                id: UUID(),
                variantID: variant.qualifiedID,
                sourceType: .unavailable,
                sourceRevision: pack.source.revision,
                attribution: pack.source.attribution,
                activationReach: .unavailable,
                setupNeeds: [],
                conflicts: [],
                unavailableCapabilities: workspace.connectedTargetInstances.map { _ in "theme" },
                unavailableTargetInstanceIDs: workspace.connectedTargetInstances.map(\.id),
                userActions: [],
                targetPlans: []
            )
            previews[preview.id] = preview
            return preview
        }
        let source =
            resolvedSource
            ?? ResolvedSource(type: .unavailable, revision: pack.source.revision, artifact: nil)
        let previewID = UUID()

        var targetPlans: [AdapterPlan] = []
        var setupNeeds: [UserAction] = []
        var conflicts: [String] = []
        var unavailableCapabilities: [String] = []
        var unavailableTargetInstanceIDs: [TargetInstanceID] = []
        var preparationFailures: [TargetPreparationFailure] = []
        var userActions: [UserAction] = []
        for instance in workspace.connectedTargetInstances {
            guard let adapter = adapters[instance.adapterID] else {
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
                let plan = try await adapter.prepareApply(instance: instance, theme: preparedTheme)
                if let persistence {
                    try persist(plan: plan, previewID: previewID, persistence: persistence)
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
                    detail: "This preview has no Target Instances to change."
                )
            )
            userActions.append(contentsOf: setupNeeds)
        }

        let sourceTypes = Set(targetPlans.map(\.sourceType))
        let previewSourceType: ThemeSourceKind
        if sourceTypes.count == 1, let sourceType = sourceTypes.first {
            previewSourceType = sourceType
        } else if sourceTypes.isEmpty {
            previewSourceType = source.type
        } else {
            previewSourceType = .mixed
        }
        let preview = ThemePreview(
            id: previewID,
            variantID: variant.qualifiedID,
            sourceType: previewSourceType,
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
        previews[preview.id] = preview
        return preview
    }

    public func apply(previewID: UUID) async throws -> ApplyReport {
        guard !isApplying else {
            throw ThemeEngineError.applyInProgress
        }
        guard let preview = previews.removeValue(forKey: previewID) else {
            throw ThemeEngineError.previewNotFound(previewID)
        }
        isApplying = true
        defer { isApplying = false }

        var outcomes = preview.targetPlans.map { plan in
            TargetCapabilityOutcome(
                targetInstanceID: plan.targetInstanceID,
                adapterID: plan.adapterID,
                capabilityID: plan.capabilityID,
                sourceType: plan.sourceType,
                sourceRevision: plan.sourceRevision,
                configurationState: .failed,
                runningInstanceReach: .unavailable,
                detail: "The Target Instance did not apply."
            )
        }
        for (index, plan) in preview.targetPlans.enumerated() {
            guard let adapter = adapters[plan.adapterID] else {
                outcomes[index] = TargetCapabilityOutcome(
                    targetInstanceID: plan.targetInstanceID,
                    adapterID: plan.adapterID,
                    capabilityID: plan.capabilityID,
                    sourceType: plan.sourceType,
                    sourceRevision: plan.sourceRevision,
                    configurationState: .unavailable,
                    runningInstanceReach: .unavailable,
                    detail: "The adapter is unavailable."
                )
                continue
            }
            guard plan.adapterID == plan.payload.adapterID,
                plan.adapterVersion == plan.payload.adapterVersion,
                plan.adapterVersion == adapter.version,
                plan.payload.payloadVersion == adapter.payloadVersion
            else {
                outcomes[index] = TargetCapabilityOutcome(
                    targetInstanceID: plan.targetInstanceID,
                    adapterID: plan.adapterID,
                    capabilityID: plan.capabilityID,
                    sourceType: plan.sourceType,
                    sourceRevision: plan.sourceRevision,
                    configurationState: .failed,
                    runningInstanceReach: .unavailable,
                    detail: "The adapter payload envelope is incompatible."
                )
                continue
            }
            do {
                let receipt = try await adapter.apply(plan)
                outcomes[index] = TargetCapabilityOutcome(
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
                outcomes[index] = TargetCapabilityOutcome(
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
        outcomes.append(
            contentsOf: preview.unavailableTargetInstanceIDs.map {
                TargetCapabilityOutcome(
                    targetInstanceID: $0,
                    adapterID: "unavailable",
                    capabilityID: "theme",
                    sourceType: preview.sourceType,
                    sourceRevision: preview.sourceRevision,
                    configurationState: .unavailable,
                    runningInstanceReach: .unavailable,
                    detail: "No compatible adapter prepared this Target Instance."
                )
            })
        outcomes.append(
            contentsOf: preview.preparationFailures.map {
                TargetCapabilityOutcome(
                    targetInstanceID: $0.targetInstanceID,
                    adapterID: $0.adapterID,
                    capabilityID: "theme",
                    sourceType: preview.sourceType,
                    sourceRevision: preview.sourceRevision,
                    configurationState: .failed,
                    runningInstanceReach: .unavailable,
                    detail: $0.detail
                )
            })
        return ApplyReport(variantID: preview.variantID, outcomes: outcomes)
    }

    private func findVariant(_ qualifiedID: String) -> (ThemePack, ThemeVariant)? {
        packs.lazy
            .flatMap { pack in pack.variants.map { (pack, $0) } }
            .first { $0.1.qualifiedID == qualifiedID }
    }

    private func persist(plan: AdapterPlan, previewID: UUID, persistence: PersistenceStore) throws {
        let envelope = PersistedPayloadEnvelope(
            id: "\(previewID.uuidString).\(plan.targetInstanceID.rawValue)",
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

    private static func worstReach(_ left: ActivationReach, _ right: ActivationReach) -> ActivationReach {
        let order: [ActivationReach] = [
            .currentInstances,
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
