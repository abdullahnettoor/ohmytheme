import Foundation
import Persistence
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Apply Cancellation Tests")
struct ApplyCancellationTests {
    private struct Fixture {
        let directory: URL
        let store: PersistenceStore

        init() throws {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("omt-apply-cancel-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            self.directory = temp
            self.store = try PersistenceStore(
                databaseURL: temp.appendingPathComponent("state.sqlite"),
                contentStoreURL: temp.appendingPathComponent("recovery", isDirectory: true)
            )
        }
    }

    actor ApplyGate {
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
        private var _updates: [ApplyProgress] = []
        private let lock = NSLock()

        var updates: [ApplyProgress] {
            lock.lock()
            defer { lock.unlock() }
            return _updates
        }

        func add(_ progress: ApplyProgress) {
            lock.lock()
            defer { lock.unlock() }
            _updates.append(progress)
        }
    }

    private static func makeFixture() throws -> Fixture {
        try Fixture()
    }

    // AC 1: Apply preparation can be canceled immediately before external mutation begins.
    // AC 3: Unstarted instances are durably marked skipped and are not mutated.
    @Test("Apply preparation can be canceled immediately before external mutation begins")
    func cancellationBeforeMutationIsImmediateAndMarksUnstartedInstancesSkipped() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "recording.a")
        let secondID = TargetInstanceID(rawValue: "recording.b")
        let firstInstance = ConnectedTargetInstance(id: firstID, displayName: "Recording A", adapterID: "recording.a")
        let secondInstance = ConnectedTargetInstance(id: secondID, displayName: "Recording B", adapterID: "recording.b")

        let firstAdapter = RecordingWritableAdapter(id: "recording.a")
        let secondAdapter = RecordingWritableAdapter(id: "recording.b")

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [firstAdapter, secondAdapter],
            persistence: fixture.store
        )
        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [firstInstance, secondInstance],
            targetOptIns: [firstID, secondID],
            themeAssignment: .fixed(variantID: "test-pack/dark")
        )

        let plan = try await engine.prepare(workspace: workspace)

        // Request cancellation before apply mutation begins
        #expect(try await engine.cancelRemainingApply(operationID: plan.id))

        var caughtCancellation = false
        do {
            _ = try await engine.applyDurable(planID: plan.id, workspace: workspace)
        } catch let error as DurableOperationError {
            if error == .operationCancelled {
                caughtCancellation = true
            }
        }

        #expect(caughtCancellation)

        // Unstarted instances are durably marked skipped
        let records = try fixture.store.journalLoadRecords(operationID: plan.id)
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.phase == .skipped })

        // Neither adapter was mutated
        let firstBytes = await firstAdapter.currentWorldBytes()
        let secondBytes = await secondAdapter.currentWorldBytes()
        #expect(firstBytes == Data("recording-world-initial".utf8))
        #expect(secondBytes == Data("recording-world-initial".utf8))

        // Operation state is cancelled
        let op = try fixture.store.journalLoadOperation(id: plan.id)
        #expect(op?.state == .cancelled)
    }

    // AC 2: After mutation starts, cancellation waits for the active Target Instance to reach a terminal or recovery-required state.
    // AC 3: Unstarted instances are durably marked skipped and are not mutated.
    // AC 5: Presentation shows the active target and distinguishes completed, active, and skipped targets.
    @Test("Cancellation during mutation waits for active target to finish and skips remaining targets")
    func cancellationWaitsForActiveTargetToReachTerminalStateAndSkipsSubsequent() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "recording.a")
        let secondID = TargetInstanceID(rawValue: "recording.b")
        let firstInstance = ConnectedTargetInstance(id: firstID, displayName: "Recording A", adapterID: "recording.a")
        let secondInstance = ConnectedTargetInstance(id: secondID, displayName: "Recording B", adapterID: "recording.b")

        let firstAdapter = RecordingWritableAdapter(id: "recording.a")
        let secondAdapter = RecordingWritableAdapter(id: "recording.b")

        let gate = ApplyGate()
        await firstAdapter.setBeforeApplyHook { _ in
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
            connectedTargetInstances: [firstInstance, secondInstance],
            targetOptIns: [firstID, secondID],
            themeAssignment: .fixed(variantID: "test-pack/dark")
        )

        let plan = try await engine.prepare(workspace: workspace)
        let collector = ProgressCollector()

        let execution = Task {
            try await engine.applyDurable(planID: plan.id, workspace: workspace, onProgress: { collector.add($0) })
        }

        // Wait until target 1 has entered apply
        while !(await gate.arrived()) {
            await Task.yield()
        }

        // Check progress while target 1 is applying
        let inFlightProgress = collector.updates.last
        #expect(inFlightProgress != nil)
        #expect(inFlightProgress?.currentTargetID == firstID)
        let activeStep = inFlightProgress?.steps.first(where: { $0.targetInstanceID == firstID })
        #expect(activeStep?.status.isActive == true)

        let operationID = inFlightProgress?.operationID
        #expect(operationID != nil)
        guard let operationID else { return }

        // Cancel while first target is applying and second target has not started
        #expect(try await engine.cancelRemainingApply(operationID: operationID))

        // Open gate to allow target 1 to finish reaching its terminal state
        await gate.open()

        let report = try await execution.value

        // Target 1 finished reaching terminal state (.updated)
        let firstOutcome = report.outcomes.first(where: { $0.targetInstanceID == firstID })
        #expect(firstOutcome?.configurationState == .updated)

        // Target 2 was skipped without mutating
        let secondOutcome = report.outcomes.first(where: { $0.targetInstanceID == secondID })
        #expect(secondOutcome?.configurationState == .unchanged)
        #expect(secondOutcome?.detail == "Skipped after Cancel Remaining.")

        // Verify second adapter was never mutated
        let secondBytes = await secondAdapter.currentWorldBytes()
        #expect(secondBytes == Data("recording-world-initial".utf8))

        // Journal records: target 1 applied, target 2 skipped
        let records = try fixture.store.journalLoadRecords(operationID: operationID)
        let firstRecord = records.first(where: { $0.targetInstanceID == firstID && $0.phase == .applied })
        let secondRecord = records.first(where: { $0.targetInstanceID == secondID && $0.phase == .skipped })
        #expect(firstRecord != nil)
        #expect(secondRecord != nil)

        // Progress updates distinguish completed, active, and skipped targets
        let finalProgress = collector.updates.last
        #expect(finalProgress != nil)
        let finalFirstStep = finalProgress?.steps.first(where: { $0.targetInstanceID == firstID })
        let finalSecondStep = finalProgress?.steps.first(where: { $0.targetInstanceID == secondID })
        #expect(finalFirstStep?.status.isCompleted == true)
        #expect(finalSecondStep?.status.isSkipped == true)
    }

    // AC 4: Completed results remain part of the partial Apply Transaction and follow existing Last Apply Transaction rules.
    @Test("Completed results remain part of partial Apply Transaction and can be undone")
    func completedResultsRemainPartofLATAndCanBeUndone() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let firstID = TargetInstanceID(rawValue: "recording.a")
        let secondID = TargetInstanceID(rawValue: "recording.b")
        let firstInstance = ConnectedTargetInstance(id: firstID, displayName: "Recording A", adapterID: "recording.a")
        let secondInstance = ConnectedTargetInstance(id: secondID, displayName: "Recording B", adapterID: "recording.b")

        let firstAdapter = RecordingWritableAdapter(id: "recording.a")
        let secondAdapter = RecordingWritableAdapter(id: "recording.b")

        let gate = ApplyGate()
        await firstAdapter.setBeforeApplyHook { _ in
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
            connectedTargetInstances: [firstInstance, secondInstance],
            targetOptIns: [firstID, secondID],
            themeAssignment: .fixed(variantID: "test-pack/dark")
        )

        let plan = try await engine.prepare(workspace: workspace)
        let collector = ProgressCollector()

        let execution = Task {
            try await engine.applyDurable(planID: plan.id, workspace: workspace, onProgress: { collector.add($0) })
        }

        while !(await gate.arrived()) {
            await Task.yield()
        }
        guard let operationID = collector.updates.last?.operationID else { return }

        #expect(try await engine.cancelRemainingApply(operationID: operationID))
        await gate.open()

        _ = try await execution.value

        // Undo availability: the cancelled operation is a valid Last Apply Transaction because target 1 was applied
        let availability = try await engine.undoAvailability(workspace: workspace)
        guard case .available(let sourceOpID, let changedCount) = availability else {
            Issue.record("Expected undo to be available for completed targets in partial apply transaction")
            return
        }
        #expect(sourceOpID == operationID)
        #expect(changedCount == 1)

        // Undo Last Apply Transaction: only target 1 is rolled back
        let undoReport = try await engine.undoLast(workspace: workspace)
        #expect(undoReport.outcomes.count == 1)
        #expect(undoReport.outcomes[0].targetInstanceID == firstID)
        #expect(undoReport.outcomes[0].rollbackState == .restored)
    }
}
