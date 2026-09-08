import Foundation
import Persistence
import PlatformClients
import ThemeEngine
import ThemeModel
import XCTest

@testable import OhMyTheme

@MainActor
final class ProductionWorkspaceRuntimeTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var persistence: PersistenceStore!
    private var store: WorkspaceStore!
    private var packs: [ThemePack]!

    override func setUp() async throws {
        try await super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-runtime-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        persistence = try PersistenceStore(
            databaseURL: temporaryDirectory.appendingPathComponent("workspace.sqlite"),
            contentStoreURL: temporaryDirectory.appendingPathComponent("Recovery", isDirectory: true)
        )
        store = WorkspaceStore(persistenceStore: persistence)
        packs = try BundledThemeCatalog().load()
    }

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try await super.tearDown()
    }

    func testRuntimeExposesCurrentWorkspaceCatalogAndDiscoveredTargets() async throws {
        let runtime = ProductionWorkspaceRuntime(store: store, themePacks: packs)

        XCTAssertEqual(runtime.workspace.displayName, "My Mac")
        XCTAssertEqual(runtime.themePacks.map(\.displayName), ["Catppuccin", "Oh My Theme"])
        XCTAssertNil(runtime.persistenceError)
        XCTAssertTrue(runtime.canApplyThemes)

        let snapshot = try await runtime.start()

        XCTAssertEqual(snapshot.workspace.id, .myMac)
        XCTAssertTrue(snapshot.targets.contains { $0.id == "macos" })
    }

    func testRuntimeSelectFixedThemeVariantPersistsThemeAssignment() throws {
        let runtime = ProductionWorkspaceRuntime(store: store, themePacks: packs)

        runtime.selectFixedThemeVariant("oh-my-theme/aurora")

        XCTAssertEqual(runtime.workspace.themeAssignment, .fixed(variantID: "oh-my-theme/aurora"))

        // Verify SQLite persistence survives a new WorkspaceStore instance
        let reloadedStore = WorkspaceStore(persistenceStore: persistence)
        XCTAssertEqual(reloadedStore.workspace.themeAssignment, .fixed(variantID: "oh-my-theme/aurora"))
    }

    func testRuntimeConnectionReviewAndConnectRegistersBaselineAndUpdatesWorkspace() async throws {
        let adapter = RecordingWritableAdapter(id: "recording")
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: packs,
            additionalAdapters: [adapter]
        )

        _ = try await runtime.start()

        let candidateID = TargetInstanceID(rawValue: "recording.default")
        let reviewPlan = try await runtime.reviewConnection(optionID: candidateID)

        XCTAssertEqual(reviewPlan.targetInstanceID, candidateID)
        XCTAssertEqual(reviewPlan.adapterID, "recording")
        XCTAssertFalse(reviewPlan.requiresApproval)

        let connectionResult = try await runtime.connect(optionID: candidateID, reviewedPlan: reviewPlan)

        XCTAssertEqual(connectionResult.report.outcomes.first?.configurationState, .updated)
        XCTAssertTrue(runtime.workspace.connectedTargetInstances.contains { $0.id == candidateID })

        // Verify connected instance is durably recorded
        let reloadedWorkspace = store.workspace
        XCTAssertTrue(reloadedWorkspace.connectedTargetInstances.contains { $0.id == candidateID })
    }

    func testRuntimePreparesAndAppliesPlanDurablyWithRealEngineOrchestration() async throws {
        let adapter = RecordingWritableAdapter(id: "recording")
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: packs,
            additionalAdapters: [adapter]
        )

        _ = try await runtime.start()
        runtime.selectFixedThemeVariant("catppuccin/mocha")

        let candidateID = TargetInstanceID(rawValue: "recording.default")
        let reviewPlan = try await runtime.reviewConnection(optionID: candidateID)
        _ = try await runtime.connect(optionID: candidateID, reviewedPlan: reviewPlan)

        let initialAvailability = try await runtime.undoAvailability()
        XCTAssertEqual(initialAvailability, .unavailable)

        let plan = try await runtime.prepareApplyPlan()

        XCTAssertEqual(plan.variantID, "catppuccin/mocha")
        XCTAssertEqual(plan.targetPlans.count, 1)
        XCTAssertEqual(plan.targetPlans.first?.targetInstanceID, candidateID)

        let applyReport = try await runtime.apply(planID: plan.id)

        XCTAssertEqual(applyReport.variantID, plan.variantID)
        XCTAssertEqual(applyReport.outcomes.first?.configurationState, .updated)
        XCTAssertEqual(applyReport.outcomes.first?.rollbackState, .undoAvailable)

        let availabilityAfterApply = try await runtime.undoAvailability()
        guard case .available = availabilityAfterApply else {
            XCTFail("Expected .available, got \(availabilityAfterApply)")
            return
        }

        // Verify durable storage has the Last Apply Transaction recorded
        let lat = try persistence.journalFindLastAppliedTransaction(workspaceID: runtime.workspace.id)
        XCTAssertNotNil(lat)
        XCTAssertEqual(lat?.id, applyReport.operationID)
    }

    func testRuntimeUndoRestoresPreviousBaselineWithRealEngineOrchestration() async throws {
        let initialWorld = Data("baseline-before-theme".utf8)
        let adapter = RecordingWritableAdapter(id: "recording", initialWorld: initialWorld)
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: packs,
            additionalAdapters: [adapter]
        )

        _ = try await runtime.start()
        runtime.selectFixedThemeVariant("catppuccin/mocha")

        let candidateID = TargetInstanceID(rawValue: "recording.default")
        let reviewPlan = try await runtime.reviewConnection(optionID: candidateID)
        _ = try await runtime.connect(optionID: candidateID, reviewedPlan: reviewPlan)

        let plan = try await runtime.prepareApplyPlan()
        _ = try await runtime.apply(planID: plan.id)

        let bytesAfterApply = await adapter.currentWorldBytes()
        XCTAssertNotEqual(bytesAfterApply, initialWorld)

        let undoReport = try await runtime.undoLast()

        XCTAssertEqual(undoReport.outcomes.first?.rollbackState, .restored)
        let avail = try await runtime.undoAvailability()
        XCTAssertEqual(avail, .unavailable)

        let bytesAfterUndo = await adapter.currentWorldBytes()
        XCTAssertEqual(bytesAfterUndo, initialWorld + Data(".connected".utf8))
    }

    func testRuntimeRestoreAndDisconnectRemovesTargetAndRestoresBaseline() async throws {
        let initialWorld = Data("baseline-before-connect".utf8)
        let adapter = RecordingWritableAdapter(id: "recording", initialWorld: initialWorld)
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: packs,
            additionalAdapters: [adapter]
        )

        _ = try await runtime.start()

        let candidateID = TargetInstanceID(rawValue: "recording.default")
        let reviewPlan = try await runtime.reviewConnection(optionID: candidateID)
        _ = try await runtime.connect(optionID: candidateID, reviewedPlan: reviewPlan)

        XCTAssertTrue(runtime.workspace.connectedTargetInstances.contains { $0.id == candidateID })

        let disconnectResult = try await runtime.restoreAndDisconnect(targetInstanceID: candidateID)

        XCTAssertEqual(disconnectResult.report.outcomes.first?.configurationState, .updated)
        XCTAssertFalse(runtime.workspace.connectedTargetInstances.contains { $0.id == candidateID })
        XCTAssertFalse(store.workspace.connectedTargetInstances.contains { $0.id == candidateID })
    }

    func testRuntimeStartupRecoveryReconcilesInterruptedOperations() async throws {
        let runtime = ProductionWorkspaceRuntime(store: store, themePacks: packs)

        // Seed an operation in progress
        let interruptedOp = try persistence.journalStartOperation(
            kind: .apply,
            workspaceID: store.workspace.id,
            variantID: "catppuccin/mocha"
        )
        try persistence.journalTransitionState(operationID: interruptedOp.id, to: .applying)
        let beforeOp = try persistence.journalLoadOperation(id: interruptedOp.id)
        XCTAssertEqual(beforeOp?.state, .applying)

        // Calling start() must reconcile interrupted operations
        let snapshot = try await runtime.start()

        XCTAssertEqual(snapshot.workspace.id, .myMac)

        // The operation should now be marked reconciled in the journal
        let loaded = try persistence.journalLoadOperation(id: interruptedOp.id)
        XCTAssertEqual(loaded?.state, .reconciled)
    }
}
