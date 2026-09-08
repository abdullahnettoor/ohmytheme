import Foundation
import Persistence
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Partial Setup Results & Failures (Issue #33)")
struct PartialSetupTransactionTests {
    private static func makeFixture() throws -> (directory: URL, store: PersistenceStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-partialsetup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        return (directory, store)
    }

    final class ProgressCollector: @unchecked Sendable {
        private var _updates: [SetupProgress] = []
        private let lock = NSLock()

        var updates: [SetupProgress] {
            lock.lock()
            defer { lock.unlock() }
            return _updates
        }

        func add(_ p: SetupProgress) {
            lock.lock()
            _updates.append(p)
            lock.unlock()
        }
    }

    // AC 1: Permission denial marks only the affected target Needs Permission and preserves its Target Opt-in.
    @Test("Permission denial marks only the affected target Needs Permission and preserves its Target Opt-in")
    func permissionDenialMarksTargetNeedsPermissionAndPreservesOptIn() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let target1ID = TargetInstanceID(rawValue: "macos.appearance")
        let target2ID = TargetInstanceID(rawValue: "starship.default")

        let instance1 = ConnectedTargetInstance(
            id: target1ID, displayName: "System Appearance", adapterID: "macos.appearance")
        let instance2 = ConnectedTargetInstance(id: target2ID, displayName: "Starship", adapterID: "starship")

        let adapter1 = RecordingWritableAdapter(id: "macos.appearance")
        await adapter1.setBeforeConnectHook { plan in
            if plan.targetInstanceID == target1ID {
                throw RecordingConnectionPermissionDeniedError()
            }
        }
        let adapter2 = RecordingWritableAdapter(id: "starship")

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1, adapter2],
            persistence: fixture.store
        )

        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [target1ID, target2ID],
            themeAssignment: nil
        )
        try fixture.store.saveWorkspace(workspace)

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [instance1, instance2]
        )

        let collector = ProgressCollector()
        let report = try await engine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: [instance1, instance2],
            onProgress: { collector.add($0) }
        )

        // 1. Report outcomes
        #expect(report.outcomes.count == 2)
        #expect(report.kind(for: target1ID) == .needsPermission)
        #expect(report.kind(for: target2ID) == .connected)

        let outcome1 = try #require(report.outcomes.first(where: { $0.targetInstanceID == target1ID }))
        #expect(outcome1.configurationState == .permissionRequired)
        #expect(outcome1.rollbackState == .notNeeded)
        #expect(!outcome1.userActions.isEmpty)

        let outcome2 = try #require(report.outcomes.first(where: { $0.targetInstanceID == target2ID }))
        #expect(outcome2.configurationState == .updated)

        // 2. Opt-in preserved, only target2 connected
        let persistedWorkspace = try fixture.store.loadWorkspace().workspace
        #expect(persistedWorkspace.isOptedIn(target1ID))
        #expect(!persistedWorkspace.isConnected(target1ID))
        #expect(
            try fixture.store.journalLoadConnectionBaseline(targetInstanceID: target1ID) == nil
        )
        #expect(persistedWorkspace.isOptedIn(target2ID))
        #expect(persistedWorkspace.isConnected(target2ID))

        // 3. Progress reported steps
        let lastProgress = try #require(collector.updates.last)
        let step1 = try #require(lastProgress.steps.first(where: { $0.targetInstanceID == target1ID }))
        let step2 = try #require(lastProgress.steps.first(where: { $0.targetInstanceID == target2ID }))
        if case .needsPermission = step1.status {
            // expected
        } else {
            Issue.record("Expected step1 to be .needsPermission, got \(step1.status)")
        }
        if case .connected = step2.status {
            // expected
        } else {
            Issue.record("Expected step2 to be .connected, got \(step2.status)")
        }
    }

    // AC 2: A target-specific conflict, unavailability, or failure does not stop unrelated selected targets.
    @Test("Target-specific conflict, unavailability, or failure does not stop unrelated targets")
    func targetSpecificErrorsDoNotStopUnrelatedTargets() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let conflictID = TargetInstanceID(rawValue: "conflict-target")
        let failureID = TargetInstanceID(rawValue: "failure-target")
        let unavailableID = TargetInstanceID(rawValue: "unavailable-target")
        let successID = TargetInstanceID(rawValue: "success-target")

        let instanceConflict = ConnectedTargetInstance(
            id: conflictID, displayName: "Conflict Target", adapterID: "conflict-adapter")
        let instanceFailure = ConnectedTargetInstance(
            id: failureID, displayName: "Failure Target", adapterID: "failure-adapter")
        let instanceUnavailable = ConnectedTargetInstance(
            id: unavailableID, displayName: "Unavailable Target", adapterID: "unavailable-adapter")
        let instanceSuccess = ConnectedTargetInstance(
            id: successID, displayName: "Success Target", adapterID: "success-adapter")

        let adapterConflict = RecordingWritableAdapter(id: "conflict-adapter")
        await adapterConflict.setBeforeConnectHook { _ in
            throw RecordingConnectionConflictError()
        }

        let adapterFailure = RecordingWritableAdapter(id: "failure-adapter")
        await adapterFailure.setBeforeConnectHook { _ in
            throw RecordingConnectionFailedError()
        }

        let adapterUnavailable = RecordingWritableAdapter(id: "unavailable-adapter")
        await adapterUnavailable.setBeforeConnectionPreparationHook { _ in
            throw RecordingConnectionUnavailableError()
        }

        let adapterSuccess = RecordingWritableAdapter(id: "success-adapter")

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapterConflict, adapterFailure, adapterUnavailable, adapterSuccess],
            persistence: fixture.store
        )

        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [conflictID, failureID, unavailableID, successID],
            themeAssignment: nil
        )
        try fixture.store.saveWorkspace(workspace)

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [instanceConflict, instanceFailure, instanceUnavailable, instanceSuccess]
        )

        let collector = ProgressCollector()
        let report = try await engine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: [instanceConflict, instanceFailure, instanceUnavailable, instanceSuccess],
            onProgress: { collector.add($0) }
        )

        #expect(report.kind(for: conflictID) == .conflict)
        #expect(report.kind(for: failureID) == .failed)
        #expect(report.kind(for: unavailableID) == .unavailable)
        #expect(report.kind(for: successID) == .connected)

        let persistedWorkspace = try fixture.store.loadWorkspace().workspace
        #expect(!persistedWorkspace.isConnected(conflictID))
        #expect(!persistedWorkspace.isConnected(failureID))
        #expect(!persistedWorkspace.isConnected(unavailableID))
        #expect(persistedWorkspace.isConnected(successID))

        let lastProgress = try #require(collector.updates.last)
        #expect(
            lastProgress.steps.first(where: { $0.targetInstanceID == conflictID })?.status
                == .conflict(detail: "Target configuration was externally modified before connection started.")
        )
        #expect(
            lastProgress.steps.first(where: { $0.targetInstanceID == failureID })?.status
                == .failed(detail: "Connection failed unexpectedly before mutation started.")
        )
        #expect(
            lastProgress.steps.first(where: { $0.targetInstanceID == unavailableID })?.status
                == .unavailable(detail: "Target instance cannot be reached.")
        )
        #expect(
            lastProgress.steps.first(where: { $0.targetInstanceID == successID })?.status
                == .connected(reach: .currentInstances)
        )
    }

    @Test("An adapter becoming unavailable after review discards its new Connection Baseline")
    func unavailableAdapterAfterReviewDiscardsNewBaseline() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let targetID = TargetInstanceID(rawValue: "adapter-lost-after-review")
        let instance = ConnectedTargetInstance(
            id: targetID,
            displayName: "Lost Adapter",
            adapterID: "lost-adapter"
        )
        let planningAdapter = RecordingWritableAdapter(id: "lost-adapter")
        let planningEngine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [planningAdapter],
            persistence: fixture.store
        )
        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [targetID],
            themeAssignment: nil
        )
        try fixture.store.saveWorkspace(workspace)

        let plan = try await planningEngine.prepareSetup(workspace: workspace, instances: [instance])
        let existingBaseline = try fixture.store.journalSaveConnectionBaseline(
            targetInstanceID: targetID,
            adapterID: "lost-adapter",
            adapterVersion: "1",
            baseline: plan.targetPlans[0].capturedPreChangeState
        )
        let executionEngine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [],
            persistence: fixture.store
        )
        let report = try await executionEngine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: [instance]
        )

        #expect(report.kind(for: targetID) == .unavailable)
        let storedBaseline = try fixture.store.journalLoadConnectionBaseline(
            targetInstanceID: targetID
        )
        let retainedBaseline = try #require(storedBaseline)
        #expect(retainedBaseline.baselineReference == existingBaseline.baselineReference)
        #expect(!((try fixture.store.loadWorkspace()).workspace.isConnected(targetID)))
    }

    // AC 3: Successful targets remain connected with durable Connection Baselines after partial setup.
    @Test("Successful targets remain connected with durable Connection Baselines after partial setup")
    func successfulTargetsRemainConnectedWithDurableBaselines() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let target1ID = TargetInstanceID(rawValue: "failing-target")
        let target2ID = TargetInstanceID(rawValue: "successful-target")

        let instance1 = ConnectedTargetInstance(id: target1ID, displayName: "Failing Target", adapterID: "adapter1")
        let instance2 = ConnectedTargetInstance(id: target2ID, displayName: "Successful Target", adapterID: "adapter2")

        let adapter1 = RecordingWritableAdapter(id: "adapter1")
        await adapter1.setBeforeConnectHook { _ in
            throw RecordingConnectionFailedError()
        }
        let adapter2 = RecordingWritableAdapter(id: "adapter2")

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1, adapter2],
            persistence: fixture.store
        )

        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [target1ID, target2ID],
            themeAssignment: nil
        )
        try fixture.store.saveWorkspace(workspace)

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [instance1, instance2]
        )

        let report = try await engine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: [instance1, instance2]
        )

        #expect(report.kind(for: target1ID) == .failed)
        #expect(report.kind(for: target2ID) == .connected)

        // Baseline verification: target2 must have durable baseline in store
        let storedBaseline2 = try fixture.store.journalLoadConnectionBaseline(targetInstanceID: target2ID)
        #expect(storedBaseline2 != nil)
        let baselineData = try storedBaseline2.map { try fixture.store.loadContent($0.baselineReference) }
        #expect(baselineData != nil)

        // Target1 has no baseline
        let storedBaseline1 = try fixture.store.journalLoadConnectionBaseline(targetInstanceID: target1ID)
        #expect(storedBaseline1 == nil)

        // Target2 is recorded as connected in persistence store
        #expect(try fixture.store.loadWorkspace().workspace.isConnected(target2ID))
        #expect(!(try fixture.store.loadWorkspace().workspace.isConnected(target1ID)))

        // Fresh engine with same store sees target2 connected
        let freshEngine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1, adapter2],
            persistence: fixture.store
        )
        let freshWorkspace = try fixture.store.loadWorkspace().workspace
        #expect(freshWorkspace.isConnected(target2ID))
        _ = freshEngine
    }

    // AC 4: Global persistence failure, corrupt aggregate plan state, or changed selected-target membership stops setup before mutation.
    @Test("Pre-mutation validations stop setup before any adapter mutation")
    func preMutationValidationsStopSetup() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let target1ID = TargetInstanceID(rawValue: "target-1")
        let target2ID = TargetInstanceID(rawValue: "target-2")
        let instance1 = ConnectedTargetInstance(id: target1ID, displayName: "Target 1", adapterID: "adapter1")
        let instance2 = ConnectedTargetInstance(id: target2ID, displayName: "Target 2", adapterID: "adapter2")

        actor MutationWatchdog {
            var mutated = false
            func recordMutation() { mutated = true }
        }
        let watchdog = MutationWatchdog()

        let adapter1 = RecordingWritableAdapter(id: "adapter1")
        await adapter1.setBeforeConnectHook { _ in
            await watchdog.recordMutation()
        }
        let adapter2 = RecordingWritableAdapter(id: "adapter2")
        await adapter2.setBeforeConnectHook { _ in
            await watchdog.recordMutation()
        }

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1, adapter2],
            persistence: fixture.store
        )

        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [target1ID, target2ID],
            themeAssignment: nil
        )
        try fixture.store.saveWorkspace(workspace)

        let validPlan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [instance1, instance2]
        )

        // 1. Missing persistence store
        let engineWithoutPersistence = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1, adapter2],
            persistence: nil
        )
        await #expect(throws: DurableOperationError.persistenceRequired) {
            try await engineWithoutPersistence.executeSetup(
                plan: validPlan,
                workspace: workspace,
                instances: [instance1, instance2]
            )
        }
        #expect(await !watchdog.mutated)

        // 2. Changed selected-target membership (e.g. user removed target2 from opt-ins)
        let modifiedWorkspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: [],
            targetOptIns: [target1ID],  // target2 removed!
            themeAssignment: nil
        )
        await #expect(throws: ThemeEngineError.planMembershipChanged(validPlan.id)) {
            try await engine.executeSetup(
                plan: validPlan,
                workspace: modifiedWorkspace,
                instances: [instance1, instance2]
            )
        }
        #expect(await !watchdog.mutated)

        // 3. Corrupt aggregate plan state: empty targetInstanceIDs
        let emptyPlan = SetupPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [],
            targetPlans: [],
            discoveryAndSelectionDigest: "digest"
        )
        await #expect(
            throws: ThemeEngineError.corruptPlanState(emptyPlan.id, reason: "Setup plan has no target instances.")
        ) {
            try await engine.executeSetup(
                plan: emptyPlan,
                workspace: workspace,
                instances: [instance1, instance2]
            )
        }
        #expect(await !watchdog.mutated)

        // 4. Corrupt aggregate plan state: duplicate targetInstanceIDs
        let duplicatePlan = SetupPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [target1ID, target1ID],
            targetPlans: validPlan.targetPlans,
            discoveryAndSelectionDigest: "digest"
        )
        await #expect(
            throws: ThemeEngineError.corruptPlanState(
                duplicatePlan.id, reason: "Setup plan contains duplicate target instance IDs.")
        ) {
            try await engine.executeSetup(
                plan: duplicatePlan,
                workspace: workspace,
                instances: [instance1, instance2]
            )
        }
        #expect(await !watchdog.mutated)

        // 5. Corrupt aggregate plan state: targets in targetInstanceIDs don't match targetPlans
        let mismatchedPlan = SetupPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [target1ID, target2ID],
            // Only has target1; target2 is missing from both plans and failures.
            targetPlans: [validPlan.targetPlans[0]],
            discoveryAndSelectionDigest: "digest"
        )
        await #expect(
            throws: ThemeEngineError.corruptPlanState(
                mismatchedPlan.id, reason: "Setup plan target instance IDs do not match target plans and failures.")
        ) {
            try await engine.executeSetup(
                plan: mismatchedPlan,
                workspace: workspace,
                instances: [instance1, instance2]
            )
        }
        #expect(await !watchdog.mutated)
    }

    // AC 5: The Setup Report distinguishes connected, unchanged, needs permission, conflict, failed, unavailable, and recovery-required outcomes.
    @Test("Setup Report distinguishes all seven outcome kinds")
    func setupReportDistinguishesAllSevenOutcomes() {
        let opID = UUID()
        let t1 = TargetInstanceID(rawValue: "target-connected")
        let t2 = TargetInstanceID(rawValue: "target-unchanged")
        let t3 = TargetInstanceID(rawValue: "target-permission")
        let t4 = TargetInstanceID(rawValue: "target-conflict")
        let t5 = TargetInstanceID(rawValue: "target-failed")
        let t6 = TargetInstanceID(rawValue: "target-unavailable")
        let t7 = TargetInstanceID(rawValue: "target-recovery")

        let outcomes = [
            TargetCapabilityOutcome(
                targetInstanceID: t1,
                adapterID: "a1",
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .updated,
                runningInstanceReach: .currentInstances,
                detail: "Connected"
            ),
            TargetCapabilityOutcome(
                targetInstanceID: t2,
                adapterID: "a2",
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .unchanged,
                runningInstanceReach: .currentInstances,
                detail: "Already configured"
            ),
            TargetCapabilityOutcome(
                targetInstanceID: t3,
                adapterID: "a3",
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .permissionRequired,
                runningInstanceReach: .unavailable,
                detail: "Permission denied"
            ),
            TargetCapabilityOutcome(
                targetInstanceID: t4,
                adapterID: "a4",
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .conflicted,
                runningInstanceReach: .unavailable,
                detail: "External modification conflict"
            ),
            TargetCapabilityOutcome(
                targetInstanceID: t5,
                adapterID: "a5",
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .failed,
                runningInstanceReach: .unavailable,
                detail: "Adapter error"
            ),
            TargetCapabilityOutcome(
                targetInstanceID: t6,
                adapterID: "a6",
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .unavailable,
                runningInstanceReach: .unavailable,
                detail: "Target unavailable"
            ),
            TargetCapabilityOutcome(
                targetInstanceID: t7,
                adapterID: "a7",
                capabilityID: "connection",
                sourceType: .unavailable,
                sourceRevision: "1",
                configurationState: .failed,
                runningInstanceReach: .unavailable,
                detail: "Mutation interrupted",
                rollbackState: .recoveryRequired
            ),
        ]

        let report = SetupReport(
            operationID: opID,
            outcomes: outcomes
        )

        // Verify individual outcome kinds
        #expect(report.kind(for: t1) == .connected)
        #expect(report.kind(for: t2) == .unchanged)
        #expect(report.kind(for: t3) == .needsPermission)
        #expect(report.kind(for: t4) == .conflict)
        #expect(report.kind(for: t5) == .failed)
        #expect(report.kind(for: t6) == .unavailable)
        #expect(report.kind(for: t7) == .recoveryRequired)

        // Verify categorized arrays
        #expect(report.connectedOutcomes.count == 1)
        #expect(report.connectedOutcomes.first?.targetInstanceID == t1)

        #expect(report.unchangedOutcomes.count == 1)
        #expect(report.unchangedOutcomes.first?.targetInstanceID == t2)

        #expect(report.needsPermissionOutcomes.count == 1)
        #expect(report.needsPermissionOutcomes.first?.targetInstanceID == t3)

        #expect(report.conflictOutcomes.count == 1)
        #expect(report.conflictOutcomes.first?.targetInstanceID == t4)

        #expect(report.failedOutcomes.count == 1)
        #expect(report.failedOutcomes.first?.targetInstanceID == t5)

        #expect(report.unavailableOutcomes.count == 1)
        #expect(report.unavailableOutcomes.first?.targetInstanceID == t6)

        #expect(report.recoveryRequiredOutcomes.count == 1)
        #expect(report.recoveryRequiredOutcomes.first?.targetInstanceID == t7)
    }
}
