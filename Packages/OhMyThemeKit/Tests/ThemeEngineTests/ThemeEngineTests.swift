import Foundation
import Persistence
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Theme engine")
struct ThemeEngineTests {
    @Test("Preparation creates a preview without applying the recording target")
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
                    id: TargetInstanceID(rawValue: "recording.preview"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ]
        )

        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        #expect(preview.variantID == "test-pack/dark")
        #expect(preview.sourceType == .generated)
        #expect(preview.sourceRevision == "reviewed-revision")
        #expect(preview.activationReach == .currentInstances)
        #expect(preview.setupNeeds.isEmpty)
        #expect(preview.conflicts.isEmpty)
        #expect(preview.unavailableCapabilities.isEmpty)
        #expect(preview.userActions.isEmpty)
        #expect(preview.targetPlans.count == 1)
        #expect(preview.targetPlans[0].payload.adapterID == "recording")
        #expect(preview.targetPlans[0].payload.adapterVersion == "1")
        #expect(preview.targetPlans[0].payload.payloadVersion == "1")
        #expect(await adapter.appliedArtifacts().isEmpty)

        let serializedPreview = try JSONEncoder().encode(preview)
        let restoredPreview = try JSONDecoder().decode(ThemePreview.self, from: serializedPreview)
        #expect(restoredPreview == preview)
    }

    @Test("Applying a preview sends the prepared artifact and groups the report by target")
    func applyingPreviewUsesPreparedArtifact() async throws {
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

        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let report = try await engine.apply(previewID: preview.id)
        let artifacts = await adapter.appliedArtifacts()

        #expect(artifacts == [preview.targetPlans[0].artifact])
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

        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        #expect(preview.sourceType == .upstream)
        #expect(preview.targetPlans[0].artifact == upstreamArtifact)
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

        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let report = try await engine.apply(previewID: preview.id)

        #expect(preview.unavailableCapabilities == ["theme"])
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

        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        #expect(preview.sourceType == .unavailable)
        #expect(preview.activationReach == .unavailable)
        #expect(preview.targetPlans.isEmpty)
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

        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        #expect(preview.sourceType == .upstream)
        #expect(preview.targetPlans[0].artifact == upstreamArtifact)
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

        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let envelope = try persistence.loadPayloadEnvelope(
            id: "\(preview.id.uuidString).recording.persisted"
        )

        #expect(envelope.adapterID == "recording")
        #expect(envelope.payload == preview.targetPlans[0].payload.payload)
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
