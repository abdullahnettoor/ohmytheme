import Foundation
import Persistence
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Undo the Last Apply Transaction (issue #12)")
struct UndoLastApplyTests {
    // MARK: Helpers

    private static func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        return Fixture(directory: directory, store: store)
    }

    private struct Fixture {
        let directory: URL
        let store: PersistenceStore
    }

    // MARK: AC #1 — LAT is set by any completed transaction that changed ≥1 instance

    @Test("Successful apply becomes the Last Apply Transaction and undo restores prior state")
    func successfulUndoRestoresState() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter(initialWorld: Data("before-theme".utf8))
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.undo"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        _ = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        // World is now the applied artifact.
        let worldAfterApply = await adapter.currentWorldBytes()
        #expect(worldAfterApply != Data("before-theme".utf8))

        let undo = try await engine.undoLast(workspace: workspace)
        #expect(undo.outcomes.count == 1)
        #expect(undo.outcomes[0].configurationState == .updated)
        #expect(undo.outcomes[0].detail == "undone")
        #expect(await adapter.currentWorldBytes() == Data("before-theme".utf8))
    }

    @Test("A partially successful apply is still the LAT and undo reports per-target results")
    func partialApplyIsLatAndUndoIsPerTarget() async throws {
        let fixture = try Self.makeFixture()
        let adapter = FaultyRecordingAdapter(failingInstanceIDs: [TargetInstanceID(rawValue: "recording.b")])
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.a", "recording.b", "recording.c"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        _ = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        let undo = try await engine.undoLast(workspace: workspace)
        // Only the two changed targets are eligible for undo. The failed one is not.
        #expect(undo.outcomes.count == 2)
        let ids = Set(undo.outcomes.map(\.targetInstanceID.rawValue))
        #expect(ids == ["recording.a", "recording.c"])
    }

    // MARK: AC #2 — Skipped / no-change / fully failed does not replace prior undo reference

    @Test("A fully failed apply does not replace the previous Last Apply Transaction")
    func failedApplyDoesNotReplaceLAT() async throws {
        let fixture = try Self.makeFixture()
        let adapter = FaultyRecordingAdapter(failingInstanceIDs: [])
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.first"])
        // First apply: successful → becomes LAT.
        let firstPreview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let firstReport = try await engine.applyDurable(previewID: firstPreview.id, workspace: workspace)

        // Second apply: everyone fails → LAT must remain the first.
        let allFailing = FaultyRecordingAdapter(
            failingInstanceIDs: [TargetInstanceID(rawValue: "recording.second")]
        )
        let engine2 = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [allFailing],
            persistence: fixture.store
        )
        let secondWorkspace = Fixtures.workspace(recordingInstances: ["recording.second"])
        let secondPreview = try await engine2.prepare(themeVariantID: "test-pack/dark", workspace: secondWorkspace)
        _ = try await engine2.applyDurable(previewID: secondPreview.id, workspace: secondWorkspace)

        // Query the LAT — it must still be the first apply.
        let lat = try fixture.store.journalFindLastAppliedTransaction(workspaceID: workspace.id)
        #expect(lat?.id == firstReport.operationID)
    }

    // MARK: AC #3 — Previous LAT durable until replacement reaches terminal states

    @Test("Prior LAT remains valid while a new apply is still in `prepared` state")
    func priorLATRemainsWhileNewApplyIsPrepared() async throws {
        let fixture = try Self.makeFixture()
        let adapter = FaultyRecordingAdapter(failingInstanceIDs: [])
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.old"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let latReport = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        // Simulate a new apply operation that has only reached `prepared` state.
        let inflight = try fixture.store.journalStartOperation(
            kind: .apply,
            workspaceID: workspace.id,
            variantID: "test-pack/dark"
        )

        let lat = try fixture.store.journalFindLastAppliedTransaction(workspaceID: workspace.id)
        #expect(lat?.id == latReport.operationID)
        #expect(lat?.id != inflight.id)
    }

    // MARK: AC #4 — Undo goes through the same journal/recovery machinery

    @Test("Undo produces a journaled undo operation with per-target records")
    func undoIsJournaledLikeApply() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.journal"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        _ = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let undo = try await engine.undoLast(workspace: workspace)

        let operation = try fixture.store.journalLoadOperation(id: undo.operationID)
        #expect(operation?.kind == .undo)
        #expect(operation?.state == .applied)
        let records = try fixture.store.journalLoadRecords(operationID: undo.operationID)
        #expect(records.count == 1)
        #expect(records[0].phase == .applied)
    }

    // MARK: AC #5 — Rollback only when current state matches expected managed state

    @Test("Undo refuses to overwrite external state that no longer matches the intended after-change")
    func undoRefusesOnExternalChange() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.external"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        _ = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        // External edit — the world no longer matches the intended after-change.
        await adapter.mutateWorldExternally(Data("someone-else-took-over".utf8))
        let external = await adapter.currentWorldBytes()

        let undo = try await engine.undoLast(workspace: workspace)
        #expect(undo.outcomes[0].configurationState == .conflicted)
        // The external state must be preserved.
        #expect(await adapter.currentWorldBytes() == external)
    }

    // MARK: AC #6 — Conflicted receipts remain visible and are not silently reused

    @Test("A conflicted undo does not silently retry the same receipt")
    func conflictedReceiptIsNotSilentlyRetried() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.retry"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let applyReport = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        await adapter.mutateWorldExternally(Data("external".utf8))
        _ = try await engine.undoLast(workspace: workspace)

        // A subsequent undo call must not silently reuse the conflicted receipt.
        let second = try? await engine.undoLast(workspace: workspace)
        // Either no LAT remains actionable (throws) or the report has zero outcomes to act on.
        if let second {
            #expect(second.outcomes.isEmpty)
        }
        // Confirm the source record is preserved as `.conflicted`, still visible.
        let sourceRecords = try fixture.store.journalLoadRecords(operationID: applyReport.operationID)
        #expect(sourceRecords[0].phase == .conflicted)
    }

    // MARK: AC #7 — Interrupted undo reconciles

    @Test("An interrupted undo is reconciled before the next mutation")
    func interruptedUndoReconciles() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.interrupt"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        _ = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        // Interrupt the rollback partway.
        await adapter.setInterruption(.beforeRollback, enabled: true)
        _ = try await engine.undoLast(workspace: workspace)

        // Simulate a crash by forcing the undo op back to `applying`.
        let ops = try fixture.store.journalInterruptedOperations()
        if !ops.isEmpty {
            for op in ops {
                try fixture.store.journalTransitionState(operationID: op.id, to: .applying)
            }
        }
        let engine2 = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        try await engine2.reconcileInterruptedOperations()
        #expect(try fixture.store.journalInterruptedOperations().isEmpty)
    }

    @Test("A missing apply receipt is retired as conflicted instead of retried")
    func missingReceiptIsNotRetried() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.missing-receipt"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let apply = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let appliedRecord = try #require(
            try fixture.store.journalLoadRecords(operationID: apply.operationID).first
        )
        try fixture.store.journalSaveRecord(
            JournaledRecord(
                operationID: appliedRecord.operationID,
                targetInstanceID: appliedRecord.targetInstanceID,
                ordinal: appliedRecord.ordinal,
                adapterID: appliedRecord.adapterID,
                adapterVersion: appliedRecord.adapterVersion,
                capabilityID: appliedRecord.capabilityID,
                phase: appliedRecord.phase,
                intendedChangeDigest: appliedRecord.intendedChangeDigest,
                staleStateToken: appliedRecord.staleStateToken,
                planDigest: appliedRecord.planDigest,
                receiptJSON: nil,
                detail: appliedRecord.detail
            )
        )

        let undo = try await engine.undoLast(workspace: workspace)

        #expect(undo.outcomes.count == 1)
        #expect(undo.outcomes[0].configurationState == .conflicted)
        #expect(try fixture.store.journalLoadRecords(operationID: apply.operationID)[0].phase == .conflicted)
        await #expect(throws: DurableOperationError.self) {
            _ = try await engine.undoLast(workspace: workspace)
        }
    }

    @Test("Undo throws when there is no completed apply transaction")
    func undoWithoutLATThrows() async throws {
        let fixture = try Self.makeFixture()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [RecordingWritableAdapter()],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: [])
        await #expect(throws: DurableOperationError.self) {
            _ = try await engine.undoLast(workspace: workspace)
        }
    }
}
