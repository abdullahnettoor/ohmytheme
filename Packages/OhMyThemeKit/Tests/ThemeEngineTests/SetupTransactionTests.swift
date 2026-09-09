import Foundation
import Persistence
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Setup Transaction (Issue #32)")
struct SetupTransactionTests {
    private static func makeFixture() throws -> (directory: URL, store: PersistenceStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-setuptransaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        return (directory, store)
    }

    actor OrderTracker {
        var order: [TargetInstanceID] = []
        func record(_ id: TargetInstanceID) {
            order.append(id)
        }
    }

    actor SetupGate {
        private var hasArrived = false
        private var isOpen = false

        func wait() async {
            hasArrived = true
            while !isOpen {
                await Task.yield()
            }
        }

        func arrived() -> Bool { hasArrived }
        func open() { isOpen = true }
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

    // AC 1: The engine persists the Setup Transaction and all selected Connection Plans before the first external mutation.
    @Test("Persists Setup Transaction and all selected Connection Plans before first external mutation")
    func persistsTransactionAndPlansBeforeFirstExternalMutation() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "macos.appearance")
        let secondID = TargetInstanceID(rawValue: "starship.default")

        let appearanceInstance = ConnectedTargetInstance(
            id: firstID, displayName: "System Appearance", adapterID: "macos.appearance")
        let starshipInstance = ConnectedTargetInstance(id: secondID, displayName: "Starship", adapterID: "starship")

        let adapter1 = RecordingWritableAdapter(id: "macos.appearance")
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
            targetOptIns: [firstID, secondID],
            themeAssignment: nil
        )

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [appearanceInstance, starshipInstance]
        )

        actor HookState {
            var checked = false
            var foundOperationID: UUID?
            func markChecked(opID: UUID) {
                checked = true
                foundOperationID = opID
            }
        }
        let hookState = HookState()

        await adapter1.setBeforeConnectHook { _ in
            // When the first adapter is called, verify:
            // 1. The setup transaction record exists in the operations journal in prepared/applying phase.
            let inFlightOps = try fixture.store.journalInterruptedOperations()
            let setupOp = inFlightOps.first(where: { $0.kind == .setup })
            #expect(setupOp != nil)
            #expect(setupOp?.state == .prepared || setupOp?.state == .applying)

            // 2. Both targets have their connection baselines already persisted before this mutation!
            let baseline1 = try fixture.store.journalLoadConnectionBaseline(targetInstanceID: firstID)
            let baseline2 = try fixture.store.journalLoadConnectionBaseline(targetInstanceID: secondID)
            #expect(baseline1 != nil)
            #expect(baseline2 != nil)

            if let id = setupOp?.id {
                await hookState.markChecked(opID: id)
            }
        }

        let report = try await engine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: [appearanceInstance, starshipInstance]
        )

        let checked = await hookState.checked
        let foundOpID = await hookState.foundOperationID
        #expect(checked)
        #expect(foundOpID == report.operationID)
        #expect(report.outcomes.count == 2)
    }

    // AC 2: Selected instances execute sequentially in the same stable order shown during review.
    @Test("Selected instances execute sequentially in the exact stable order shown during review")
    func sequentialExecutionInReviewedOrder() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let tracker = OrderTracker()

        let appearanceInstance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "macos.appearance"),
            displayName: "System Appearance",
            adapterID: "macos.appearance"
        )
        let wallpaperInstance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "macos.wallpaper.1"),
            displayName: "Wallpaper (Display 1)",
            adapterID: "macos.wallpaper"
        )
        let starshipInstance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "starship.default"),
            displayName: "Starship",
            adapterID: "starship"
        )

        let adapter1 = RecordingWritableAdapter(id: "macos.appearance")
        let adapter2 = RecordingWritableAdapter(id: "macos.wallpaper")
        let adapter3 = RecordingWritableAdapter(id: "starship")

        await adapter1.setBeforeConnectHook { plan in
            await tracker.record(plan.targetInstanceID)
        }
        await adapter2.setBeforeConnectHook { plan in
            await tracker.record(plan.targetInstanceID)
        }
        await adapter3.setBeforeConnectHook { plan in
            await tracker.record(plan.targetInstanceID)
        }

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1, adapter2, adapter3],
            persistence: fixture.store
        )

        // Pass instances scrambled: starship, wallpaper, appearance
        let scrambled = [starshipInstance, wallpaperInstance, appearanceInstance]
        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: Set(scrambled.map(\.id)),
            themeAssignment: nil
        )

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: scrambled
        )

        // Reviewed order is stable: appearance (0), wallpaper (1), starship (4)
        #expect(plan.targetInstanceIDs == [appearanceInstance.id, wallpaperInstance.id, starshipInstance.id])

        _ = try await engine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: scrambled
        )

        let executedOrder = await tracker.order
        #expect(executedOrder == plan.targetInstanceIDs)
    }

    // AC 3: Each instance receives its own durable Connection Baseline, outcome, and recovery record.
    @Test("Each instance receives its own durable Connection Baseline, outcome, and recovery record")
    func durableBaselinesOutcomesAndRecoveryRecords() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "macos.appearance")
        let secondID = TargetInstanceID(rawValue: "starship.default")

        let appearanceInstance = ConnectedTargetInstance(
            id: firstID, displayName: "System Appearance", adapterID: "macos.appearance")
        let starshipInstance = ConnectedTargetInstance(id: secondID, displayName: "Starship", adapterID: "starship")

        let adapter1 = RecordingWritableAdapter(id: "macos.appearance")
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
            targetOptIns: [firstID, secondID],
            themeAssignment: nil
        )

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [appearanceInstance, starshipInstance]
        )

        let report = try await engine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: [appearanceInstance, starshipInstance]
        )

        #expect(report.outcomes.count == 2)

        let loaded = try fixture.store.loadWorkspace()

        for id in [firstID, secondID] {
            // Durable baseline exists
            let baseline = try fixture.store.journalLoadConnectionBaseline(targetInstanceID: id)
            #expect(baseline != nil)

            // Distinct outcome exists
            let outcome = report.outcomes.first { $0.targetInstanceID == id }
            #expect(outcome != nil)
            #expect(outcome?.configurationState == .updated)
            #expect(outcome?.capabilityID == "connection")

            // Recovery record exists in target instances table
            let persistedTarget = loaded.targetInstances.first { $0.id == id }
            #expect(persistedTarget != nil)
            #expect(persistedTarget?.isConnected == true)
        }
    }

    // AC 4: A target is marked connected only after its successful connection receipt is durable.
    @Test("Target is marked connected only after its successful connection receipt is durable")
    func targetMarkedConnectedOnlyAfterReceiptIsDurable() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let successID = TargetInstanceID(rawValue: "macos.appearance")
        let failID = TargetInstanceID(rawValue: "starship.default")

        let appearanceInstance = ConnectedTargetInstance(
            id: successID, displayName: "System Appearance", adapterID: "macos.appearance")
        let starshipInstance = ConnectedTargetInstance(id: failID, displayName: "Starship", adapterID: "starship")

        let adapter1 = RecordingWritableAdapter(id: "macos.appearance")
        let adapter2 = RecordingWritableAdapter(id: "starship")

        struct TestAdapterError: Error, LocalizedError {
            var errorDescription: String? { "Failed to connect starship" }
        }

        await adapter2.setBeforeConnectHook { _ in
            throw TestAdapterError()
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
            targetOptIns: [successID, failID],
            themeAssignment: nil
        )

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [appearanceInstance, starshipInstance]
        )

        let report = try await engine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: [appearanceInstance, starshipInstance]
        )

        let loaded = try fixture.store.loadWorkspace()

        // The successful target is marked connected in persistence and journal
        let persistedSuccess = loaded.targetInstances.first { $0.id == successID }
        #expect(persistedSuccess?.isConnected == true)

        let successOutcome = report.outcomes.first { $0.targetInstanceID == successID }
        #expect(successOutcome?.configurationState == .updated)

        // The failed target is NOT marked connected in persistence
        let persistedFail = loaded.targetInstances.first { $0.id == failID }
        #expect(persistedFail == nil || persistedFail?.isConnected == false)

        let failOutcome = report.outcomes.first { $0.targetInstanceID == failID }
        #expect(failOutcome?.configurationState == .failed)
    }

    // AC 5: The runtime exposes one operation identity, progress model, and grouped Setup Report.
    @Test("Exposes one operation identity, progressive progress model, and grouped Setup Report")
    func oneOperationIdentityAndProgressModel() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "macos.appearance")
        let secondID = TargetInstanceID(rawValue: "starship.default")

        let appearanceInstance = ConnectedTargetInstance(
            id: firstID, displayName: "System Appearance", adapterID: "macos.appearance")
        let starshipInstance = ConnectedTargetInstance(id: secondID, displayName: "Starship", adapterID: "starship")

        let adapter1 = RecordingWritableAdapter(id: "macos.appearance")
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
            targetOptIns: [firstID, secondID],
            themeAssignment: nil
        )

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [appearanceInstance, starshipInstance]
        )

        let collector = ProgressCollector()

        let report = try await engine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: [appearanceInstance, starshipInstance],
            onProgress: { progress in
                collector.add(progress)
            }
        )

        let updates = collector.updates
        #expect(!updates.isEmpty)
        // All progress updates share the exact same operation identity matching the final report
        for update in updates {
            #expect(update.operationID == report.operationID)
            #expect(update.totalCount == 2)
        }

        // Final progress update is complete
        let last = updates.last
        #expect(last?.isComplete == true)
        #expect(last?.completedCount == 2)
    }

    // AC 6: Only one mutating Workspace operation can run, and conflicting operations are rejected.
    @Test("Only one mutating Workspace operation can run concurrently")
    func concurrentMutatingOperationIsRejected() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "macos.appearance")
        let appearanceInstance = ConnectedTargetInstance(
            id: firstID, displayName: "System Appearance", adapterID: "macos.appearance")
        let adapter1 = RecordingWritableAdapter(id: "macos.appearance")

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1],
            persistence: fixture.store
        )

        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [firstID],
            themeAssignment: nil
        )

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [appearanceInstance]
        )

        actor ErrorCollector {
            var error: Error?
            func set(_ err: Error) { self.error = err }
        }
        let errCollector = ErrorCollector()

        await adapter1.setBeforeConnectHook { _ in
            // While adapter1 is executing within executeSetup, attempt another mutating operation
            do {
                _ = try await engine.executeSetup(
                    plan: plan,
                    workspace: workspace,
                    instances: [appearanceInstance]
                )
            } catch {
                await errCollector.set(error)
            }
        }

        _ = try await engine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: [appearanceInstance]
        )

        let captured = await errCollector.error
        #expect(captured != nil)
        if let durableError = captured as? DurableOperationError {
            #expect(durableError == .operationInProgress)
        }
    }

    @Test("A denied deferred permission affects only that target and is disclosed in progress")
    func deferredPermissionDenialDoesNotStopSiblingTargets() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let deniedID = TargetInstanceID(rawValue: "macos.appearance")
        let readyID = TargetInstanceID(rawValue: "starship.default")
        let denied = ConnectedTargetInstance(
            id: deniedID, displayName: "System Appearance", adapterID: "macos.appearance")
        let ready = ConnectedTargetInstance(id: readyID, displayName: "Starship", adapterID: "starship")
        let deniedAdapter = RecordingWritableAdapter(
            id: "macos.appearance",
            requiredPermissions: ["Allow Automation"],
            baselineCaptureTiming: .immediatelyBeforeExecution,
            deniesDeferredBaselineCapture: true
        )
        let readyAdapter = RecordingWritableAdapter(id: "starship")
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [deniedAdapter, readyAdapter],
            persistence: fixture.store
        )
        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [deniedID, readyID],
            themeAssignment: nil
        )
        let plan = try await engine.prepareSetup(workspace: workspace, instances: [denied, ready])
        let progress = ProgressCollector()

        let report = try await engine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: [denied, ready],
            onProgress: { progress.add($0) }
        )

        #expect(report.outcomes.map(\.targetInstanceID) == [deniedID, readyID])
        #expect(report.outcomes[0].configurationState == .permissionRequired)
        #expect(report.outcomes[1].configurationState == .updated)
        #expect(progress.updates.contains { $0.currentAction == "Waiting for permission: Allow Automation" })
        #expect(try fixture.store.journalLoadConnectionBaseline(targetInstanceID: deniedID) == nil)
        #expect(try fixture.store.journalLoadConnectionBaseline(targetInstanceID: readyID) != nil)
    }

    @Test("Cancel Remaining skips untouched targets after the current target boundary")
    func cancelRemainingSetupSkipsUntouchedTargets() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "macos.appearance")
        let secondID = TargetInstanceID(rawValue: "starship.default")
        let first = ConnectedTargetInstance(
            id: firstID, displayName: "System Appearance", adapterID: "macos.appearance")
        let second = ConnectedTargetInstance(id: secondID, displayName: "Starship", adapterID: "starship")
        let firstAdapter = RecordingWritableAdapter(id: "macos.appearance")
        let secondAdapter = RecordingWritableAdapter(id: "starship")
        let gate = SetupGate()
        await firstAdapter.setBeforeConnectHook { _ in
            await gate.wait()
        }
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [firstAdapter, secondAdapter],
            persistence: fixture.store
        )
        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [firstID, secondID],
            themeAssignment: nil
        )
        let plan = try await engine.prepareSetup(workspace: workspace, instances: [first, second])
        let progress = ProgressCollector()
        let execution = Task {
            try await engine.executeSetup(
                plan: plan,
                workspace: workspace,
                instances: [first, second],
                onProgress: { progress.add($0) }
            )
        }

        while !(await gate.arrived()) {
            await Task.yield()
        }
        let operationID = progress.updates.last?.operationID
        #expect(operationID != nil)
        guard let operationID else { return }
        #expect(try await engine.cancelRemainingSetup(operationID: operationID))
        await gate.open()

        let report = try await execution.value
        #expect(report.outcomes.map(\.targetInstanceID) == [firstID, secondID])
        #expect(report.outcomes[0].configurationState == .updated)
        #expect(report.outcomes[1].detail == "Skipped after Cancel Remaining.")
        #expect(try fixture.store.journalLoadRecords(operationID: operationID).last?.phase == .skipped)
        #expect(try fixture.store.journalLoadOperation(id: operationID)?.state == .cancelled)
    }

    @Test("Cancel Remaining stops a target awaiting deferred baseline capture before mutation")
    func cancellationDuringDeferredBaselineCaptureDoesNotConnectTarget() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let targetID = TargetInstanceID(rawValue: "macos.appearance")
        let target = ConnectedTargetInstance(
            id: targetID,
            displayName: "System Appearance",
            adapterID: "macos.appearance"
        )
        let adapter = RecordingWritableAdapter(
            id: "macos.appearance",
            requiredPermissions: ["Allow Automation"],
            baselineCaptureTiming: .immediatelyBeforeExecution
        )
        let gate = SetupGate()
        await adapter.setBeforeDeferredBaselineCaptureHook { _ in
            await gate.wait()
        }
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: fixture.store)
        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [targetID],
            themeAssignment: nil
        )
        let plan = try await engine.prepareSetup(workspace: workspace, instances: [target])
        let progress = ProgressCollector()
        let execution = Task {
            try await engine.executeSetup(
                plan: plan,
                workspace: workspace,
                instances: [target],
                onProgress: { progress.add($0) }
            )
        }

        while !(await gate.arrived()) {
            await Task.yield()
        }
        guard let operationID = progress.updates.last?.operationID else {
            Issue.record("Expected setup progress before deferred baseline capture.")
            return
        }
        #expect(try await engine.cancelRemainingSetup(operationID: operationID))
        await gate.open()

        let report = try await execution.value
        #expect(report.kind(for: targetID) == .skipped)
        #expect(!(await adapter.isConnected(targetID)))
        #expect(try fixture.store.journalLoadConnectionBaseline(targetInstanceID: targetID) == nil)
        #expect(try fixture.store.journalLoadOperation(id: operationID)?.state == .cancelled)
    }

    @Test("Retry Setup Transactions retain their durable source operation")
    func retrySetupTransactionLinksToThePriorOperation() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let targetID = TargetInstanceID(rawValue: "starship.default")
        let target = ConnectedTargetInstance(id: targetID, displayName: "Starship", adapterID: "starship")
        let adapter = RecordingWritableAdapter(id: "starship")
        await adapter.setBeforeConnectHook { _ in
            throw RecordingConnectionFailedError()
        }
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: fixture.store)
        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [targetID],
            themeAssignment: nil
        )
        let sourcePlan = try await engine.prepareSetup(workspace: workspace, instances: [target])
        let sourceReport = try await engine.executeSetup(
            plan: sourcePlan,
            workspace: workspace,
            instances: [target]
        )

        await adapter.setBeforeConnectHook(nil)
        let retryPlan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [target],
            retrySourceOperationID: sourceReport.operationID
        )
        let retryReport = try await engine.executeSetup(
            plan: retryPlan,
            workspace: workspace,
            instances: [target]
        )

        #expect(retryReport.retrySourceOperationID == sourceReport.operationID)
        #expect(
            try fixture.store.journalLoadOperation(id: retryReport.operationID)?.parentOperationID
                == sourceReport.operationID
        )
    }

    @Test("Retry Remaining excludes targets that are already connected successfully")
    func retryRemainingExcludesAlreadyConnectedTargets() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let target1ID = TargetInstanceID(rawValue: "macos.appearance")
        let target2ID = TargetInstanceID(rawValue: "starship.default")
        let target3ID = TargetInstanceID(rawValue: "ghostty.default")
        let target1 = ConnectedTargetInstance(
            id: target1ID, displayName: "System Appearance", adapterID: "macos.appearance")
        let target2 = ConnectedTargetInstance(id: target2ID, displayName: "Starship", adapterID: "starship")
        let target3 = ConnectedTargetInstance(id: target3ID, displayName: "Ghostty", adapterID: "ghostty")

        let adapter1 = RecordingWritableAdapter(id: "macos.appearance")
        let adapter2 = RecordingWritableAdapter(id: "starship")
        let adapter3 = RecordingWritableAdapter(id: "ghostty")
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1, adapter2, adapter3],
            persistence: fixture.store
        )

        // Workspace where target1 is already connected successfully
        var workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [target1],
            targetOptIns: [target1ID, target2ID],
            themeAssignment: nil
        )

        await adapter2.setBeforeConnectHook { _ in
            throw RecordingConnectionFailedError()
        }
        let sourcePlan = try await engine.prepareSetup(workspace: workspace, instances: [target2])
        let sourceReport = try await engine.executeSetup(
            plan: sourcePlan,
            workspace: workspace,
            instances: [target2]
        )
        await adapter2.setBeforeConnectHook(nil)
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: [target1],
            targetOptIns: [target1ID, target2ID, target3ID],
            themeAssignment: nil
        )

        // A newly opted-in target is a new setup flow, not part of this retry.
        let retryPlan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [target1, target2, target3],
            retrySourceOperationID: sourceReport.operationID
        )

        // Excludes target1 because it is connected and target3 because it was
        // not unresolved in the source Setup Transaction.
        #expect(retryPlan.targetInstanceIDs == [target2ID])
        #expect(retryPlan.targetPlans.map(\.targetInstanceID) == [target2ID])
    }

    @Test("Retry prepares a fresh Setup Plan and produces combined outcomes without erasing earlier receipts")
    func retryProducesCombinedOutcomesWithoutErasingEarlierReceipts() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let target1ID = TargetInstanceID(rawValue: "macos.appearance")
        let target2ID = TargetInstanceID(rawValue: "starship.default")
        let target1 = ConnectedTargetInstance(
            id: target1ID, displayName: "System Appearance", adapterID: "macos.appearance")
        let target2 = ConnectedTargetInstance(id: target2ID, displayName: "Starship", adapterID: "starship")

        let adapter1 = RecordingWritableAdapter(id: "macos.appearance")
        let adapter2 = RecordingWritableAdapter(id: "starship")
        await adapter2.setBeforeConnectHook { _ in
            throw RecordingConnectionFailedError()
        }
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter1, adapter2], persistence: fixture.store)

        var workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [target1ID, target2ID],
            themeAssignment: nil
        )

        // 1. Initial attempt: target1 succeeds, target2 fails
        let firstPlan = try await engine.prepareSetup(workspace: workspace, instances: [target1, target2])
        let firstReport = try await engine.executeSetup(
            plan: firstPlan,
            workspace: workspace,
            instances: [target1, target2]
        )

        #expect(firstReport.outcomes.count == 2)
        #expect(firstReport.kind(for: target1ID) == .connected)
        #expect(firstReport.kind(for: target2ID) == .failed)

        // target1 connected in workspace, target2 remains unconnected
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: [target1],
            targetOptIns: [target1ID, target2ID],
            themeAssignment: nil
        )

        // Verify earlier receipts are saved durably in the journal
        let initialRecords = try fixture.store.journalLoadRecords(operationID: firstReport.operationID)
        #expect(initialRecords.count == 2)
        #expect(initialRecords[0].receiptJSON != nil)

        // 2. Fix target2 adapter so retry can succeed
        await adapter2.setBeforeConnectHook(nil)

        // 3. Prepare fresh setup plan for retry
        let retryPlan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [target1, target2],
            retrySourceOperationID: firstReport.operationID
        )

        // Fresh plan targets only unresolved target2
        #expect(retryPlan.targetInstanceIDs == [target2ID])
        #expect(retryPlan.retrySourceOperationID == firstReport.operationID)

        // 4. Execute retry setup
        let retryReport = try await engine.executeSetup(
            plan: retryPlan,
            workspace: workspace,
            instances: [target2]
        )

        #expect(retryReport.retrySourceOperationID == firstReport.operationID)
        #expect(retryReport.outcomes.count == 1)  // only target2 executed in this transaction
        #expect(retryReport.outcomes[0].targetInstanceID == target2ID)
        #expect(retryReport.kind(for: target2ID) == .connected)

        // Combined outcomes include both target1 (from prior transaction) and target2 (from retry)
        #expect(retryReport.combinedOutcomes.count == 2)
        #expect(retryReport.combinedOutcomes.map { $0.targetInstanceID } == [target1ID, target2ID])
        #expect(retryReport.resolvedOutcomes.count == 2)
        #expect(retryReport.unresolvedOutcomes.isEmpty)

        // Verify earlier records from first attempt were NOT erased
        let priorRecordsAfterRetry = try fixture.store.journalLoadRecords(operationID: firstReport.operationID)
        #expect(priorRecordsAfterRetry.count == 2)
        #expect(priorRecordsAfterRetry[0].receiptJSON != nil)

        // Verify durable link between transactions in SQLite operations table
        let durableRetryOp = try fixture.store.journalLoadOperation(id: retryReport.operationID)
        #expect(durableRetryOp?.parentOperationID == firstReport.operationID)
    }

    @Test("Materially changed retry plans return to aggregate review before mutation")
    func materiallyChangedRetryPlanRequiresReconfirmation() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let targetID = TargetInstanceID(rawValue: "starship.default")
        let target = ConnectedTargetInstance(id: targetID, displayName: "Starship", adapterID: "starship")
        let adapter = RecordingWritableAdapter(id: "starship")
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: fixture.store)

        let initialWorkspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [targetID],
            themeAssignment: nil
        )

        await adapter.setBeforeConnectHook { _ in
            throw RecordingConnectionFailedError()
        }
        let sourcePlan = try await engine.prepareSetup(
            workspace: initialWorkspace,
            instances: [target]
        )
        let sourceReport = try await engine.executeSetup(
            plan: sourcePlan,
            workspace: initialWorkspace,
            instances: [target]
        )
        await adapter.setBeforeConnectHook(nil)
        let plan = try await engine.prepareSetup(
            workspace: initialWorkspace,
            instances: [target],
            retrySourceOperationID: sourceReport.operationID
        )

        // Material change: user opts out or target opt-ins change
        let changedWorkspace = Workspace(
            id: initialWorkspace.id,
            displayName: initialWorkspace.displayName,
            connectedTargetInstances: [],
            targetOptIns: [],  // opted out
            themeAssignment: nil
        )

        let validation = await engine.validateSetupPlanPreconditions(
            plan: plan,
            workspace: changedWorkspace,
            currentInstances: [target],
            availableTargetInstanceIDs: [targetID]
        )

        switch validation {
        case .invalidated(let reason):
            #expect(reason.contains("Target Opt-ins"))
        case .valid:
            Issue.record("Expected plan to be invalidated due to opt-ins change")
        }
    }

    // Recovery reconciliation for interrupted setup
    @Test("Interrupted setup operation is reconciled cleanly on engine startup")
    func interruptedSetupIsReconciled() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "macos.appearance")
        let adapter1 = RecordingWritableAdapter(id: "macos.appearance")

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1],
            persistence: fixture.store
        )

        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [firstID],
            themeAssignment: nil
        )

        // Inject an interrupted setup operation directly into the journal
        let op = try fixture.store.journalStartOperation(kind: .setup, workspaceID: workspace.id)
        try fixture.store.journalTransitionState(operationID: op.id, to: .applying)

        // Calling reconcileInterruptedOperations should reconcile and transition state
        try await engine.reconcileInterruptedOperations()

        let reloaded = try fixture.store.journalLoadOperation(id: op.id)
        #expect(reloaded?.state == .failed || reloaded?.state == .applied || reloaded?.state == .reconciled)
    }

    // AC 2: Cancellation before mutation is immediate; unstarted instances marked skipped.
    @Test("Cancellation before mutation is immediate and marks unstarted instances skipped")
    func cancellationBeforeMutationIsImmediate() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "macos.appearance")
        let first = ConnectedTargetInstance(
            id: firstID, displayName: "System Appearance", adapterID: "macos.appearance")
        let firstAdapter = RecordingWritableAdapter(id: "macos.appearance")

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [firstAdapter],
            persistence: fixture.store
        )
        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [firstID],
            themeAssignment: nil
        )
        let plan = try await engine.prepareSetup(workspace: workspace, instances: [first])

        // Request cancellation before executeSetup begins
        #expect(try await engine.cancelRemainingSetup(operationID: plan.id))

        var caughtCancellation = false
        do {
            _ = try await engine.executeSetup(
                plan: plan,
                workspace: workspace,
                instances: [first]
            )
        } catch let error as DurableOperationError {
            if error == .operationCancelled {
                caughtCancellation = true
            }
        }

        #expect(caughtCancellation)
        let records = try fixture.store.journalLoadRecords(operationID: plan.id)
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.phase == .skipped })
        #expect(try fixture.store.journalLoadOperation(id: plan.id)?.state == .cancelled)
        #expect(try fixture.store.journalLoadConnectionBaseline(targetInstanceID: firstID) == nil)
        #expect(await firstAdapter.isConnected(firstID) == false)
    }

    // AC 3: Completed target results remain intact and are not automatically restored when setup is canceled.
    @Test("Completed target results remain intact and are not restored when setup is cancelled")
    func completedTargetsRemainIntactOnCancel() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "macos.appearance")
        let secondID = TargetInstanceID(rawValue: "starship.default")
        let first = ConnectedTargetInstance(
            id: firstID, displayName: "System Appearance", adapterID: "macos.appearance")
        let second = ConnectedTargetInstance(id: secondID, displayName: "Starship", adapterID: "starship")
        let firstAdapter = RecordingWritableAdapter(id: "macos.appearance")
        let secondAdapter = RecordingWritableAdapter(id: "starship")

        let gate = SetupGate()
        await firstAdapter.setBeforeConnectHook { _ in
            await gate.wait()
        }

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [firstAdapter, secondAdapter],
            persistence: fixture.store
        )
        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [firstID, secondID],
            themeAssignment: nil
        )
        let plan = try await engine.prepareSetup(workspace: workspace, instances: [first, second])
        let progress = ProgressCollector()
        let execution = Task {
            try await engine.executeSetup(
                plan: plan,
                workspace: workspace,
                instances: [first, second],
                onProgress: { progress.add($0) }
            )
        }

        while !(await gate.arrived()) {
            await Task.yield()
        }
        let operationID = progress.updates.last?.operationID
        #expect(operationID != nil)
        guard let operationID else { return }

        // Cancel while instance 2 is waiting
        #expect(try await engine.cancelRemainingSetup(operationID: operationID))
        await gate.open()

        let report = try await execution.value
        #expect(report.outcomes[0].targetInstanceID == firstID)
        #expect(report.outcomes[0].configurationState == .updated)
        #expect(report.outcomes[1].targetInstanceID == secondID)
        #expect(report.outcomes[1].detail == "Skipped after Cancel Remaining.")

        // Verify first target remains intact and was NOT restored
        let baseline = try fixture.store.journalLoadConnectionBaseline(targetInstanceID: firstID)
        #expect(baseline != nil)
        let loaded = try fixture.store.loadWorkspace()
        let firstPersisted = loaded.targetInstances.first { $0.id == firstID }
        #expect(firstPersisted?.isConnected == true)
    }

    // AC 4: Skipped states and the cancellation request survive relaunch.
    @Test("Skipped states and cancellation request survive relaunch")
    func skippedStatesAndCancellationSurviveRelaunch() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "macos.appearance")
        let secondID = TargetInstanceID(rawValue: "starship.default")
        let firstAdapter = RecordingWritableAdapter(id: "macos.appearance")
        let secondAdapter = RecordingWritableAdapter(id: "starship")

        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [firstID, secondID],
            themeAssignment: nil
        )

        // Inject an interrupted setup operation with cancellation requested
        let op = try fixture.store.journalStartOperation(kind: .setup, workspaceID: workspace.id)
        try fixture.store.journalRecordCancellationRequest(operationID: op.id)
        try fixture.store.journalTransitionState(operationID: op.id, to: .applying)

        // Target 1: was completed before interrupt
        try fixture.store.journalSaveRecord(
            JournaledRecord(
                operationID: op.id,
                targetInstanceID: firstID,
                ordinal: 0,
                adapterID: "macos.appearance",
                adapterVersion: "1",
                capabilityID: "connection",
                phase: .applied,
                intendedChangeDigest: "connected",
                staleStateToken: nil,
                planDigest: nil,
                receiptJSON: nil,
                detail: nil
            )
        )
        // Target 2: was not started yet (phase .prepared)
        try fixture.store.journalSaveRecord(
            JournaledRecord(
                operationID: op.id,
                targetInstanceID: secondID,
                ordinal: 1,
                adapterID: "starship",
                adapterVersion: "1",
                capabilityID: "connection",
                phase: .prepared,
                intendedChangeDigest: "connected",
                staleStateToken: nil,
                planDigest: nil,
                receiptJSON: nil,
                detail: nil
            )
        )

        // Simulate relaunch by creating a brand new ThemeEngine instance
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [firstAdapter, secondAdapter],
            persistence: fixture.store
        )

        try await engine.reconcileInterruptedOperations()

        // Verify cancellation survived relaunch
        let reloaded = try fixture.store.journalLoadOperation(id: op.id)
        #expect(reloaded?.cancellationRequested == true)
        #expect(reloaded?.state == .cancelled)

        // Verify Target 2 was marked skipped
        let records = try fixture.store.journalLoadRecords(operationID: op.id)
        let secondRecord = records.first { $0.targetInstanceID == secondID }
        #expect(secondRecord?.phase == .skipped)
        #expect(secondRecord?.detail == "Skipped after Cancel Remaining.")

        // Verify Target 1 completed state remained intact
        let firstRecord = records.first { $0.targetInstanceID == firstID }
        #expect(firstRecord?.phase == .applied)
    }
}
