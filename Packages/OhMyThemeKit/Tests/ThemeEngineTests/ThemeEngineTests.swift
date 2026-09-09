import Foundation
import Persistence
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Theme engine")
struct ThemeEngineTests {
    @Test("Preparation creates an Apply Plan without applying the recording target")
    func preparationIsReadOnly() async throws {
        let adapter = RecordingThemeAdapter()
        let engine = ThemeEngine(
            packs: [testPack],
            adapters: [adapter],
            sourcePolicy: .preferUpstream
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.plan"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ]
        )

        let plan = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        #expect(plan.variantID == "test-pack/dark")
        #expect(plan.sourceType == .generated)
        #expect(plan.sourceRevision == "reviewed-revision")
        #expect(plan.activationReach == .currentInstances)
        #expect(plan.setupNeeds.isEmpty)
        #expect(plan.conflicts.isEmpty)
        #expect(plan.unavailableCapabilities.isEmpty)
        #expect(plan.userActions.isEmpty)
        #expect(plan.targetPlans.count == 1)
        #expect(plan.targetPlans[0].payload.adapterID == "recording")
        #expect(plan.targetPlans[0].payload.adapterVersion == "1")
        #expect(plan.targetPlans[0].payload.payloadVersion == "1")
        #expect(await adapter.appliedArtifacts().isEmpty)

        let serializedPlan = try JSONEncoder().encode(plan)
        let restoredPlan = try JSONDecoder().decode(ApplyPlan.self, from: serializedPlan)
        #expect(restoredPlan == plan)
    }

    @Test("Applying a plan sends the prepared artifact and groups the report by target")
    func applyingPlanUsesPreparedArtifact() async throws {
        let adapter = RecordingThemeAdapter()
        let engine = ThemeEngine(
            packs: [testPack],
            adapters: [adapter],
            sourcePolicy: .preferUpstream
        )
        let target = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "recording.apply"),
            displayName: "Recording Target",
            adapterID: "recording"
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [target]
        )

        let plan = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let report = try await engine.apply(planID: plan.id)
        let artifacts = await adapter.appliedArtifacts()

        #expect(artifacts == [plan.targetPlans[0].artifact])
        #expect(report.outcomes.count == 1)
        #expect(report.outcomes[0].targetInstanceID == target.id)
        #expect(report.outcomes[0].configurationState == .updated)
        #expect(report.outcomes[0].runningInstanceReach == .currentInstances)
        #expect(report.outcomes[0].sourceRevision == "reviewed-revision")
    }

    @Test("Prefer upstream uses a supplied pinned upstream artifact")
    func preferUpstreamUsesPinnedArtifact() async throws {
        let adapter = RecordingThemeAdapter()
        let upstreamArtifact = Data([0x01, 0x02, 0x03])
        let engine = ThemeEngine(
            packs: [testPack],
            adapters: [adapter],
            sourcePolicy: .preferUpstream,
            upstreamArtifacts: [
                "recording/test-pack/dark": PinnedUpstreamArtifact(
                    adapterID: "recording",
                    variantID: "test-pack/dark",
                    revision: "reviewed-revision",
                    contentDigest: "sha256:test",
                    payload: upstreamArtifact
                )
            ]
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.upstream"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ]
        )

        let plan = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        #expect(plan.sourceType == .upstream)
        #expect(plan.targetPlans[0].artifact == upstreamArtifact)
    }

    @Test("Unavailable targets remain reportable during apply")
    func unavailableTargetsRemainReportable() async throws {
        let engine = ThemeEngine(packs: [testPack], adapters: [])
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "missing.target"),
                    displayName: "Missing Target",
                    adapterID: "missing"
                )
            ]
        )

        let plan = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let report = try await engine.apply(planID: plan.id)

        #expect(plan.unavailableCapabilities == ["theme"])
        #expect(report.outcomes.count == 1)
        #expect(report.outcomes[0].configurationState == .unavailable)
        #expect(report.outcomes[0].capabilityID == "theme")
    }

    @Test("Require upstream reports unavailable provenance without generating an artifact")
    func requireUpstreamReportsUnavailableProvenance() async throws {
        let engine = ThemeEngine(
            packs: [testPack],
            adapters: [RecordingThemeAdapter()],
            sourcePolicy: .requireUpstream
        )
        let workspace = Workspace(id: .myMac, displayName: "My Mac", connectedTargetInstances: [])

        let plan = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        #expect(plan.sourceType == .unavailable)
        #expect(plan.activationReach == .unavailable)
        #expect(plan.targetPlans.isEmpty)
    }

    @Test("Require upstream uses a valid target-specific pinned artifact")
    func requireUpstreamUsesPinnedArtifact() async throws {
        let adapter = RecordingThemeAdapter()
        let upstreamArtifact = Data([0x04, 0x05, 0x06])
        let engine = ThemeEngine(
            packs: [testPack],
            adapters: [adapter],
            sourcePolicy: .requireUpstream,
            upstreamArtifacts: [
                "recording/test-pack/dark": PinnedUpstreamArtifact(
                    adapterID: "recording",
                    variantID: "test-pack/dark",
                    revision: "reviewed-revision",
                    contentDigest: "sha256:test",
                    payload: upstreamArtifact
                )
            ]
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.required"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ]
        )

        let plan = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        #expect(plan.sourceType == .upstream)
        #expect(plan.targetPlans[0].artifact == upstreamArtifact)
    }

    @Test("Preparation persists the exact adapter payload envelope when storage is configured")
    func preparationPersistsPayloadEnvelope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-engine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let engine = ThemeEngine(
            packs: [testPack],
            adapters: [RecordingThemeAdapter()],
            persistence: persistence
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.persisted"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ]
        )

        let plan = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let envelope = try persistence.loadPayloadEnvelope(
            id: "\(plan.id.uuidString).recording.persisted"
        )

        #expect(envelope.adapterID == "recording")
        #expect(envelope.payload == plan.targetPlans[0].payload.payload)
        #expect(
            try persistence.loadRestorationContent(forEnvelopeID: envelope.id)
                == Data("recording-target-before-theme".utf8)
        )
    }


    @Test("Status verification reports applied, pending, and needs-attention and separates assignment from outcomes")
    func verifyStatusSeparatesAssignmentAndReportsCounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )

        let appliedTarget = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "target.applied"),
            displayName: "Applied Target",
            adapterID: "custom.applied"
        )
        let pendingTarget = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "target.pending"),
            displayName: "Pending Target",
            adapterID: "custom.pending"
        )
        let attentionTarget = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "target.attention"),
            displayName: "Attention Target",
            adapterID: "custom.attention"
        )

        let appliedAdapter = ConfigurableVerificationAdapter(id: "custom.applied", status: .applied, detail: "All set")
        let pendingAdapter = ConfigurableVerificationAdapter(id: "custom.pending", status: .pending, detail: "Will apply")
        let attentionAdapter = ConfigurableVerificationAdapter(id: "custom.attention", status: .needsAttention, detail: "Needs permission")

        let engine = ThemeEngine(
            packs: [testPack],
            adapters: [appliedAdapter, pendingAdapter, attentionAdapter],
            persistence: persistence
        )

        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [appliedTarget, pendingTarget, attentionTarget],
            themeAssignment: .fixed(variantID: "test-pack/dark")
        )
        try persistence.saveWorkspace(workspace)

        let status = try await engine.verifyStatus(workspace: workspace)

        #expect(status.appliedCount == 1)
        #expect(status.pendingCount == 1)
        #expect(status.needsAttentionCount == 1)
        #expect(status.totalTargetCount == 3)
        #expect(status.isFullyApplied == false)
        #expect(status.desiredThemeAssignment == .fixed(variantID: "test-pack/dark"))

        let appliedOutcome = status.targetOutcomes.first(where: { $0.targetInstanceID == appliedTarget.id })
        #expect(appliedOutcome?.status == .applied)
        #expect(appliedOutcome?.verifiedVariantID == "test-pack/dark")
        #expect(appliedOutcome?.detail == "All set")

        let pendingOutcome = status.targetOutcomes.first(where: { $0.targetInstanceID == pendingTarget.id })
        #expect(pendingOutcome?.status == .pending)
        #expect(pendingOutcome?.verifiedVariantID == nil)

        let attentionOutcome = status.targetOutcomes.first(where: { $0.targetInstanceID == attentionTarget.id })
        #expect(attentionOutcome?.status == .needsAttention)
        #expect(attentionOutcome?.detail == "Needs permission")

        let persistedOutcomes = try persistence.loadTargetVerificationOutcomes(workspaceID: workspace.id)
        #expect(persistedOutcomes.count == 3)
        #expect(persistedOutcomes.first(where: { $0.targetInstanceID == appliedTarget.id })?.status == .applied)

        let fullyAppliedWorkspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [appliedTarget],
            themeAssignment: .fixed(variantID: "test-pack/dark")
        )
        let fullyAppliedStatus = try await engine.verifyStatus(workspace: fullyAppliedWorkspace)
        #expect(fullyAppliedStatus.isFullyApplied == true)
        #expect(fullyAppliedStatus.appliedCount == 1)
        #expect(fullyAppliedStatus.pendingCount == 0)
        #expect(fullyAppliedStatus.needsAttentionCount == 0)
    }

}

private let testPack = ThemePack(
    schemaVersion: 1,
    id: "test-pack",
    displayName: "Test Pack",
    author: "Test",
    source: ThemeSource(
        type: .upstream,
        url: URL(string: "https://example.com/theme")!,
        revision: "reviewed-revision",
        license: "MIT",
        attribution: "Test contributors"
    ),
    variants: [
        ThemeVariant(
            id: "dark",
            displayName: "Dark",
            appearance: .dark,
            contentDigest: "sha256:test",
            roles: Dictionary(
                uniqueKeysWithValues: SemanticRole.allCases.map {
                    ($0, ThemeColor(rawValue: "#112233"))
                })
        )
    ]
)


private actor ConfigurableVerificationAdapter: ThemeAdapter {
    let id: String
    let version = "1"
    let payloadVersion = "1"
    let status: TargetVerificationStatus
    let detail: String?

    init(id: String, status: TargetVerificationStatus, detail: String?) {
        self.id = id
        self.status = status
        self.detail = detail
    }

    func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> AdapterPlan {
        AdapterPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capabilityID: "test",
            payload: AdapterPayloadEnvelope(
                adapterID: id,
                adapterVersion: version,
                payloadVersion: payloadVersion,
                payload: Data()
            ),
            intendedChangeDigest: "test",
            sourceType: .generated,
            sourceRevision: "rev",
            activationReach: .currentInstances
        )
    }

    func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        AdapterReceipt(configurationState: .updated, runningInstanceReach: .currentInstances)
    }

    func verify(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> (status: TargetVerificationStatus, detail: String?) {
        (status, detail)
    }
}
