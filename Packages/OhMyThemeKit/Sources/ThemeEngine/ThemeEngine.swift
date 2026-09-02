import Foundation
import ThemeModel

public enum ThemeSourcePolicy: String, Codable, Equatable, Sendable {
    case preferUpstream
    case requireUpstream
    case useGenerated
}

public enum ThemeSourceKind: String, Codable, Equatable, Sendable {
    case upstream
    case generated
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
    public let sourceType: ThemeSourceKind
    public let sourceRevision: String
    public let attribution: String
    public let themeSchemaVersion: Int
    public let contentDigest: String
    public let compilerVersion: String
    public let artifact: Data

    public init(
        variantID: String,
        sourceType: ThemeSourceKind,
        sourceRevision: String,
        attribution: String,
        themeSchemaVersion: Int,
        contentDigest: String,
        compilerVersion: String,
        artifact: Data
    ) {
        self.variantID = variantID
        self.sourceType = sourceType
        self.sourceRevision = sourceRevision
        self.attribution = attribution
        self.themeSchemaVersion = themeSchemaVersion
        self.contentDigest = contentDigest
        self.compilerVersion = compilerVersion
        self.artifact = artifact
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

public struct AdapterPlan: Codable, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let adapterVersion: String
    public let capabilityID: String
    public let payload: AdapterPayloadEnvelope
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
        self.userActions = userActions
        self.targetPlans = targetPlans
    }
}

public protocol ThemeAdapter: Sendable {
    var id: String { get }
    var version: String { get }

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
}

public actor ThemeEngine {
    private let packs: [ThemePack]
    private let adapters: [String: any ThemeAdapter]
    private let sourcePolicy: ThemeSourcePolicy
    private var previews: [UUID: ThemePreview] = [:]

    public init(
        packs: [ThemePack],
        adapters: [any ThemeAdapter],
        sourcePolicy: ThemeSourcePolicy = .preferUpstream
    ) {
        self.packs = packs
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
        self.sourcePolicy = sourcePolicy
    }

    public func prepare(themeVariantID: String, workspace: Workspace) async throws -> ThemePreview {
        guard let packAndVariant = findVariant(themeVariantID) else {
            throw ThemeEngineError.variantNotFound(themeVariantID)
        }
        let (pack, variant) = packAndVariant
        let resolvedSource = resolveSource(for: pack)
        guard resolvedSource != nil || sourcePolicy != .requireUpstream else {
            let preview = ThemePreview(
                id: UUID(),
                variantID: variant.qualifiedID,
                sourceType: .generated,
                sourceRevision: pack.source.revision,
                attribution: pack.source.attribution,
                activationReach: .unavailable,
                setupNeeds: [],
                conflicts: [],
                unavailableCapabilities: workspace.connectedTargetInstances.map(\.displayName),
                unavailableTargetInstanceIDs: workspace.connectedTargetInstances.map(\.id),
                userActions: [],
                targetPlans: []
            )
            previews[preview.id] = preview
            return preview
        }
        let source = resolvedSource ?? (type: .generated, revision: pack.source.revision)
        let preparedTheme = PreparedTheme(
            variantID: variant.qualifiedID,
            sourceType: source.type,
            sourceRevision: pack.source.revision,
            attribution: pack.source.attribution,
            themeSchemaVersion: pack.schemaVersion,
            contentDigest: variant.contentDigest,
            compilerVersion: "theme-compiler-1",
            artifact: try encodeArtifact(for: variant, pack: pack)
        )

        var targetPlans: [AdapterPlan] = []
        var setupNeeds: [UserAction] = []
        var conflicts: [String] = []
        var unavailableCapabilities: [String] = []
        var unavailableTargetInstanceIDs: [TargetInstanceID] = []
        for instance in workspace.connectedTargetInstances {
            guard let adapter = adapters[instance.adapterID] else {
                unavailableCapabilities.append(instance.displayName)
                unavailableTargetInstanceIDs.append(instance.id)
                continue
            }
            do {
                let plan = try await adapter.prepareApply(instance: instance, theme: preparedTheme)
                targetPlans.append(plan)
                setupNeeds.append(contentsOf: plan.setupNeeds)
                conflicts.append(contentsOf: plan.conflicts)
            } catch {
                unavailableCapabilities.append(instance.displayName)
                unavailableTargetInstanceIDs.append(instance.id)
            }
        }
        if workspace.connectedTargetInstances.isEmpty {
            setupNeeds.append(
                UserAction(
                    title: "Connect an app",
                    detail: "This preview has no Target Instances to change."
                )
            )
        }

        let preview = ThemePreview(
            id: UUID(),
            variantID: variant.qualifiedID,
            sourceType: source.type,
            sourceRevision: pack.source.revision,
            attribution: pack.source.attribution,
            activationReach: targetPlans.isEmpty
                ? .unavailable
                : targetPlans.map(\.activationReach).reduce(.currentInstances, Self.worstReach),
            setupNeeds: setupNeeds,
            conflicts: conflicts,
            unavailableCapabilities: unavailableCapabilities,
            unavailableTargetInstanceIDs: unavailableTargetInstanceIDs,
            userActions: setupNeeds,
            targetPlans: targetPlans
        )
        previews[preview.id] = preview
        return preview
    }

    public func apply(previewID: UUID) async throws -> ApplyReport {
        guard let preview = previews.removeValue(forKey: previewID) else {
            throw ThemeEngineError.previewNotFound(previewID)
        }

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
        return ApplyReport(variantID: preview.variantID, outcomes: outcomes)
    }

    private func findVariant(_ qualifiedID: String) -> (ThemePack, ThemeVariant)? {
        packs.lazy
            .flatMap { pack in pack.variants.map { (pack, $0) } }
            .first { $0.1.qualifiedID == qualifiedID }
    }

    private func resolveSource(for pack: ThemePack) -> (type: ThemeSourceKind, revision: String)? {
        switch sourcePolicy {
        case .preferUpstream:
            return (.generated, pack.source.revision)
        case .requireUpstream:
            return nil
        case .useGenerated:
            return (.generated, pack.source.revision)
        }
    }

    private func encodeArtifact(for variant: ThemeVariant, pack: ThemePack) throws -> Data {
        let artifact = GeneratedArtifact(
            variantID: variant.qualifiedID,
            themeSchemaVersion: pack.schemaVersion,
            sourceRevision: pack.source.revision,
            contentDigest: variant.contentDigest,
            compilerVersion: "theme-compiler-1",
            appearance: variant.appearance,
            roles: variant.roles
                .map { ArtifactRole(role: $0.key.rawValue, color: $0.value.rawValue) }
                .sorted { $0.role < $1.role }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(artifact)
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
    private var preparedArtifacts: [Data] = []
    private var appliedArtifactsStorage: [Data] = []

    public init() {}

    public func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> AdapterPlan {
        preparedArtifacts.append(theme.artifact)
        return AdapterPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capabilityID: "theme",
            payload: AdapterPayloadEnvelope(
                adapterID: id,
                adapterVersion: version,
                payloadVersion: "1",
                payload: theme.artifact
            ),
            sourceType: theme.sourceType,
            sourceRevision: theme.sourceRevision,
            activationReach: .currentInstances
        )
    }

    public func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        guard plan.payload.adapterID == id, plan.payload.adapterVersion == version else {
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

private struct ArtifactRole: Codable, Equatable, Sendable {
    let role: String
    let color: String
}
