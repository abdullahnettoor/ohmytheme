import Foundation
import Persistence
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Full Workspace lifecycle qualification (issue #23)")
struct WorkspaceLifecycleQualificationTests {
    @Test("Repeated full-Workspace switching, Undo, and Restore and Disconnect preserve every baseline")
    func repeatedWorkspaceLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-workspace-qualification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        try store.saveWorkspace(.myMac)

        let adapterIDs = ["macos.appearance", "ghostty", "vscode", "starship"]
        let adapters = adapterIDs.map {
            RecordingWritableAdapter(id: $0, initialWorld: Data("baseline.\($0)".utf8))
        }
        let instances = adapterIDs.map {
            ConnectedTargetInstance(
                id: TargetInstanceID(rawValue: "\($0).qualification"),
                displayName: $0,
                adapterID: $0
            )
        }
        let pack = qualificationPack()
        let engine = ThemeEngine(
            packs: [pack],
            adapters: adapters,
            persistence: store
        )

        for instance in instances {
            let workspace = try store.loadWorkspace().workspace
            let report = try await engine.connect(instance: instance, workspace: workspace)
            #expect(report.outcomes.map(\.configurationState) == [.updated])
        }

        var workspace = try store.loadWorkspace().workspace
        workspace = workspace.assigning(variantID: "qualification/aurora")
        try store.saveWorkspace(workspace)

        let firstApply = try await apply(engine: engine, workspace: workspace)
        #expect(firstApply.outcomes.map(\.configurationState) == Array(repeating: .updated, count: 4))

        workspace = workspace.assigning(variantID: "qualification/mocha")
        try store.saveWorkspace(workspace)
        let secondApply = try await apply(engine: engine, workspace: workspace)
        #expect(secondApply.outcomes.map(\.configurationState) == Array(repeating: .updated, count: 4))

        let undo = try await engine.undoLast(workspace: workspace)
        #expect(undo.outcomes.map(\.configurationState) == Array(repeating: .updated, count: 4))
        for adapter in adapters {
            #expect(await adapter.currentWorldBytes() == Data("recording-artifact.digest-aurora".utf8))
        }

        for instance in instances {
            let current = try store.loadWorkspace().workspace
            let report = try await engine.disconnect(instance: instance, workspace: current)
            #expect(report.outcomes.map(\.configurationState) == [.updated])
        }
        #expect(try store.loadWorkspace().workspace.connectedTargetInstances.isEmpty)
        for (adapter, adapterID) in zip(adapters, adapterIDs) {
            #expect(await adapter.currentWorldBytes() == Data("baseline.\(adapterID)".utf8))
        }

        for instance in instances {
            let current = try store.loadWorkspace().workspace
            _ = try await engine.connect(instance: instance, workspace: current)
        }
        workspace = try store.loadWorkspace().workspace.assigning(variantID: "qualification/aurora")
        let repeatedApply = try await apply(engine: engine, workspace: workspace)
        #expect(repeatedApply.outcomes.map(\.configurationState) == Array(repeating: .updated, count: 4))

        for instance in instances {
            let current = try store.loadWorkspace().workspace
            _ = try await engine.disconnect(instance: instance, workspace: current)
        }
        for (adapter, adapterID) in zip(adapters, adapterIDs) {
            #expect(await adapter.currentWorldBytes() == Data("baseline.\(adapterID)".utf8))
        }
    }

    private func apply(engine: ThemeEngine, workspace: Workspace) async throws -> DurableApplyReport {
        let preview = try await engine.prepare(workspace: workspace)
        return try await engine.applyDurable(previewID: preview.id, workspace: workspace)
    }

    private func qualificationPack() -> ThemePack {
        ThemePack(
            schemaVersion: 1,
            id: "qualification",
            displayName: "Qualification",
            author: "Oh My Theme",
            source: ThemeSource(
                type: .generated,
                url: URL(string: "https://example.com/qualification")!,
                revision: "issue-23",
                license: "MIT",
                attribution: "Oh My Theme"
            ),
            variants: [
                variant(id: "aurora", digest: "digest-aurora"),
                variant(id: "mocha", digest: "digest-mocha"),
            ]
        )
    }

    private func variant(id: String, digest: String) -> ThemeVariant {
        ThemeVariant(
            id: id,
            displayName: id,
            appearance: .dark,
            contentDigest: digest,
            roles: Dictionary(
                uniqueKeysWithValues: SemanticRole.allCases.map {
                    ($0, ThemeColor(rawValue: "#112233"))
                }
            )
        )
    }
}

private extension Workspace {
    func assigning(variantID: String) -> Workspace {
        Workspace(
            id: id,
            displayName: displayName,
            connectedTargetInstances: connectedTargetInstances,
            themeAssignment: .fixed(variantID: variantID)
        )
    }
}
