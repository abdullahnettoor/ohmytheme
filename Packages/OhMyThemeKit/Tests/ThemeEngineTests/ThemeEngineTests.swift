import Foundation
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
        #expect(preview.sourceType == .upstream)
        #expect(preview.sourceRevision == "reviewed-revision")
        #expect(preview.activationReach == .currentInstances)
        #expect(preview.setupNeeds.isEmpty)
        #expect(preview.conflicts.isEmpty)
        #expect(preview.unavailableCapabilities.isEmpty)
        #expect(preview.userActions.isEmpty)
        #expect(preview.targetPlans.count == 1)
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
