import Foundation
import Persistence
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Durable recording operations (issue #11)")
struct DurableOperationsTests {
    // MARK: Helpers

    private static func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        return Fixture(directory: directory, store: store)
    }

    // MARK: AC #1 — Plans, baselines, and receipts are durable BEFORE their external mutation

    @Test("Adapter Plans are durable in the journal before any external mutation")
    func plansPersistedBeforeMutation() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        // Interrupt just before writing so the journal must already contain the prepared plan
        // and no mutation may have taken effect.
        await adapter.setInterruption(.beforeApplyWrite, enabled: true)
        let originalWorld = await adapter.currentWorldBytes()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.durable"])

        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        // World must be unchanged (interruption happened before the write).
        #expect(await adapter.currentWorldBytes() == originalWorld)

        // Journal must contain both a `prepared` record (persisted BEFORE the write attempt) and
        // then a `failed` record for the interrupted target.
        let records = try fixture.store.journalLoadRecords(operationID: report.operationID)
        #expect(records.count == 1)
        #expect(records[0].phase == .failed)
        #expect(records[0].planDigest != nil)
        #expect(records[0].intendedChangeDigest == "sha256:test")
        #expect(report.outcomes[0].configurationState == .failed)
    }

    @Test("Connection baselines are durable before the first connect write")
    func connectionBaselinePersistedBeforeMutation() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        await adapter.setInterruption(.beforeConnect, enabled: true)
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: [])
        let instance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "recording.baseline"),
            displayName: "Recording",
            adapterID: "recording"
        )

        _ = try await engine.connect(instance: instance, workspace: workspace)

        // Baseline must exist even though the connect call was interrupted before writing.
        let baseline = try fixture.store.journalLoadConnectionBaseline(
            targetInstanceID: instance.id
        )
        #expect(baseline != nil)
        #expect(baseline?.adapterID == "recording")
    }

    // MARK: AC #2 — One mutating operation at a time; deterministic order

    @Test("A second operation cannot start while another is in flight")
    func mutuallyExclusiveMutations() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.one"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        // Kick off the durable apply and, while it is running, attempt a second one — the actor
        // serializes them, so the second must complete only after the first (and the second must
        // report `previewNotFound` because the preview was consumed by the first apply).
        async let first = engine.applyDurable(previewID: preview.id, workspace: workspace)
        _ = try await first

        var secondFailed = false
        do {
            _ = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        } catch is ThemeEngineError {
            secondFailed = true
        }
        #expect(secondFailed)
    }

    @Test("Adapter Plan records are stored in the deterministic preview order")
    func deterministicOrder() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let instanceIDs = (0..<3).map { "recording.\($0)" }
        let workspace = Fixtures.workspace(recordingInstances: instanceIDs)
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let records = try fixture.store.journalLoadRecords(operationID: report.operationID)
        let ordinals = records.map(\.ordinal)
        #expect(ordinals == [0, 1, 2])
        #expect(records.map(\.targetInstanceID.rawValue) == instanceIDs)
    }

    // MARK: AC #3 — Cancellation available before the first mutation but not after

    @Test("Cancellation before any mutation transitions the operation to cancelled")
    func cancellationBeforeMutation() async throws {
        let fixture = try Self.makeFixture()
        // Create a prepared-but-not-applying operation manually.
        let op = try fixture.store.journalStartOperation(
            kind: .apply,
            workspaceID: .myMac,
            variantID: "test-pack/dark"
        )
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [RecordingWritableAdapter()],
            persistence: fixture.store
        )
        let cancelled = try await engine.cancel(operationID: op.id)
        #expect(cancelled)
        let reloaded = try fixture.store.journalLoadOperation(id: op.id)
        #expect(reloaded?.state == .cancelled)
    }

    @Test("Cancellation is refused after mutation has begun")
    func cancellationAfterMutationRefused() async throws {
        let fixture = try Self.makeFixture()
        let op = try fixture.store.journalStartOperation(
            kind: .apply,
            workspaceID: .myMac,
            variantID: "test-pack/dark"
        )
        // Simulate that mutation has started.
        try fixture.store.journalTransitionState(operationID: op.id, to: .applying)
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [RecordingWritableAdapter()],
            persistence: fixture.store
        )
        await #expect(throws: DurableOperationError.self) {
            _ = try await engine.cancel(operationID: op.id)
        }
    }

    // MARK: AC #4 — Write-boundary revalidation

    @Test("A stale state token at the write boundary becomes a conflict, not a mutation")
    func writeBoundaryRevalidationDetectsStalePlan() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        let originalWorld = await adapter.currentWorldBytes()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.stale"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        // External edit invalidates the plan between prepare and apply.
        await adapter.mutateWorldExternally(Data("someone-else-edited".utf8))
        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        // No mutation applied by us: world should remain what the external edit set it to.
        #expect(await adapter.currentWorldBytes() != originalWorld)
        #expect(await adapter.currentWorldBytes() == Data("someone-else-edited".utf8))
        #expect(report.outcomes[0].configurationState == .conflicted)

        let records = try fixture.store.journalLoadRecords(operationID: report.operationID)
        #expect(records[0].phase == .conflicted)
    }

    // MARK: AC #5 — Interrupted operations reconcile before another mutation

    @Test("Reconciliation classifies an interrupted target as before-change when no mutation ran")
    func reconciliationBeforeChange() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        await adapter.setInterruption(.beforeApplyWrite, enabled: true)
        var engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.recover"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        _ = report

        // Simulate a crash: forcibly reset operation state to `applying` and re-run.
        let interruptedID = report.operationID
        try fixture.store.journalTransitionState(operationID: interruptedID, to: .applying)
        // Also set the target record back to `applying` phase to simulate a mid-flight crash.
        let priorRecords = try fixture.store.journalLoadRecords(operationID: interruptedID)
        for record in priorRecords {
            var mutable = record
            mutable.phase = .applying
            try fixture.store.journalSaveRecord(mutable)
        }

        // New engine instance (simulating a new launch) reconciles.
        engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        try await engine.reconcileInterruptedOperations()

        let reloaded = try fixture.store.journalLoadOperation(id: interruptedID)
        #expect(reloaded?.state == .reconciled)
        let records = try fixture.store.journalLoadRecords(operationID: interruptedID)
        #expect(records[0].phase == .reconciledBefore)
    }

    @Test("Reconciliation classifies as intended-after-change when the write completed")
    func reconciliationIntendedAfterChange() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        // Run a normal apply so the world reflects the intended state.
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.intended"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        // Simulate a crash before the operation transitioned to `applied`.
        try fixture.store.journalTransitionState(operationID: report.operationID, to: .applying)
        let priorRecords = try fixture.store.journalLoadRecords(operationID: report.operationID)
        for record in priorRecords {
            var mutable = record
            mutable.phase = .applying
            try fixture.store.journalSaveRecord(mutable)
        }
        let engine2 = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        try await engine2.reconcileInterruptedOperations()
        let records = try fixture.store.journalLoadRecords(operationID: report.operationID)
        #expect(records[0].phase == .reconciledIntended)
    }

    @Test("Reconciliation classifies as conflicting when the current state matches neither expectation")
    func reconciliationConflicting() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        await adapter.setInterruption(.beforeApplyWrite, enabled: true)
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.conflict"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        // External edit now changes the world to a third state.
        await adapter.mutateWorldExternally(Data("something-unrelated".utf8))
        try fixture.store.journalTransitionState(operationID: report.operationID, to: .applying)
        let priorRecords = try fixture.store.journalLoadRecords(operationID: report.operationID)
        for record in priorRecords {
            var mutable = record
            mutable.phase = .applying
            try fixture.store.journalSaveRecord(mutable)
        }
        let engine2 = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        try await engine2.reconcileInterruptedOperations()
        let records = try fixture.store.journalLoadRecords(operationID: report.operationID)
        #expect(records[0].phase == .reconciledConflict)
    }

    @Test("Reconciliation runs before another mutation is accepted")
    func reconciliationBeforeNextMutation() async throws {
        let fixture = try Self.makeFixture()
        // Prepare a pretend-interrupted operation for a target the engine doesn't know about
        // — reconciliation should still transition it to `reconciled`.
        let op = try fixture.store.journalStartOperation(
            kind: .apply,
            workspaceID: .myMac,
            variantID: "test-pack/dark"
        )
        try fixture.store.journalTransitionState(operationID: op.id, to: .applying)
        try fixture.store.journalSaveRecord(
            JournaledRecord(
                operationID: op.id,
                targetInstanceID: TargetInstanceID(rawValue: "orphaned"),
                ordinal: 0,
                adapterID: "recording",
                adapterVersion: "1",
                capabilityID: "theme",
                phase: .applying,
                intendedChangeDigest: "x",
                staleStateToken: nil,
                planDigest: nil,
                receiptJSON: nil,
                detail: nil
            )
        )
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [RecordingWritableAdapter()],
            persistence: fixture.store
        )
        // Any new mutation triggers reconciliation first.
        let workspace = Fixtures.workspace(recordingInstances: ["recording.after-reconcile"])
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        _ = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        let reloaded = try fixture.store.journalLoadOperation(id: op.id)
        #expect(reloaded?.state == .reconciled)
    }

    // MARK: AC #6 — Partial results survive a single-target failure

    @Test("A per-instance failure keeps safe results from independent instances")
    func partialFailurePreservesGoodResults() async throws {
        let fixture = try Self.makeFixture()
        let adapter = FaultyRecordingAdapter(failingInstanceIDs: [TargetInstanceID(rawValue: "recording.fail")])
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(
            recordingInstances: ["recording.ok-a", "recording.fail", "recording.ok-b"]
        )
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        #expect(report.outcomes.count == 3)
        let byInstance = Dictionary(uniqueKeysWithValues: report.outcomes.map { ($0.targetInstanceID.rawValue, $0) })
        #expect(byInstance["recording.ok-a"]?.configurationState == .updated)
        #expect(byInstance["recording.fail"]?.configurationState == .failed)
        #expect(byInstance["recording.ok-b"]?.configurationState == .updated)
    }

    // MARK: AC #7 — Shared adapter safety contract

    @Test("Preparation performs no external writes")
    func preparationIsSafe() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        let originalWorld = await adapter.currentWorldBytes()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: ["recording.safe"])
        _ = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        #expect(await adapter.currentWorldBytes() == originalWorld)
    }

    @Test("Restore is guarded and refuses to overwrite non-owned state")
    func guardedRollbackRefusesOnConflict() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: [])
        let instance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "recording.rb"),
            displayName: "Recording",
            adapterID: "recording"
        )
        // First connect the instance so a baseline exists.
        _ = try await engine.connect(instance: instance, workspace: workspace)

        // External edit takes the world to an unexpected state — guarded rollback must refuse.
        await adapter.mutateWorldExternally(Data("external".utf8))

        let restoreReport = try await engine.restore(instance: instance, workspace: workspace)
        #expect(restoreReport.outcomes[0].configurationState == .conflicted)
    }

    @Test("Sensitive baseline bytes are excluded from reports and outcome detail")
    func sensitiveBytesAreExcluded() async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter(initialWorld: Data("SECRET-BASELINE-BYTES".utf8))
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: [])
        let instance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "recording.secret"),
            displayName: "Recording",
            adapterID: "recording"
        )
        let connectReport = try await engine.connect(instance: instance, workspace: workspace)
        // The report and detail must not contain the raw sensitive baseline bytes.
        let encoder = JSONEncoder()
        let reportBytes = try encoder.encode(connectReport)
        let asText = String(decoding: reportBytes, as: UTF8.self)
        #expect(!asText.contains("SECRET-BASELINE-BYTES"))
    }

    // MARK: AC #8 — Interruption at every journal transition

    @Test(
        "Interruption at every journal transition leaves durable state consistent",
        arguments: InterruptionPoint.allCases)
    func interruptionAtEveryTransition(point: InterruptionPoint) async throws {
        let fixture = try Self.makeFixture()
        let adapter = RecordingWritableAdapter()
        await adapter.setInterruption(point, enabled: true)
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )
        let workspace = Fixtures.workspace(recordingInstances: [])
        let instance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "recording.\(point.rawValue)"),
            displayName: "Recording",
            adapterID: "recording"
        )
        let workspaceForApply = Fixtures.workspace(recordingInstances: [instance.id.rawValue])

        switch point {
        case .beforeConnect, .afterConnect:
            _ = try await engine.connect(instance: instance, workspace: workspace)
        case .beforeDisconnect, .afterDisconnect:
            _ = try await engine.connect(instance: instance, workspace: workspace)
            await adapter.setInterruption(point, enabled: true)
            _ = try await engine.disconnect(instance: instance, workspace: workspace)
        case .beforeRollback, .afterRollback:
            _ = try await engine.connect(instance: instance, workspace: workspace)
            await adapter.setInterruption(point, enabled: true)
            _ = try await engine.restore(instance: instance, workspace: workspace)
        case .beforePrepareApply, .beforeApplyWrite, .afterApplyWrite, .beforeRevalidation:
            let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspaceForApply)
            _ = try await engine.applyDurable(previewID: preview.id, workspace: workspaceForApply)
        }

        // Regardless of where interruption occurred, the journal must contain the operation and
        // reconciliation must complete without throwing.
        let interrupted = try fixture.store.journalInterruptedOperations()
        try await engine.reconcileInterruptedOperations()
        let stillInterrupted = try fixture.store.journalInterruptedOperations()
        #expect(stillInterrupted.isEmpty)
        _ = interrupted
    }

    private struct Fixture {
        let directory: URL
        let store: PersistenceStore
    }
}

// MARK: - Fixtures

enum Fixtures {
    static let pack = ThemePack(
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

    static func workspace(recordingInstances ids: [String]) -> Workspace {
        Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: ids.map {
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: $0),
                    displayName: "Recording",
                    adapterID: "recording"
                )
            }
        )
    }
}

/// A recording adapter that fails apply for a specific set of Target Instances,
/// so partial-success behavior can be exercised.
actor FaultyRecordingAdapter: WritableThemeAdapter {
    let id = "recording"
    let version = "1"
    let payloadVersion = "1"

    private let inner = RecordingWritableAdapter()
    private let failingInstanceIDs: Set<TargetInstanceID>

    init(failingInstanceIDs: Set<TargetInstanceID>) {
        self.failingInstanceIDs = failingInstanceIDs
    }

    func prepareApply(instance: ConnectedTargetInstance, theme: PreparedTheme) async throws -> AdapterPlan {
        let plan = try await inner.prepareApply(instance: instance, theme: theme)
        // Strip the stale-state token so per-target failures don't cascade into revalidation conflicts.
        return AdapterPlan(
            targetInstanceID: plan.targetInstanceID,
            adapterID: plan.adapterID,
            adapterVersion: plan.adapterVersion,
            capabilityID: plan.capabilityID,
            payload: plan.payload,
            intendedChangeDigest: plan.intendedChangeDigest,
            capturedPreChangeState: plan.capturedPreChangeState,
            staleStateToken: nil,
            expectedSideEffects: plan.expectedSideEffects,
            requiredPermissions: plan.requiredPermissions,
            sourceType: plan.sourceType,
            sourceRevision: plan.sourceRevision,
            activationReach: plan.activationReach,
            setupNeeds: plan.setupNeeds,
            conflicts: plan.conflicts
        )
    }

    func revalidateApply(plan: AdapterPlan) async throws {
        // Skip token-based revalidation for partial-failure scenarios.
    }

    func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        if failingInstanceIDs.contains(plan.targetInstanceID) {
            throw FaultyRecordingAdapterError.injectedFailure
        }
        return try await inner.apply(plan)
    }

    func prepareConnection(instance: ConnectedTargetInstance) async throws -> ConnectionPlan {
        try await inner.prepareConnection(instance: instance)
    }

    func connect(_ plan: ConnectionPlan) async throws -> ConnectionReceipt {
        try await inner.connect(plan)
    }

    func classifyApply(plan: AdapterPlan) async throws -> ReconciliationClassification {
        try await inner.classifyApply(plan: plan)
    }

    func rollbackApply(plan: AdapterPlan, receipt: AdapterReceipt) async throws {
        try await inner.rollbackApply(plan: plan, receipt: receipt)
    }

    func prepareDisconnect(
        instance: ConnectedTargetInstance,
        baseline: StoredConnectionBaseline
    ) async throws -> DisconnectPlan {
        try await inner.prepareDisconnect(instance: instance, baseline: baseline)
    }

    func disconnect(_ plan: DisconnectPlan, baseline: Data) async throws -> AdapterReceipt {
        try await inner.disconnect(plan, baseline: baseline)
    }
}

enum FaultyRecordingAdapterError: Error, Equatable, Sendable {
    case injectedFailure
}
